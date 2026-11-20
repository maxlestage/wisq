//! **Un disque lu depuis un fichier, dont les écritures vont dans une couche
//! à part — et y restent.** L'arrière ([`Arriere`]) d'une machine native :
//! `FileDiskStore` du cœur Swift (`Sources/WisqVM/DiskStore.swift`), avec les
//! mêmes garanties et **le même format, octet pour octet**.
//!
//! **La base ne change jamais.** Elle est ouverte en lecture seule, et c'est
//! le fichier que la personne a importé : une image ext4, une ISO de plus
//! d'un gigaoctet. Rien n'en est copié en mémoire ; une lecture est un
//! `pread` à l'endroit demandé.
//!
//! **La couche est faite de deux fichiers, et elle est tassée.** `couche`
//! range les secteurs écrits les uns derrière les autres, dans l'ordre où
//! ils ont été écrits : le n-ième secteur touché occupe le n-ième
//! emplacement, quel que soit son numéro sur le disque. `couche.map` dit quel
//! secteur occupe quel emplacement — un en-tête de seize octets (`wisqdisk`,
//! puis le nombre de secteurs de la base), puis un numéro de secteur de huit
//! octets par emplacement. La raison est une mesure du cœur Swift : sur APFS,
//! un fichier épars alloue ses trous, et un seul secteur écrit à deux
//! mébioctets du début y coûtait deux mébioctets.
//!
//! **Chaque écriture est durable au moment où elle est faite** : le secteur
//! part dans `couche`, puis son numéro dans `couche.map`, avant que le
//! disque ne réponde à l'invité. **Dans cet ordre**, et l'ordre rend une
//! mort brutale inoffensive : un emplacement écrit mais pas encore nommé
//! n'appartient à personne, il est ignoré à la réouverture et le prochain
//! secteur le reprend. [`Arriere::vider`] ajoute `fsync`.
//!
//! **Pourquoi l'écrire une troisième fois.** Le format existe déjà en Swift,
//! et en Rust dans `wisq_vm::store` pour la machine RISC-V. Mais ce crate ne
//! dépend de rien — c'est ce qui laisse `wisq-vm` le prendre —, et ne peut
//! donc pas emprunter le magasin de `wisq-vm`. Les couches que l'application
//! a déjà écrites sur les téléphones doivent pourtant se relire telles
//! quelles : `crates/wisq-page/tests/disque.rs` fait écrire les mêmes
//! secteurs par les deux et compare les deux fichiers octet pour octet, puis
//! fait rouvrir à chacun la couche de l'autre.
//!
//! **Ce qui change, et c'est une mesure** : la lecture. `wisq_vm::store` et
//! le cœur Swift lisent secteur par secteur, un `pread` de 512 octets à la
//! fois. Ici les secteurs qui se suivent dans le même fichier se lisent d'un
//! seul `pread` : une lecture d'un mébioctet dans une ISO que personne n'a
//! écrite en fait un, pas deux mille quarante-huit.
//!
//! **Ce qui n'est pas porté** : les formats à tables (qcow2, VMDK, VDI, VHD,
//! VHDX, OVA), que `FileDiskStore` lit à travers `VirtualDiskImages`. Le
//! bureau n'en a pas besoin — l'application lui attache une ISO brute, et un
//! disque vierge brut à côté (`BlankDisk`). La base est lue ici octet pour
//! octet : c'est à l'appelant de refuser une image à tables, comme
//! `RustLinuxMachine.attach(diskFileAt:)` le fait pour la machine RISC-V.

use std::collections::HashMap;
use std::fmt;
use std::fs::{File, OpenOptions};
use std::os::unix::fs::{FileExt, OpenOptionsExt};
use std::path::Path;

use super::pc::Arriere;

/// Un secteur : 512 octets.
pub const SECTEUR: u64 = 512;
/// Huit octets qui disent à quoi sert le fichier, suivis du nombre de
/// secteurs de la base : c'est **lui** qui rattache une couche à son disque.
const MARQUE: &[u8; 8] = b"wisqdisk";
const ENTETE: u64 = 16;

/// Pourquoi un disque n'a pas pu être ouvert : les cas de
/// `FileDiskStore.Failure`, dans le même ordre.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Refus {
    /// La base n'a pas pu être ouverte.
    BaseIllisible,
    /// Moins d'un secteur : l'invité verrait un disque de zéro secteur.
    PasUnDisque,
    /// La couche n'a pas pu être créée ou ouverte.
    CoucheIllisible,
    /// L'en-tête de la carte ne décrit pas cette base : cette couche vient
    /// d'un autre disque, et la lire donnerait les secteurs d'un autre
    /// fichier.
    CoucheDUnAutreDisque,
    /// La carte nomme des emplacements que le fichier des écritures n'a pas :
    /// il a été tronqué, et les octets que l'invité croit avoir écrits ne
    /// sont plus là.
    CoucheTronquee,
}

impl fmt::Display for Refus {
    /// Les phrases de `FileDiskStore.Failure.errorDescription`.
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Refus::BaseIllisible => "le disque n'a pas pu être ouvert.",
            Refus::PasUnDisque => "le disque fait moins d'un secteur.",
            Refus::CoucheIllisible => "la couche d'écriture du disque n'a pas pu être créée.",
            Refus::CoucheDUnAutreDisque => {
                "la couche d'écriture trouvée appartient à un autre disque."
            }
            Refus::CoucheTronquee => "la couche d'écriture du disque est incomplète.",
        })
    }
}

impl std::error::Error for Refus {}

/// D'où vient un secteur.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Source {
    Base,
    Couche,
}

/// **Le disque** : la base, sa couche, et la carte des emplacements.
pub struct DisqueFichier {
    base: File,
    couche: File,
    carte: File,
    secteurs: u64,
    /// Quel emplacement porte quel secteur. En mémoire seulement : la carte
    /// sur le disque est la liste des secteurs, dans l'ordre des
    /// emplacements.
    places: HashMap<u64, u64>,
    occupees: u64,
}

impl DisqueFichier {
    /// **Ouvrir un disque** : `base`, lue sur place et jamais modifiée, et
    /// `couche`, où vont les écritures (sa carte est `couche` suivi de
    /// `.map`). Les deux fichiers de la couche sont créés s'ils n'existent
    /// pas ; s'ils existent, ce qu'ils portent est repris.
    pub fn ouvrir(base: &Path, couche: &Path) -> Result<Self, Refus> {
        let base = File::open(base).map_err(|_| Refus::BaseIllisible)?;
        let taille = base.metadata().map_err(|_| Refus::BaseIllisible)?.len();
        if taille < SECTEUR {
            return Err(Refus::PasUnDisque);
        }
        let secteurs = taille / SECTEUR;

        let mut options = OpenOptions::new();
        options
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .mode(0o600);
        let mut chemin_de_la_carte = couche.as_os_str().to_owned();
        chemin_de_la_carte.push(".map");
        let couche = options.open(couche).map_err(|_| Refus::CoucheIllisible)?;
        let carte = options
            .open(Path::new(&chemin_de_la_carte))
            .map_err(|_| Refus::CoucheIllisible)?;
        let taille_de_la_carte = carte.metadata().map_err(|_| Refus::CoucheIllisible)?.len();
        let taille_de_la_couche = couche.metadata().map_err(|_| Refus::CoucheIllisible)?.len();

        let mut places = HashMap::new();
        let mut occupees = 0u64;
        if taille_de_la_carte == 0 {
            let mut entete = [0u8; ENTETE as usize];
            entete[..8].copy_from_slice(MARQUE);
            entete[8..].copy_from_slice(&secteurs.to_le_bytes());
            carte
                .write_all_at(&entete, 0)
                .map_err(|_| Refus::CoucheIllisible)?;
        } else {
            if taille_de_la_carte < ENTETE {
                return Err(Refus::CoucheDUnAutreDisque);
            }
            let mut entete = [0u8; ENTETE as usize];
            carte
                .read_exact_at(&mut entete, 0)
                .map_err(|_| Refus::CoucheIllisible)?;
            let (marque, declares) = entete.split_at(8);
            if marque != MARQUE {
                return Err(Refus::CoucheDUnAutreDisque);
            }
            if declares != secteurs.to_le_bytes() {
                return Err(Refus::CoucheDUnAutreDisque);
            }
            // **Les deux fichiers ne peuvent se désaccorder que dans un
            // sens.** Le contenu part avant le nom, donc il peut y avoir un
            // emplacement de plus que de noms : c'est l'application tuée
            // entre les deux, et cet emplacement-là n'appartient à personne.
            //
            // L'inverse est impossible à produire honnêtement : un nom dont
            // le contenu manque veut dire que le fichier des écritures a été
            // tronqué. On refuse la couche plutôt que de choisir entre deux
            // mauvaises réponses — rendre le secteur de la base, périmé, sans
            // le dire, ou une erreur à chaque lecture de ce secteur.
            let nommes = (taille_de_la_carte - ENTETE) / 8;
            let ranges = taille_de_la_couche / SECTEUR;
            if nommes > ranges {
                return Err(Refus::CoucheTronquee);
            }
            if nommes > 0 {
                let longueur = usize::try_from(nommes * 8).map_err(|_| Refus::CoucheIllisible)?;
                let mut noms = vec![0u8; longueur];
                carte
                    .read_exact_at(&mut noms, ENTETE)
                    .map_err(|_| Refus::CoucheIllisible)?;
                places.reserve(nommes as usize);
                for (place, nom) in noms.chunks_exact(8).enumerate() {
                    let mut huit = [0u8; 8];
                    huit.copy_from_slice(nom);
                    places.insert(u64::from_le_bytes(huit), place as u64);
                }
                occupees = nommes;
            }
        }

        Ok(Self {
            base,
            couche,
            carte,
            secteurs,
            places,
            occupees,
        })
    }

    /// **Combien d'octets l'invité a changés** : 512 par secteur touché. Ce
    /// que le rapport de stockage de l'application montre.
    pub fn octets_ecrits(&self) -> u64 {
        self.occupees * SECTEUR
    }

    fn dans_le_disque(&self, decalage: u64, longueur: usize) -> bool {
        let taille = self.secteurs * SECTEUR;
        decalage <= taille && longueur as u64 <= taille - decalage
    }

    /// D'où lire l'octet `dedans` du secteur `secteur`.
    fn source(&self, secteur: u64, dedans: u64) -> (Source, u64) {
        match self.places.get(&secteur) {
            Some(place) => (Source::Couche, place * SECTEUR + dedans),
            None => (Source::Base, secteur * SECTEUR + dedans),
        }
    }

    fn fichier(&self, source: Source) -> &File {
        match source {
            Source::Base => &self.base,
            Source::Couche => &self.couche,
        }
    }
}

impl Arriere for DisqueFichier {
    fn secteurs(&self) -> u64 {
        self.secteurs
    }

    fn lire(&mut self, decalage: u64, vers: &mut [u8]) -> bool {
        if !self.dans_le_disque(decalage, vers.len()) {
            return false;
        }
        // Une base que personne n'a écrite — une ISO — se lit d'un trait.
        if self.places.is_empty() {
            return self.base.read_exact_at(vers, decalage).is_ok();
        }
        let mut fait = 0usize;
        let mut a = decalage;
        while fait < vers.len() {
            let (secteur, dedans) = (a / SECTEUR, a % SECTEUR);
            let (source, depuis) = self.source(secteur, dedans);
            // Ce morceau s'étend tant que les secteurs suivants se suivent
            // aussi dans le fichier d'où celui-ci vient : la base toujours,
            // la couche quand ils y ont été écrits à la file.
            let mut n = (vers.len() - fait).min((SECTEUR - dedans) as usize);
            let mut suivant = secteur + 1;
            while fait + n < vers.len() && self.source(suivant, 0) == (source, depuis + n as u64) {
                n += (vers.len() - fait - n).min(SECTEUR as usize);
                suivant += 1;
            }
            if self
                .fichier(source)
                .read_exact_at(&mut vers[fait..fait + n], depuis)
                .is_err()
            {
                return false;
            }
            fait += n;
            a += n as u64;
        }
        true
    }

    fn ecrire(&mut self, decalage: u64, octets: &[u8]) -> bool {
        if !self.dans_le_disque(decalage, octets.len()) {
            return false;
        }
        let mut fait = 0usize;
        let mut a = decalage;
        while fait < octets.len() {
            let secteur = a / SECTEUR;
            let dedans = (a % SECTEUR) as usize;
            let n = (octets.len() - fait).min(SECTEUR as usize - dedans);
            let deja = self.places.get(&secteur).copied();
            let place = deja.unwrap_or(self.occupees);

            // Un emplacement entier à chaque fois. Le premier passage
            // recopie ce que le secteur valait — la base, ou l'emplacement
            // qu'il avait déjà — sinon les octets non écrits liraient le zéro
            // d'un emplacement neuf là où il y avait quelque chose.
            let mut entier = [0u8; SECTEUR as usize];
            if n < SECTEUR as usize {
                let (source, depuis) = self.source(secteur, 0);
                if self
                    .fichier(source)
                    .read_exact_at(&mut entier, depuis)
                    .is_err()
                {
                    return false;
                }
            }
            entier[dedans..dedans + n].copy_from_slice(&octets[fait..fait + n]);
            if self.couche.write_all_at(&entier, place * SECTEUR).is_err() {
                return false;
            }

            if deja.is_none() {
                // Le contenu d'abord, le nom ensuite : un emplacement nommé
                // dont le contenu manque rendrait des zéros pour des octets
                // qu'il prétend avoir.
                if self
                    .carte
                    .write_all_at(&secteur.to_le_bytes(), ENTETE + place * 8)
                    .is_err()
                {
                    return false;
                }
                self.places.insert(secteur, place);
                self.occupees += 1;
            }
            fait += n;
            a += n as u64;
        }
        true
    }

    fn vider(&mut self) -> bool {
        // Les deux, même si le premier échoue.
        let couche = self.couche.sync_data();
        let carte = self.carte.sync_data();
        couche.is_ok() && carte.is_ok()
    }
}

#[cfg(test)]
mod tests {
    //! **Un disque lu depuis un fichier, dont les écritures ne se perdent
    //! pas** : les onze cas du magasin de `Tests/WisqVMTests/FileDiskStoreTests.swift`,
    //! portés un pour un, son cas « à travers le périphérique », puis ce que
    //! la lecture par morceaux ajoute. Les cas d'instantané ne sont pas
    //! portés : la carte Rust n'a pas encore d'instantané.
    use super::super::pc::tests::{image, ram, PREMIER, SECOND};
    use super::super::pc::{CartePc, Disque};
    use super::*;
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicU32, Ordering};

    /// Un dossier à soi, effacé à la fin.
    struct Dossier(PathBuf);

    impl Dossier {
        fn nouveau() -> Self {
            static RANG: AtomicU32 = AtomicU32::new(0);
            let chemin = std::env::temp_dir().join(format!(
                "wisq-carte-{}-{}",
                std::process::id(),
                RANG.fetch_add(1, Ordering::Relaxed)
            ));
            let _ = std::fs::remove_dir_all(&chemin);
            std::fs::create_dir_all(&chemin).unwrap();
            Self(chemin)
        }

        /// Une base de `secteurs` secteurs, chacun rempli de son propre
        /// numéro plus un — pour qu'une lecture au mauvais endroit se voie à
        /// l'octet. La base des tests Swift.
        fn base(&self, secteurs: usize, nom: &str) -> PathBuf {
            let chemin = self.0.join(nom);
            std::fs::write(&chemin, image(secteurs, 1)).unwrap();
            chemin
        }

        fn couche(&self) -> PathBuf {
            self.0.join("disk.writes")
        }

        fn carte(&self) -> PathBuf {
            self.0.join("disk.writes.map")
        }
    }

    impl Drop for Dossier {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    fn lu(disque: &mut DisqueFichier, decalage: u64, longueur: usize) -> Option<Vec<u8>> {
        let mut octets = vec![0xEE; longueur];
        disque.lire(decalage, &mut octets).then_some(octets)
    }

    // ---------------------------------- lire, écrire, et la base qui ne bouge pas

    /// **La base n'est jamais touchée.** Écrire dans le disque écrit dans la
    /// couche ; relire le fichier de base rend ce qu'il a toujours eu.
    #[test]
    fn writes_go_to_the_overlay_and_the_base_is_never_touched() {
        let dossier = Dossier::nouveau();
        let base = dossier.base(8, "base.img");
        let avant = std::fs::read(&base).unwrap();
        let mut disque = DisqueFichier::ouvrir(&base, &dossier.couche()).unwrap();
        assert_eq!(disque.secteurs(), 8);

        assert_eq!(lu(&mut disque, 512, 4).unwrap(), [2; 4], "depuis la base");
        assert!(disque.ecrire(512, &[0xAB; 512]));
        assert_eq!(
            lu(&mut disque, 512, 4).unwrap(),
            [0xAB; 4],
            "puis la couche"
        );
        assert_eq!(lu(&mut disque, 1024, 2).unwrap(), [3, 3], "le voisin reste");

        assert!(disque.vider());
        assert_eq!(std::fs::read(&base).unwrap(), avant, "la base est intacte");
    }

    /// **Et les écritures survivent.** Fermer le disque, le rouvrir sur les
    /// mêmes fichiers : ce qui a été écrit est là, le reste vient encore de
    /// la base.
    #[test]
    fn writes_survive_closing_and_reopening() {
        let dossier = Dossier::nouveau();
        let base = dossier.base(8, "base.img");
        {
            let mut disque = DisqueFichier::ouvrir(&base, &dossier.couche()).unwrap();
            assert!(disque.ecrire(3 * 512, &[0x5A; 512]));
            assert!(disque.vider());
        }
        let mut rouvert = DisqueFichier::ouvrir(&base, &dossier.couche()).unwrap();
        assert_eq!(lu(&mut rouvert, 3 * 512, 3).unwrap(), [0x5A; 3]);
        assert_eq!(lu(&mut rouvert, 2 * 512, 3).unwrap(), [3; 3], "de la base");
        assert_eq!(rouvert.octets_ecrits(), 512, "la couche sait ce qu'elle a");
    }

    /// Une écriture qui ne couvre pas un secteur entier garde le reste du
    /// secteur.
    #[test]
    fn a_partial_sector_write_keeps_the_rest_of_the_sector() {
        let dossier = Dossier::nouveau();
        let mut disque =
            DisqueFichier::ouvrir(&dossier.base(4, "base.img"), &dossier.couche()).unwrap();
        assert!(disque.ecrire(512 + 8, &[9, 9, 9, 9]));
        let secteur = lu(&mut disque, 512, 512).unwrap();
        assert_eq!(secteur[..8], [2; 8], "avant : la base");
        assert_eq!(secteur[8..12], [9; 4], "les quatre octets écrits");
        assert_eq!(secteur[12..], [2; 500], "après : la base");
        // Une seconde écriture partielle dans le même secteur part de ce que
        // l'emplacement porte, pas de la base.
        assert!(disque.ecrire(512 + 10, &[5, 5, 5, 5]));
        let secteur = lu(&mut disque, 512, 16).unwrap();
        assert_eq!(secteur, [2, 2, 2, 2, 2, 2, 2, 2, 9, 9, 5, 5, 5, 5, 2, 2]);
        assert_eq!(disque.octets_ecrits(), 512, "un seul emplacement");
    }

    /// Une écriture à cheval sur deux secteurs touche les deux, et seulement
    /// les deux.
    #[test]
    fn a_write_straddling_two_sectors_lands_in_both() {
        let dossier = Dossier::nouveau();
        let mut disque =
            DisqueFichier::ouvrir(&dossier.base(4, "base.img"), &dossier.couche()).unwrap();
        assert!(disque.ecrire(1020, &[7; 8]));
        assert_eq!(
            lu(&mut disque, 1018, 12).unwrap(),
            [2, 2, 7, 7, 7, 7, 7, 7, 7, 7, 3, 3]
        );
        assert_eq!(disque.octets_ecrits(), 1024, "deux secteurs dans la couche");
    }

    // ------------------------------------------------------------- les bords

    /// Au-delà de la fin, rien : ni lecture qui invente, ni écriture qui
    /// agrandit.
    #[test]
    fn beyond_the_end_is_refused() {
        let dossier = Dossier::nouveau();
        let mut disque =
            DisqueFichier::ouvrir(&dossier.base(4, "base.img"), &dossier.couche()).unwrap();
        assert_eq!(lu(&mut disque, 4 * 512 - 2, 4), None, "à cheval sur la fin");
        assert_eq!(lu(&mut disque, 4 * 512, 1), None);
        assert!(!disque.ecrire(4 * 512, &[1]));
        assert!(!disque.ecrire(4 * 512 - 1, &[1, 1]), "ni à cheval");
        assert_eq!(lu(&mut disque, u64::MAX, 1), None, "sans faire le tour");
        assert_eq!(lu(&mut disque, 4 * 512 - 1, 1).unwrap(), [4], "le dernier");
        assert_eq!(disque.octets_ecrits(), 0, "un refus n'écrit rien");
        assert_eq!(std::fs::metadata(dossier.couche()).unwrap().len(), 0);
        // Une base dont la taille n'est pas un multiple de 512 : la queue
        // n'est pas du disque.
        let boiteuse = dossier.0.join("boiteuse.img");
        std::fs::write(&boiteuse, [7u8; 1024 + 100]).unwrap();
        let mut disque = DisqueFichier::ouvrir(&boiteuse, &dossier.0.join("b.writes")).unwrap();
        assert_eq!(disque.secteurs(), 2);
        assert_eq!(lu(&mut disque, 1023, 2), None);
    }

    /// **La couche est tassée** : 512 octets par secteur touché, sur la
    /// taille du fichier, pas sur ce que le système de fichiers a bien voulu
    /// allouer.
    #[test]
    fn the_overlay_is_packed_not_spread() {
        let dossier = Dossier::nouveau();
        let mut disque =
            DisqueFichier::ouvrir(&dossier.base(4000, "base.img"), &dossier.couche()).unwrap();
        assert!(disque.ecrire(3999 * 512, &[1; 512]));
        assert!(disque.vider());
        assert_eq!(std::fs::metadata(dossier.couche()).unwrap().len(), 512);
        let carte = std::fs::read(dossier.carte()).unwrap();
        assert_eq!(carte.len(), 16 + 8, "l'en-tête, et un nom d'emplacement");
        assert_eq!(&carte[..8], b"wisqdisk");
        assert_eq!(
            carte[8..16],
            4000u64.to_le_bytes(),
            "les secteurs de la base"
        );
        assert_eq!(carte[16..], 3999u64.to_le_bytes(), "et le secteur rangé");
        assert_eq!(disque.octets_ecrits(), 512);
        // Les deux fichiers portent le disque de quelqu'un : à lui seul.
        use std::os::unix::fs::PermissionsExt;
        for fichier in [dossier.couche(), dossier.carte()] {
            let droits = std::fs::metadata(&fichier).unwrap().permissions().mode();
            assert_eq!(droits & 0o777, 0o600, "{}", fichier.display());
        }

        // Un second secteur ajoute un emplacement ; le réécrire n'en ajoute
        // pas.
        assert!(disque.ecrire(0, &[7, 7, 7]));
        assert!(disque.ecrire(3999 * 512, &[2; 512]));
        assert!(disque.vider());
        assert_eq!(
            std::fs::metadata(dossier.couche()).unwrap().len(),
            1024,
            "deux emplacements, pas trois"
        );
        assert_eq!(disque.octets_ecrits(), 1024);
        assert_eq!(lu(&mut disque, 3999 * 512, 2).unwrap(), [2, 2]);
        assert_eq!(lu(&mut disque, 0, 4).unwrap(), [7, 7, 7, 1]);
    }

    /// **Un emplacement écrit mais pas encore nommé n'appartient à
    /// personne** : l'application tuée entre les deux `pwrite`.
    #[test]
    fn a_slot_written_but_not_yet_named_is_ignored() {
        let dossier = Dossier::nouveau();
        let base = dossier.base(8, "base.img");
        {
            let mut disque = DisqueFichier::ouvrir(&base, &dossier.couche()).unwrap();
            assert!(disque.ecrire(512, &[0xAB; 512]));
            assert!(disque.ecrire(1024, &[0xCD; 512]));
            assert!(disque.vider());
        }
        // La mort brutale : le second nom n'est jamais arrivé.
        let carte = std::fs::read(dossier.carte()).unwrap();
        std::fs::write(dossier.carte(), &carte[..16 + 8]).unwrap();

        let mut rouvert = DisqueFichier::ouvrir(&base, &dossier.couche()).unwrap();
        assert_eq!(
            lu(&mut rouvert, 512, 2).unwrap(),
            [0xAB; 2],
            "le premier tient"
        );
        assert_eq!(lu(&mut rouvert, 1024, 2).unwrap(), [3, 3], "de la base");
        assert_eq!(rouvert.octets_ecrits(), 512);
        assert!(rouvert.ecrire(2048, &[0xEE; 512]));
        assert_eq!(
            std::fs::metadata(dossier.couche()).unwrap().len(),
            1024,
            "le nouveau secteur a repris l'emplacement orphelin"
        );
        assert_eq!(lu(&mut rouvert, 2048, 2).unwrap(), [0xEE; 2]);
    }

    /// Une couche qui vient d'un autre disque est refusée, nommément — par
    /// son en-tête, et non par sa taille.
    #[test]
    fn an_overlay_from_another_disk_is_refused() {
        let dossier = Dossier::nouveau();
        DisqueFichier::ouvrir(&dossier.base(8, "base.img"), &dossier.couche()).unwrap();
        let autre = dossier.base(16, "other.img");
        assert_eq!(
            DisqueFichier::ouvrir(&autre, &dossier.couche()).err(),
            Some(Refus::CoucheDUnAutreDisque)
        );
        // Et un fichier qui n'est pas une carte du tout.
        let faux = dossier.0.join("bogus.writes");
        std::fs::write(dossier.0.join("bogus.writes.map"), b"pas une carte du tout").unwrap();
        assert_eq!(
            DisqueFichier::ouvrir(&dossier.base(8, "b.img"), &faux).err(),
            Some(Refus::CoucheDUnAutreDisque)
        );
        // Ni une carte plus courte que son en-tête.
        std::fs::write(dossier.0.join("court.writes.map"), b"wisqdisk").unwrap();
        assert_eq!(
            DisqueFichier::ouvrir(&dossier.base(8, "c.img"), &dossier.0.join("court.writes")).err(),
            Some(Refus::CoucheDUnAutreDisque)
        );
    }

    /// Une base qui n'est pas un disque — moins d'un secteur — est refusée,
    /// et aucune couche n'est créée pour elle.
    #[test]
    fn a_base_smaller_than_a_sector_is_refused() {
        let dossier = Dossier::nouveau();
        let minuscule = dossier.0.join("tiny");
        std::fs::write(&minuscule, [1, 2, 3]).unwrap();
        assert_eq!(
            DisqueFichier::ouvrir(&minuscule, &dossier.couche()).err(),
            Some(Refus::PasUnDisque)
        );
        assert!(!dossier.couche().exists() && !dossier.carte().exists());
    }

    /// **Une couche tronquée est refusée, pas devinée.**
    #[test]
    fn a_truncated_overlay_is_refused_rather_than_guessed() {
        let dossier = Dossier::nouveau();
        let base = dossier.base(8, "base.img");
        {
            let mut disque = DisqueFichier::ouvrir(&base, &dossier.couche()).unwrap();
            assert!(disque.ecrire(512, &[0xAB; 512]));
            assert!(disque.ecrire(1024, &[0xCD; 512]));
            assert!(disque.vider());
        }
        let contenu = std::fs::read(dossier.couche()).unwrap();
        assert_eq!(contenu.len(), 1024);
        std::fs::write(dossier.couche(), &contenu[..512]).unwrap();
        assert_eq!(
            DisqueFichier::ouvrir(&base, &dossier.couche()).err(),
            Some(Refus::CoucheTronquee)
        );
    }

    /// Une base absente est refusée avant qu'on ait créé la moindre couche.
    #[test]
    fn a_missing_base_is_refused_and_leaves_no_overlay_behind() {
        let dossier = Dossier::nouveau();
        assert_eq!(
            DisqueFichier::ouvrir(&dossier.0.join("nope.img"), &dossier.couche()).err(),
            Some(Refus::BaseIllisible)
        );
        assert!(!dossier.couche().exists() && !dossier.carte().exists());
        // Et une couche qu'on ne peut pas créer se dit, la base restant là.
        let base = dossier.base(8, "base.img");
        assert_eq!(
            DisqueFichier::ouvrir(&base, &dossier.0.join("nulle/part.writes")).err(),
            Some(Refus::CoucheIllisible)
        );
        assert_eq!(
            Refus::CoucheTronquee.to_string(),
            "la couche d'écriture du disque est incomplète."
        );
    }

    // ------------------------------------------------ la lecture par morceaux

    /// **Une lecture qui traverse la base et la couche rend chaque secteur de
    /// sa source**, que les secteurs écrits se suivent dans la couche, y
    /// soient à l'envers, ou soient séparés par des secteurs de la base. Une
    /// image tenue en mémoire fait foi, à chaque décalage et chaque longueur.
    #[test]
    fn a_read_across_base_and_overlay_takes_each_sector_from_its_source() {
        let dossier = Dossier::nouveau();
        let base = dossier.base(24, "base.img");
        let mut temoin = image(24, 1);
        let mut disque = DisqueFichier::ouvrir(&base, &dossier.couche()).unwrap();
        // Les secteurs 4, 5, 6 à la file ; 10 puis 9, à l'envers ; 12 seul ;
        // 14 et 15 séparés dans la couche par le 20 ; le 0 et le dernier.
        for (rang, secteur) in [4u64, 5, 6, 10, 9, 12, 14, 20, 15, 0, 23]
            .into_iter()
            .enumerate()
        {
            let octets = [0xA0 + rang as u8; 512];
            assert!(disque.ecrire(secteur * 512, &octets));
            temoin[secteur as usize * 512..][..512].copy_from_slice(&octets);
        }
        // Et une écriture partielle, à cheval sur un secteur écrit et un de
        // la base.
        assert!(disque.ecrire(6 * 512 + 500, &[0x11; 24]));
        temoin[6 * 512 + 500..][..24].fill(0x11);

        for decalage in [0usize, 1, 511, 512, 513, 2047, 2048, 4 * 512, 9 * 512 + 7] {
            for longueur in [0usize, 1, 2, 511, 512, 513, 1024, 1500, 4096, 6000] {
                if decalage + longueur > temoin.len() {
                    continue;
                }
                assert_eq!(
                    lu(&mut disque, decalage as u64, longueur).unwrap(),
                    temoin[decalage..decalage + longueur],
                    "{longueur} octets à {decalage}"
                );
            }
        }
        assert_eq!(
            lu(&mut disque, 0, temoin.len()).unwrap(),
            temoin,
            "en entier"
        );
        // Rouvert, le même disque.
        drop(disque);
        let mut rouvert = DisqueFichier::ouvrir(&base, &dossier.couche()).unwrap();
        assert_eq!(lu(&mut rouvert, 0, temoin.len()).unwrap(), temoin);
        assert_eq!(
            std::fs::read(&base).unwrap(),
            image(24, 1),
            "la base, intacte"
        );
    }

    /// **Une base raccourcie sous le disque ouvert est une erreur**, pas des
    /// zéros : le fichier a perdu des secteurs que le disque annonce.
    #[test]
    fn a_base_cut_short_under_the_disk_is_an_error() {
        let dossier = Dossier::nouveau();
        let base = dossier.base(8, "base.img");
        let mut disque = DisqueFichier::ouvrir(&base, &dossier.couche()).unwrap();
        std::fs::write(&base, image(4, 1)).unwrap();
        assert_eq!(lu(&mut disque, 0, 512).unwrap(), [1; 512], "ce qui reste");
        assert_eq!(lu(&mut disque, 3 * 512, 1024), None, "ce qui manque");
        // De même avec une couche : le chemin par morceaux.
        assert!(disque.ecrire(0, &[9; 512]));
        assert_eq!(lu(&mut disque, 0, 1024).unwrap()[510..514], [9, 9, 2, 2]);
        assert_eq!(lu(&mut disque, 0, 8 * 512), None);
    }

    // ------------------------------------------------ à travers la carte

    /// **La carte sert un disque sur fichier comme un disque en mémoire**,
    /// par les ports et la file, et l'écriture est là après un redémarrage :
    /// `testTheDeviceServesAFileBackedDiskAndTheWriteOutlivesIt`, puis la
    /// machine rallumée sur les mêmes fichiers.
    #[test]
    fn the_card_serves_a_file_backed_disk_and_the_write_outlives_it() {
        let dossier = Dossier::nouveau();
        let base = dossier.base(8, "base.img");
        let avant = std::fs::read(&base).unwrap();
        {
            let mut carte = CartePc::nouvelle();
            carte.brancher(
                Disque::Premier,
                DisqueFichier::ouvrir(&base, &dossier.couche()).unwrap(),
            );
            PREMIER.ouvrir(&mut carte);
            let mut ram = ram();
            assert_eq!(
                carte.port_lire(0xC014, 4),
                Some(8),
                "la capacité du fichier"
            );
            // Lire le secteur 5 : ses octets valent six.
            PREMIER.requete(&mut ram, 0, 0, 5, (0x10_0000, 512));
            PREMIER.notifier(&mut carte);
            assert_eq!(carte.servir(&mut ram), 1);
            assert_eq!(PREMIER.statut(&ram, 0), 0);
            assert_eq!(ram.0[0x10_0000..0x10_0200], [6; 512]);
            // Écrire le secteur 2.
            ram.0[0x20_0000..0x20_0200].fill(0xCD);
            PREMIER.requete(&mut ram, 1, 1, 2, (0x20_0000, 512));
            PREMIER.notifier(&mut carte);
            assert_eq!(carte.servir(&mut ram), 1);
            assert_eq!(PREMIER.statut(&ram, 1), 0);
            assert_eq!(carte.carte().disque(Disque::Premier).unwrap().servies, 2);
            assert!(carte.vider());
        }
        // La machine rallumée : une carte neuve, les mêmes fichiers.
        let mut carte = CartePc::nouvelle();
        carte.brancher(
            Disque::Premier,
            DisqueFichier::ouvrir(&base, &dossier.couche()).unwrap(),
        );
        PREMIER.ouvrir(&mut carte);
        let mut ram = ram();
        PREMIER.requete(&mut ram, 0, 0, 1, (0x10_0000, 1536));
        PREMIER.notifier(&mut carte);
        assert_eq!(carte.servir(&mut ram), 1);
        assert_eq!(
            ram.0[0x10_0000..0x10_0200],
            [2; 512],
            "le secteur un, la base"
        );
        assert_eq!(
            ram.0[0x10_0200..0x10_0400],
            [0xCD; 512],
            "l'écriture a survécu"
        );
        assert_eq!(ram.0[0x10_0400..0x10_0600], [4; 512]);
        assert_eq!(
            std::fs::read(&base).unwrap(),
            avant,
            "et la base n'a rien vu"
        );
        // Le secteur huit n'existe pas : une erreur, sans toucher au fichier.
        PREMIER.requete(&mut ram, 1, 1, 8, (0x20_0000, 512));
        PREMIER.notifier(&mut carte);
        carte.servir(&mut ram);
        assert_eq!(PREMIER.statut(&ram, 1), 1);
        assert_eq!(std::fs::metadata(dossier.couche()).unwrap().len(), 512);
    }

    /// **Deux disques sur fichier, chacun sa couche** : l'ISO qu'on démarre
    /// et le disque vierge qu'on installe à côté. Ce que l'invité écrit sur
    /// le second ne paraît ni dans la base, ni dans la couche du premier.
    #[test]
    fn two_file_backed_disks_keep_their_writes_apart() {
        let dossier = Dossier::nouveau();
        let iso = dossier.base(8, "live.iso");
        let vierge = dossier.0.join("vierge.img");
        std::fs::write(&vierge, vec![0u8; 16 * 512]).unwrap();
        let (couche_iso, couche_vierge) = (dossier.0.join("a.writes"), dossier.0.join("b.writes"));
        let mut carte = CartePc::nouvelle();
        carte.brancher(
            Disque::Premier,
            DisqueFichier::ouvrir(&iso, &couche_iso).unwrap(),
        );
        carte.brancher(
            Disque::Second,
            DisqueFichier::ouvrir(&vierge, &couche_vierge).unwrap(),
        );
        PREMIER.ouvrir(&mut carte);
        SECOND.ouvrir(&mut carte);
        let mut ram = ram();
        assert_eq!(carte.port_lire(0xC054, 4), Some(16));
        // Recopier le secteur 3 de l'ISO au secteur 9 du disque vierge,
        // comme un installateur : lire sur l'un, écrire sur l'autre.
        PREMIER.requete(&mut ram, 0, 0, 3, (0x10_0000, 512));
        PREMIER.notifier(&mut carte);
        carte.servir(&mut ram);
        SECOND.requete(&mut ram, 0, 1, 9, (0x10_0000, 512));
        SECOND.notifier(&mut carte);
        assert_eq!(carte.servir(&mut ram), 1);
        assert_eq!(SECOND.statut(&ram, 0), 0);
        assert!(carte.vider());
        drop(carte);

        assert_eq!(
            std::fs::metadata(&couche_iso).unwrap().len(),
            0,
            "rien sur l'ISO"
        );
        assert_eq!(std::fs::read(&couche_vierge).unwrap(), [4u8; 512]);
        assert_eq!(std::fs::read(&vierge).unwrap(), vec![0u8; 16 * 512]);
        let mut rouvert = DisqueFichier::ouvrir(&vierge, &couche_vierge).unwrap();
        assert_eq!(lu(&mut rouvert, 9 * 512, 512).unwrap(), [4; 512]);
        assert_eq!(lu(&mut rouvert, 8 * 512, 512).unwrap(), [0; 512]);
    }
}
