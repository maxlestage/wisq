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
//! écrite en fait un, pas deux mille quarante-huit. Le disque compte ses
//! lectures de fichier ([`DisqueFichier::lectures`]), et c'est ce compte que
//! les tests tiennent : un retour au `pread` par secteur rendrait les mêmes
//! octets, deux à quatre fois moins vite, sans qu'un test d'octets le voie.
//!
//! **Les formats à tables** (qcow2, VMDK, VDI, VHD, VHDX, OVA) ne sont pas
//! lus ici : leurs octets ne sont pas ceux du disque, et ce crate lit sa base
//! octet pour octet. Un disque dans un de ces formats s'ouvre par
//! [`DisqueFichier::ouvrir_sur`], sur un [`Lecteur`] que l'appelant fournit —
//! dans l'application, le lecteur du cœur Swift (`VirtualDiskImages`),
//! atteint par l'ABI C (`wisq_pc_attach_disk_reader`). **La couche ne change
//! pas** : elle range des secteurs du disque, d'où qu'ils viennent, et c'est
//! la même que celle de `FileDiskStore` sur la même image.

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

/// **Une base lue par un autre** : un disque dont les octets ne sont pas
/// ceux du fichier (un qcow2, un VMDK…), traduits par qui sait les lire.
/// [`DisqueFichier`] range les écritures de l'invité dans sa couche, comme
/// pour un fichier brut, et ne demande au lecteur que les secteurs que
/// personne n'a écrits — par suites, comme il lit un fichier : une lecture
/// d'un mébioctet que la couche ne touche pas est un seul appel.
///
/// **Lecture seule**, et c'est le contrat de `VirtualDiskImage` côté Swift :
/// rien n'est jamais écrit dans la base.
pub trait Lecteur: Send {
    /// La taille du disque que voit l'invité, en octets — pas celle du
    /// fichier. Lue une fois, à l'ouverture.
    fn taille(&self) -> u64;

    /// **Remplir `vers` en entier** depuis `decalage`, en octets. Toujours
    /// dans le disque (`decalage + vers.len()` au plus [`Lecteur::taille`]) ;
    /// `false` si le fichier ne rend pas ce que ses tables promettent — le
    /// disque répond alors une erreur d'entrée-sortie, jamais des zéros.
    fn lire(&mut self, decalage: u64, vers: &mut [u8]) -> bool;
}

/// La base : le fichier lui-même, ou un lecteur qui le traduit.
enum Base {
    Fichier(File),
    Lecteur(Box<dyn Lecteur>),
}

/// D'où vient un secteur.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Source {
    Base,
    Couche,
}

/// **Le disque** : la base, sa couche, et la carte des emplacements.
pub struct DisqueFichier {
    base: Base,
    couche: File,
    carte: File,
    secteurs: u64,
    /// Quel emplacement porte quel secteur. En mémoire seulement : la carte
    /// sur le disque est la liste des secteurs, dans l'ordre des
    /// emplacements.
    places: HashMap<u64, u64>,
    occupees: u64,
    /// Combien de fois un fichier a été lu depuis l'ouverture.
    lectures: u64,
}

impl DisqueFichier {
    /// **Ouvrir un disque** : `base`, lue sur place et jamais modifiée, et
    /// `couche`, où vont les écritures (sa carte est `couche` suivi de
    /// `.map`). Les deux fichiers de la couche sont créés s'ils n'existent
    /// pas ; s'ils existent, ce qu'ils portent est repris.
    pub fn ouvrir(base: &Path, couche: &Path) -> Result<Self, Refus> {
        let base = File::open(base).map_err(|_| Refus::BaseIllisible)?;
        let taille = base.metadata().map_err(|_| Refus::BaseIllisible)?.len();
        Self::ouvrir_base(Base::Fichier(base), taille, couche)
    }

    /// **Ouvrir un disque dont la base est lue par `lecteur`** : un qcow2, un
    /// VMDK, que l'appelant sait traduire. La taille est celle que le lecteur
    /// annonce ; la couche, ses refus et son format sont ceux de
    /// [`DisqueFichier::ouvrir`]. Le lecteur est rendu (lâché) avec le refus.
    pub fn ouvrir_sur(lecteur: Box<dyn Lecteur>, couche: &Path) -> Result<Self, Refus> {
        let taille = lecteur.taille();
        Self::ouvrir_base(Base::Lecteur(lecteur), taille, couche)
    }

    fn ouvrir_base(base: Base, taille: u64, couche: &Path) -> Result<Self, Refus> {
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
            lectures: 0,
        })
    }

    /// **Combien de lectures de fichier** (`pread`) ce disque a faites
    /// depuis son ouverture : la mesure de la lecture par morceaux. Une
    /// requête d'un mébioctet dans une base que personne n'a écrite en
    /// compte une, pas deux mille quarante-huit — et c'est ce compte, pas un
    /// débit, qu'un test peut tenir.
    pub fn lectures(&self) -> u64 {
        self.lectures
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

    /// **Une lecture de fichier, comptée** : remplir `vers` en entier depuis
    /// `depuis`, dans le fichier de `source` — ou par le lecteur de la base,
    /// qui compte de même. `false` si le fichier ne les a pas tous.
    fn lire_dans(&mut self, source: Source, vers: &mut [u8], depuis: u64) -> bool {
        self.lectures += 1;
        match (source, &mut self.base) {
            (Source::Couche, _) => self.couche.read_exact_at(vers, depuis).is_ok(),
            (Source::Base, Base::Fichier(fichier)) => fichier.read_exact_at(vers, depuis).is_ok(),
            (Source::Base, Base::Lecteur(lecteur)) => lecteur.lire(depuis, vers),
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
        let mut fait = 0usize;
        let mut a = decalage;
        while fait < vers.len() {
            let (secteur, dedans) = (a / SECTEUR, a % SECTEUR);
            let (source, depuis) = self.source(secteur, dedans);
            // Ce morceau s'étend tant que les secteurs suivants se suivent
            // aussi dans le fichier d'où celui-ci vient : la base toujours,
            // la couche quand ils y ont été écrits à la file. Une base que
            // personne n'a écrite — une ISO — se lit donc d'un trait, sans
            // chemin à part : un raccourci « couche vide » a été mesuré
            // (cinq courses alternées sur une ISO de 1,4 Gio) et ne rendait
            // rien qui sorte du bruit.
            let mut n = (vers.len() - fait).min((SECTEUR - dedans) as usize);
            let mut suivant = secteur + 1;
            while fait + n < vers.len() && self.source(suivant, 0) == (source, depuis + n as u64) {
                n += (vers.len() - fait - n).min(SECTEUR as usize);
                suivant += 1;
            }
            if !self.lire_dans(source, &mut vers[fait..fait + n], depuis) {
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
                if !self.lire_dans(source, &mut entier, depuis) {
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

    /// 512 octets par secteur touché (`FileDiskStore.bytesWritten`).
    fn octets_ecrits(&self) -> u64 {
        self.occupees * SECTEUR
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
        // **Le bord exact**, comme `FileDiskStore.inRange` et le disque en
        // mémoire : rien du tout, posé à la fin, est dans le disque ; rien du
        // tout, posé un octet plus loin, n'y est pas — une longueur nulle
        // n'ouvre pas le disque au-delà de sa fin.
        assert_eq!(lu(&mut disque, 4 * 512, 0), Some(vec![]), "rien, à la fin");
        assert!(disque.ecrire(4 * 512, &[]));
        assert_eq!(lu(&mut disque, 4 * 512 + 1, 0), None, "rien, au-delà");
        assert!(!disque.ecrire(4 * 512 + 1, &[]));
        assert_eq!(lu(&mut disque, u64::MAX, 0), None);
        assert!(!disque.ecrire(u64::MAX, &[]));
        assert_eq!(disque.lectures(), 1, "le dernier octet, et lui seul");
        assert_eq!(disque.octets_ecrits(), 0, "un refus n'écrit rien");
        assert_eq!(std::fs::metadata(dossier.couche()).unwrap().len(), 0);
        // Une base dont la taille n'est pas un multiple de 512 : la queue
        // n'est pas du disque.
        let boiteuse = dossier.0.join("boiteuse.img");
        std::fs::write(&boiteuse, [7u8; 1024 + 100]).unwrap();
        let mut disque = DisqueFichier::ouvrir(&boiteuse, &dossier.0.join("b.writes")).unwrap();
        assert_eq!(disque.secteurs(), 2);
        assert_eq!(lu(&mut disque, 1023, 2), None);
        // Même pour rien : la queue est dans le fichier, pas dans le disque.
        assert_eq!(lu(&mut disque, 1024, 0), Some(vec![]));
        assert_eq!(lu(&mut disque, 1025, 0), None);
        assert!(disque.ecrire(1024, &[]) && !disque.ecrire(1025, &[]));
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
        // **La marque seule suffit à refuser** : huit octets qui ne sont pas
        // `wisqdisk`, suivis du bon nombre de secteurs — le fichier d'un
        // autre programme qui aurait, par hasard ou non, la bonne taille.
        for marque in [b"wisqdisq", b"WISQDISK", b"\0\0\0\0\0\0\0\0"] {
            let mut etrangere = marque.to_vec();
            etrangere.extend_from_slice(&8u64.to_le_bytes());
            std::fs::write(dossier.0.join("marque.writes.map"), &etrangere).unwrap();
            assert_eq!(
                DisqueFichier::ouvrir(&dossier.base(8, "m.img"), &dossier.0.join("marque.writes"))
                    .err(),
                Some(Refus::CoucheDUnAutreDisque),
                "{marque:?}"
            );
        }
        // Et la bonne marque avec ce compte-là est bien prise : c'est la
        // marque, et elle seule, que les trois cas d'avant ont jugée.
        let mut juste = b"wisqdisk".to_vec();
        juste.extend_from_slice(&8u64.to_le_bytes());
        std::fs::write(dossier.0.join("marque.writes.map"), &juste).unwrap();
        assert!(
            DisqueFichier::ouvrir(&dossier.base(8, "m.img"), &dossier.0.join("marque.writes"))
                .is_ok()
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
        // **Le bord exact** : un octet de moins qu'un secteur n'est pas un
        // disque ; un secteur tout juste en est un, d'un secteur ; un octet
        // de plus n'en ajoute pas (`size / sectorSize >= 1`).
        std::fs::write(&minuscule, [7; 511]).unwrap();
        assert_eq!(
            DisqueFichier::ouvrir(&minuscule, &dossier.couche()).err(),
            Some(Refus::PasUnDisque)
        );
        assert!(!dossier.couche().exists() && !dossier.carte().exists());
        for taille in [512, 513] {
            let dossier = Dossier::nouveau();
            let juste = dossier.0.join("un-secteur");
            std::fs::write(&juste, vec![7; taille]).unwrap();
            let mut disque = DisqueFichier::ouvrir(&juste, &dossier.couche())
                .unwrap_or_else(|refus| panic!("{taille} octets : {refus}"));
            assert_eq!(disque.secteurs(), 1, "{taille} octets");
            assert_eq!(lu(&mut disque, 0, 512).unwrap(), [7; 512]);
            assert_eq!(
                lu(&mut disque, 512, 1),
                None,
                "la queue n'est pas du disque"
            );
        }
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
    }

    /// **Les cinq refus disent les cinq phrases du cœur Swift**
    /// (`FileDiskStore.Failure.errorDescription`), mot pour mot : c'est ce
    /// que l'application montre à la personne dont le disque ne s'ouvre pas.
    #[test]
    fn each_refusal_says_the_sentence_of_the_swift_core() {
        let phrases = [
            (Refus::BaseIllisible, "le disque n'a pas pu être ouvert."),
            (Refus::PasUnDisque, "le disque fait moins d'un secteur."),
            (
                Refus::CoucheIllisible,
                "la couche d'écriture du disque n'a pas pu être créée.",
            ),
            (
                Refus::CoucheDUnAutreDisque,
                "la couche d'écriture trouvée appartient à un autre disque.",
            ),
            (
                Refus::CoucheTronquee,
                "la couche d'écriture du disque est incomplète.",
            ),
        ];
        for (refus, phrase) in phrases {
            assert_eq!(refus.to_string(), phrase, "{refus:?}");
            // Et par le trait d'erreur, comme `?` la remonte.
            let erreur: Box<dyn std::error::Error> = Box::new(refus);
            assert_eq!(erreur.to_string(), phrase);
        }
    }

    // ------------------------------------------------ la lecture par morceaux

    /// **Une lecture qui traverse la base et la couche rend chaque secteur de
    /// sa source**, que les secteurs écrits se suivent dans la couche, y
    /// soient à l'envers, ou soient séparés par des secteurs de la base. Une
    /// image tenue en mémoire fait foi, à neuf décalages et dix longueurs
    /// choisis autour des bords de secteur, puis d'un bout à l'autre.
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

    /// **Une lecture de fichier par suite de secteurs, pas par secteur** :
    /// c'est le gain de la lecture par morceaux, et un retour au `pread` par
    /// secteur rendrait les mêmes octets. Le disque compte donc ses lectures
    /// de fichier, et ce cas tient le compte.
    #[test]
    fn a_read_costs_one_file_read_per_run_of_sectors() {
        let dossier = Dossier::nouveau();
        let base = dossier.base(2048, "base.img");
        let mut disque = DisqueFichier::ouvrir(&base, &dossier.couche()).unwrap();
        let lectures = |disque: &mut DisqueFichier, decalage: u64, longueur: usize| {
            let avant = disque.lectures();
            lu(disque, decalage, longueur).expect("dans le disque");
            disque.lectures() - avant
        };
        assert_eq!(disque.lectures(), 0, "ouvrir ne lit pas la base");
        // Une base que personne n'a écrite : un mébioctet, une lecture.
        assert_eq!(lectures(&mut disque, 0, 2048 * 512), 1, "une ISO, un trait");
        assert_eq!(lectures(&mut disque, 700, 5000), 1, "de travers aussi");
        assert_eq!(lectures(&mut disque, 0, 0), 0, "rien à lire, rien de lu");
        assert_eq!(lu(&mut disque, 2048 * 512, 1), None);
        assert_eq!(disque.lectures(), 2, "un refus ne lit rien");

        // Trois secteurs écrits à la file se suivent dans la couche. Un
        // secteur entier s'écrit sans rien relire.
        let avant = disque.lectures();
        for secteur in [100u64, 101, 102] {
            assert!(disque.ecrire(secteur * 512, &[0xC0; 512]));
        }
        assert_eq!(disque.lectures(), avant, "trois écritures entières");
        // La base, la couche, la base : trois lectures pour 2 048 secteurs.
        assert_eq!(lectures(&mut disque, 0, 2048 * 512), 3);
        assert_eq!(
            lectures(&mut disque, 100 * 512, 3 * 512),
            1,
            "la couche seule"
        );
        assert_eq!(lectures(&mut disque, 101 * 512 + 9, 600), 1);
        assert_eq!(
            lectures(&mut disque, 102 * 512, 1024),
            2,
            "couche, puis base"
        );
        // Écrits à l'envers, 104 puis 103 ne se suivent pas dans la couche :
        // chacun sa lecture, et pas un trait qui les lirait dans le désordre.
        assert!(disque.ecrire(104 * 512, &[0xC4; 512]));
        assert!(disque.ecrire(103 * 512, &[0xC3; 512]));
        assert_eq!(lectures(&mut disque, 100 * 512, 5 * 512), 3);
        assert_eq!(
            lu(&mut disque, 103 * 512 - 1, 514).unwrap()[..3],
            [0xC0, 0xC3, 0xC3]
        );
        assert_eq!(
            lu(&mut disque, 104 * 512 - 1, 3).unwrap(),
            [0xC3, 0xC4, 0xC4]
        );
        // Une écriture partielle relit son secteur, une fois ; à cheval sur
        // deux secteurs, les deux.
        let avant = disque.lectures();
        assert!(disque.ecrire(7 * 512 + 3, &[1, 2, 3]));
        assert_eq!(disque.lectures(), avant + 1);
        assert!(disque.ecrire(9 * 512 - 2, &[1, 2, 3, 4]));
        assert_eq!(disque.lectures(), avant + 3);
    }

    /// **Six mille lectures et écritures tirées au hasard, contre une image
    /// tenue en mémoire** : n'importe quel décalage, n'importe quelle
    /// longueur jusqu'à sept secteurs, sur une base dont la queue n'est pas
    /// du disque, avec des fermetures et des réouvertures en route. Un
    /// refus — au-delà de la fin — ne touche à rien.
    #[test]
    fn random_reads_and_writes_match_an_image_kept_in_memory() {
        const SECTEURS: usize = 96;
        const TAILLE: usize = SECTEURS * 512;
        let dossier = Dossier::nouveau();
        let base = dossier.0.join("boiteuse.img");
        // Chaque octet de la base dit où il est, et la queue fait 300 octets.
        let contenu: Vec<u8> = (0..TAILLE + 300).map(|i| (i * 7 + i / 512) as u8).collect();
        std::fs::write(&base, &contenu).unwrap();
        let mut temoin = contenu[..TAILLE].to_vec();
        let mut disque = DisqueFichier::ouvrir(&base, &dossier.couche()).unwrap();
        assert_eq!(disque.secteurs(), SECTEURS as u64);

        // Un générateur à décalages (xorshift64) : la même suite à chaque
        // course.
        let mut etat = 0x9E37_79B9_7F4A_7C15u64;
        let mut hasard = move |borne: usize| {
            etat ^= etat << 13;
            etat ^= etat >> 7;
            etat ^= etat << 17;
            (etat % borne as u64) as usize
        };
        let (mut refus, mut ecritures) = (0, 0);
        for tour in 0..6000 {
            // Un peu au-delà de la fin, pour que les refus soient du voyage.
            let decalage = hasard(TAILLE + 600);
            let longueur = hasard(7 * 512 + 1);
            let dedans = decalage + longueur <= TAILLE;
            if hasard(3) == 0 {
                let octets: Vec<u8> = (0..longueur).map(|i| (tour + i * 3) as u8).collect();
                assert_eq!(
                    disque.ecrire(decalage as u64, &octets),
                    dedans,
                    "tour {tour}"
                );
                if dedans {
                    temoin[decalage..decalage + longueur].copy_from_slice(&octets);
                    ecritures += 1;
                }
            } else {
                let rendu = lu(&mut disque, decalage as u64, longueur);
                let attendu = dedans.then(|| temoin[decalage..decalage + longueur].to_vec());
                assert_eq!(
                    rendu, attendu,
                    "tour {tour} : {longueur} octets à {decalage}"
                );
            }
            refus += usize::from(!dedans);
            if tour % 500 == 499 {
                // La machine éteinte et rallumée : la couche reprend.
                assert!(disque.vider());
                let ecrits = disque.octets_ecrits();
                disque = DisqueFichier::ouvrir(&base, &dossier.couche()).unwrap();
                assert_eq!(disque.octets_ecrits(), ecrits, "tour {tour}");
                assert_eq!(lu(&mut disque, 0, TAILLE).unwrap(), temoin, "tour {tour}");
            }
        }
        assert!(
            refus > 100 && ecritures > 1000,
            "{refus} refus, {ecritures} écritures"
        );
        assert_eq!(
            disque.octets_ecrits(),
            TAILLE as u64,
            "tout le disque y est passé"
        );
        assert_eq!(std::fs::read(&base).unwrap(), contenu, "la base, intacte");
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
        // **Une écriture partielle dans un secteur que la base a perdu est
        // une erreur aussi** : elle doit d'abord recopier ce que le secteur
        // valait, et il n'y est plus. La dire réussie rangerait des zéros
        // autour des octets écrits, à la place de ce que le disque portait.
        let avant = (
            disque.octets_ecrits(),
            std::fs::read(dossier.carte()).unwrap(),
        );
        assert!(
            !disque.ecrire(5 * 512 + 10, &[7; 20]),
            "le secteur 5 manque"
        );
        assert!(!disque.ecrire(3 * 512 + 500, &[7; 100]), "le 4 aussi");
        assert_eq!(
            disque.octets_ecrits(),
            avant.0 + 512,
            "le 3 seul, entier là"
        );
        assert_eq!(lu(&mut disque, 5 * 512, 512), None, "toujours une erreur");
        assert_eq!(lu(&mut disque, 4 * 512, 512), None);
        // Un secteur écrit en entier, lui, n'a rien à recopier : il passe.
        assert!(disque.ecrire(6 * 512, &[8; 512]));
        assert_eq!(lu(&mut disque, 6 * 512, 512).unwrap(), [8; 512]);
        assert_eq!(
            std::fs::read(dossier.carte()).unwrap().len(),
            avant.1.len() + 16,
            "deux noms de plus : le 3 et le 6"
        );
    }

    /// **Une couche où l'on ne peut pas écrire est une erreur d'écriture**,
    /// pas une écriture réussie qu'on ne relira jamais : la couche est ici
    /// `/dev/full`, où toute écriture échoue faute de place. Rien n'est
    /// nommé dans la carte, rien n'est compté, et le secteur se relit de la
    /// base. Et une carte où l'en-tête ne s'écrit pas est une couche
    /// illisible, à l'ouverture.
    #[cfg(target_os = "linux")]
    #[test]
    fn a_layer_that_cannot_be_written_is_an_error() {
        let dossier = Dossier::nouveau();
        let base = dossier.base(8, "base.img");
        std::os::unix::fs::symlink("/dev/full", dossier.couche()).unwrap();
        let mut disque = DisqueFichier::ouvrir(&base, &dossier.couche()).unwrap();
        assert!(!disque.ecrire(512, &[0xAB; 512]), "un secteur entier");
        assert!(
            !disque.ecrire(1024 + 7, &[0xAB; 3]),
            "une écriture partielle"
        );
        assert!(!disque.ecrire(0, &[0xAB; 8 * 512]), "tout le disque");
        assert_eq!(disque.octets_ecrits(), 0, "rien n'est compté");
        assert_eq!(
            std::fs::read(dossier.carte()).unwrap().len(),
            16,
            "l'en-tête seul : aucun emplacement nommé"
        );
        assert_eq!(lu(&mut disque, 512, 512).unwrap(), [2; 512], "la base");
        assert_eq!(lu(&mut disque, 1024, 512).unwrap(), [3; 512]);
        drop(disque);
        // Rouverte sur une vraie couche, la même carte ne nomme rien.
        std::fs::remove_file(dossier.couche()).unwrap();
        let mut disque = DisqueFichier::ouvrir(&base, &dossier.couche()).unwrap();
        assert_eq!(disque.octets_ecrits(), 0);
        assert!(disque.ecrire(512, &[0xAB; 512]));
        assert_eq!(lu(&mut disque, 512, 512).unwrap(), [0xAB; 512]);

        // La carte, cette fois : son en-tête ne s'écrit pas.
        let dossier = Dossier::nouveau();
        let base = dossier.base(8, "base.img");
        std::os::unix::fs::symlink("/dev/full", dossier.carte()).unwrap();
        assert_eq!(
            DisqueFichier::ouvrir(&base, &dossier.couche()).err(),
            Some(Refus::CoucheIllisible)
        );
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
            // Ce que le rapport de stockage lit sur la machine vivante.
            assert_eq!(carte.octets_ecrits(Disque::Premier), 512);
            assert_eq!(carte.octets_ecrits(Disque::Second), 0);
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
        assert_eq!(carte.octets_ecrits(Disque::Premier), 0, "rien sur l'ISO");
        assert_eq!(carte.octets_ecrits(Disque::Second), 512, "un secteur");
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

    // ------------------------------------------------ une base lue par un autre

    /// **Un lecteur de test** : un disque tenu en mémoire, qui note chaque
    /// appel et refuse de servir quoi que ce soit hors de lui — le contrat de
    /// [`Lecteur::lire`] est que le disque ne lui demande jamais rien
    /// au-delà de sa taille. `panne` : la plage où il rend `false`, comme un
    /// qcow2 dont une table ment.
    struct Image {
        octets: Vec<u8>,
        appels: std::sync::Arc<std::sync::Mutex<Vec<(u64, usize)>>>,
        panne: Option<std::ops::Range<u64>>,
        lache: std::sync::Arc<std::sync::atomic::AtomicBool>,
    }

    impl Image {
        fn nouvelle(octets: Vec<u8>) -> Self {
            Self {
                octets,
                appels: Default::default(),
                panne: None,
                lache: Default::default(),
            }
        }
    }

    impl Lecteur for Image {
        fn taille(&self) -> u64 {
            self.octets.len() as u64
        }

        fn lire(&mut self, decalage: u64, vers: &mut [u8]) -> bool {
            self.appels.lock().unwrap().push((decalage, vers.len()));
            let fin = decalage + vers.len() as u64;
            assert!(fin <= self.taille(), "{} octets à {decalage}", vers.len());
            if let Some(panne) = &self.panne {
                if decalage < panne.end && panne.start < fin {
                    return false;
                }
            }
            vers.copy_from_slice(&self.octets[decalage as usize..fin as usize]);
            true
        }
    }

    impl Drop for Image {
        fn drop(&mut self) {
            self.lache.store(true, std::sync::atomic::Ordering::SeqCst);
        }
    }

    /// **La base vient du lecteur, les écritures vont dans la couche** : la
    /// taille est celle qu'il annonce (sa queue n'est pas du disque), chaque
    /// suite de secteurs que personne n'a écrits est un seul appel, un
    /// secteur écrit ne lui est plus jamais demandé, et une écriture
    /// partielle lui demande le secteur qu'elle recopie, une fois.
    #[test]
    fn a_base_read_by_a_reader_is_asked_by_runs_and_never_for_written_sectors() {
        let dossier = Dossier::nouveau();
        let mut octets = image(2048, 1);
        octets.extend_from_slice(&[0xEE; 300]);
        let lecteur = Image::nouvelle(octets);
        let appels = lecteur.appels.clone();
        let mut disque = DisqueFichier::ouvrir_sur(Box::new(lecteur), &dossier.couche()).unwrap();
        assert_eq!(disque.secteurs(), 2048, "la queue n'est pas du disque");
        assert!(appels.lock().unwrap().is_empty(), "ouvrir ne lit rien");

        assert_eq!(lu(&mut disque, 0, 2048 * 512).unwrap(), image(2048, 1));
        assert_eq!(
            *appels.lock().unwrap(),
            [(0, 2048 * 512)],
            "un mébioctet, un appel"
        );
        assert_eq!(lu(&mut disque, 2048 * 512 - 1, 2), None, "au-delà");
        assert_eq!(appels.lock().unwrap().len(), 1, "un refus ne demande rien");

        appels.lock().unwrap().clear();
        assert!(
            disque.ecrire(100 * 512, &[0xC0; 1024]),
            "deux secteurs entiers"
        );
        assert!(appels.lock().unwrap().is_empty(), "rien à recopier");
        assert!(disque.ecrire(7 * 512 + 3, &[9, 9, 9]));
        assert_eq!(
            *appels.lock().unwrap(),
            [(7 * 512, 512)],
            "le secteur recopié"
        );

        appels.lock().unwrap().clear();
        let lu_ = lu(&mut disque, 99 * 512, 4 * 512).unwrap();
        assert_eq!(lu_[..512], [100; 512], "le 99, du lecteur");
        assert_eq!(
            lu_[512..1536],
            [0xC0; 1024],
            "le 100 et le 101, de la couche"
        );
        assert_eq!(lu_[1536..], [103; 512], "le 102, du lecteur");
        assert_eq!(
            *appels.lock().unwrap(),
            [(99 * 512, 512), (102 * 512, 512)],
            "les secteurs écrits ne sont plus demandés"
        );
        let septieme = lu(&mut disque, 7 * 512, 512).unwrap();
        assert_eq!(septieme[..3], [8, 8, 8]);
        assert_eq!(septieme[3..6], [9, 9, 9]);
        assert_eq!(septieme[6..], [8; 506]);
        assert_eq!(appels.lock().unwrap().len(), 2, "le 7 vient de la couche");
        assert_eq!(disque.octets_ecrits(), 3 * 512);
        assert!(disque.vider());

        // Rouvert sur un lecteur neuf, la couche reprend.
        drop(disque);
        let mut rouvert =
            DisqueFichier::ouvrir_sur(Box::new(Image::nouvelle(image(2048, 1))), &dossier.couche())
                .unwrap();
        assert_eq!(lu(&mut rouvert, 100 * 512, 2).unwrap(), [0xC0; 2]);
        assert_eq!(rouvert.octets_ecrits(), 3 * 512);
    }

    /// **Le même disque, lu par un lecteur ou dans un fichier brut, fait la
    /// même couche, octet pour octet** : les mêmes écritures tirées au
    /// hasard, de part et d'autre, rendent les mêmes deux fichiers ; chacun
    /// rouvre ensuite la couche de l'autre. C'est ce qui laisse une machine
    /// changer de cœur sans que sa couche change de sens.
    #[test]
    fn a_reader_and_a_raw_file_with_the_same_bytes_make_the_same_overlay() {
        let dossier = Dossier::nouveau();
        let base = dossier.base(64, "base.img");
        let brut_couche = dossier.0.join("brut.writes");
        let lu_couche = dossier.0.join("lu.writes");
        let mut brut = DisqueFichier::ouvrir(&base, &brut_couche).unwrap();
        let mut lecteur =
            DisqueFichier::ouvrir_sur(Box::new(Image::nouvelle(image(64, 1))), &lu_couche).unwrap();
        let mut etat = 0x2545_F491_4F6C_DD1Du64;
        let mut hasard = move |borne: u64| {
            etat ^= etat << 13;
            etat ^= etat >> 7;
            etat ^= etat << 17;
            etat % borne
        };
        for tour in 0..800u64 {
            let decalage = hasard(64 * 512 + 100);
            let longueur = hasard(3 * 512) as usize;
            if hasard(2) == 0 {
                let octets: Vec<u8> = (0..longueur).map(|i| (tour as usize + i) as u8).collect();
                assert_eq!(
                    brut.ecrire(decalage, &octets),
                    lecteur.ecrire(decalage, &octets),
                    "tour {tour}"
                );
            } else {
                assert_eq!(
                    lu(&mut brut, decalage, longueur),
                    lu(&mut lecteur, decalage, longueur),
                    "tour {tour}"
                );
            }
        }
        assert!(brut.vider() && lecteur.vider());
        assert!(brut.octets_ecrits() > 20 * 512);
        assert_eq!(brut.octets_ecrits(), lecteur.octets_ecrits());
        let tout = lu(&mut brut, 0, 64 * 512).unwrap();
        assert_eq!(lu(&mut lecteur, 0, 64 * 512).unwrap(), tout);
        drop((brut, lecteur));
        assert_eq!(
            std::fs::read(&brut_couche).unwrap(),
            std::fs::read(&lu_couche).unwrap()
        );
        let carte = |c: &PathBuf| std::fs::read(format!("{}.map", c.display())).unwrap();
        assert_eq!(carte(&brut_couche), carte(&lu_couche));
        // Chacun relit la couche de l'autre.
        let mut croise =
            DisqueFichier::ouvrir_sur(Box::new(Image::nouvelle(image(64, 1))), &brut_couche)
                .unwrap();
        assert_eq!(lu(&mut croise, 0, 64 * 512).unwrap(), tout);
        let mut croise = DisqueFichier::ouvrir(&base, &lu_couche).unwrap();
        assert_eq!(lu(&mut croise, 0, 64 * 512).unwrap(), tout);
    }

    /// **Ce qu'un lecteur ne sait pas rendre est une erreur, pas des
    /// zéros** ; moins d'un secteur n'est pas un disque, et n'a pas de
    /// couche ; une couche d'un autre disque est refusée comme pour un
    /// fichier ; et le lecteur d'un disque refusé est lâché avec le refus.
    #[test]
    fn a_reader_that_fails_is_an_error_and_a_refused_reader_is_dropped() {
        let dossier = Dossier::nouveau();
        let mut lecteur = Image::nouvelle(image(16, 1));
        lecteur.panne = Some(5 * 512 + 10..5 * 512 + 11);
        let mut disque = DisqueFichier::ouvrir_sur(Box::new(lecteur), &dossier.couche()).unwrap();
        assert_eq!(lu(&mut disque, 4 * 512, 512).unwrap(), [5; 512]);
        assert_eq!(
            lu(&mut disque, 4 * 512, 1024),
            None,
            "la suite touche la panne"
        );
        assert_eq!(lu(&mut disque, 5 * 512 + 9, 2), None);
        assert_eq!(
            lu(&mut disque, 5 * 512 + 11, 2).unwrap(),
            [6, 6],
            "juste après"
        );
        assert!(
            !disque.ecrire(5 * 512, &[1; 20]),
            "rien à recopier : une erreur"
        );
        assert_eq!(disque.octets_ecrits(), 0, "et rien n'est rangé");
        assert!(disque.ecrire(5 * 512, &[1; 512]), "un secteur entier passe");
        assert_eq!(lu(&mut disque, 4 * 512, 1024).unwrap()[512..], [1; 512]);
        drop(disque);

        for taille in [0usize, 511] {
            let dossier = Dossier::nouveau();
            let lecteur = Image::nouvelle(vec![7; taille]);
            let lache = lecteur.lache.clone();
            assert_eq!(
                DisqueFichier::ouvrir_sur(Box::new(lecteur), &dossier.couche()).err(),
                Some(Refus::PasUnDisque),
                "{taille} octets"
            );
            assert!(lache.load(std::sync::atomic::Ordering::SeqCst), "lâché");
            assert!(!dossier.couche().exists() && !dossier.carte().exists());
        }
        // Une couche faite pour seize secteurs, sous un lecteur de dix-sept.
        let lecteur = Image::nouvelle(image(17, 1));
        let lache = lecteur.lache.clone();
        assert_eq!(
            DisqueFichier::ouvrir_sur(Box::new(lecteur), &dossier.couche()).err(),
            Some(Refus::CoucheDUnAutreDisque)
        );
        assert!(lache.load(std::sync::atomic::Ordering::SeqCst));
        // Et un disque ouvert lâche son lecteur quand il s'en va.
        let lecteur = Image::nouvelle(image(16, 1));
        let lache = lecteur.lache.clone();
        let disque = DisqueFichier::ouvrir_sur(Box::new(lecteur), &dossier.couche()).unwrap();
        assert!(!lache.load(std::sync::atomic::Ordering::SeqCst));
        drop(disque);
        assert!(lache.load(std::sync::atomic::Ordering::SeqCst));
    }
}
