//! **Le débit de lecture d'un disque sur fichier, par la carte.**
//!
//!     cargo run --release -p wisq-page --example debit-disque -- image.iso [dossier]
//!
//! Lit l'image entière, du premier au dernier secteur, comme le pilote
//! `virtio_blk` d'un noyau la lirait : par les ports de la carte
//! ([`CartePc`]), une requête à la fois dans la file — en-tête, tampon, octet
//! de statut —, la notification, `servir`, l'acquittement de la ligne. Les
//! octets arrivent dans la RAM de l'invité (un tableau, ici).
//!
//! **Ce qui est mesuré** : des mébioctets par seconde, pour plusieurs tailles
//! de requête (un noyau lit par 128 Kio en lecture anticipée, 1 280 Kio au
//! plus par défaut), trois courses chacune, la médiane et la meilleure. À
//! côté, deux repères : le même fichier lu par `pread` sans la carte (ce que
//! l'hôte sait faire au mieux), et la carte servie par le magasin de
//! `wisq_vm::store`, qui lit secteur par secteur (ce que la lecture par
//! morceaux de `DisqueFichier` remplace).
//!
//! La toute première lecture est chronométrée à part : lancée après
//! `echo 3 > /proc/sys/vm/drop_caches`, elle donne le débit à froid, borné
//! par le stockage de l'hôte ; les autres courses lisent le cache de l'hôte
//! et mesurent ce que la carte coûte.
//!
//! **Ce qui est vérifié avant de mesurer** : une course compare chaque octet
//! arrivé en RAM à celui du fichier. Un débit sur des octets faux ne vaut
//! rien.
//!
//! Le second argument est un dossier où poser la couche d'écriture, effacée
//! à la fin (par défaut le dossier temporaire du système). L'image n'est
//! jamais modifiée.

#[cfg(target_arch = "wasm32")]
fn main() {}

#[cfg(not(target_arch = "wasm32"))]
fn main() {
    natif::main();
}

#[cfg(not(target_arch = "wasm32"))]
mod natif {
    use std::fs::File;
    use std::os::unix::fs::FileExt;
    use std::path::{Path, PathBuf};
    use std::time::Instant;

    use wisq_page::carte::fichier::DisqueFichier;
    use wisq_page::carte::pc::{Arriere, CartePc, Disque};
    use wisq_page::carte::{Ram, RamPlate};
    use wisq_vm::store::{FileStore, Store};

    const FENETRE: u16 = 0xC000;
    /// La file à la page 1 : descripteurs, disponibles, servies.
    const DESCRIPTEURS: u64 = 0x1000;
    const DISPONIBLES: u64 = 0x1800;
    const SERVIES: u64 = 0x2000;
    const ENTETE: u64 = 0x4000;
    const STATUT: u64 = 0x4800;
    const TAMPON: u64 = 0x10_0000;
    const MIO: f64 = (1 << 20) as f64;

    /// **Le magasin de `wisq-vm` derrière la carte** : le repère « secteur
    /// par secteur ».
    struct ParSecteur(Store);

    impl Arriere for ParSecteur {
        fn secteurs(&self) -> u64 {
            self.0.sectors()
        }
        fn lire(&mut self, decalage: u64, vers: &mut [u8]) -> bool {
            match self.0.read(decalage, vers.len()) {
                Some(octets) => {
                    vers.copy_from_slice(&octets);
                    true
                }
                None => false,
            }
        }
        fn ecrire(&mut self, decalage: u64, octets: &[u8]) -> bool {
            self.0.write(decalage, octets)
        }
        fn octets_ecrits(&self) -> u64 {
            self.0.bytes_written()
        }
    }

    /// Le pilote : la carte, la RAM, et où il en est dans ses anneaux.
    struct Pilote {
        carte: CartePc,
        ram: RamPlate,
        publiees: u16,
    }

    impl Pilote {
        /// Ce que fait le noyau pour trouver et ouvrir le disque : la BAR0
        /// placée, les ports activés, la poignée de main, la file posée.
        fn nouveau(arriere: impl Arriere + 'static) -> Self {
            let mut carte = CartePc::nouvelle();
            carte.brancher(Disque::Premier, arriere);
            let cfg = |carte: &mut CartePc, registre: u32, valeur: u32| {
                carte.port_ecrire(0xCF8, 4, 0x8000_1800 | registre);
                carte.port_ecrire(0xCFC, 4, valeur);
            };
            cfg(&mut carte, 0x10, u32::from(FENETRE));
            cfg(&mut carte, 0x04, 0x0005);
            for statut in [0, 1, 3] {
                carte.port_ecrire(FENETRE + 0x12, 1, statut);
            }
            carte.port_ecrire(FENETRE + 0x0E, 2, 0);
            carte.port_ecrire(FENETRE + 0x08, 4, 1);
            carte.port_ecrire(FENETRE + 0x12, 1, 7);
            let mut ram = RamPlate(vec![0; 64 << 20]);
            // Les trois descripteurs ne changent pas d'une requête à l'autre,
            // sauf la longueur du tampon.
            let mut decrire = |i: u64, a: u64, longueur: u32, drapeaux: u16, suivant: u16| {
                let at = DESCRIPTEURS + i * 16;
                ram.ecrire(at, &a.to_le_bytes());
                ram.ecrire(at + 8, &longueur.to_le_bytes());
                ram.ecrire(at + 12, &drapeaux.to_le_bytes());
                ram.ecrire(at + 14, &suivant.to_le_bytes());
            };
            decrire(0, ENTETE, 16, 1, 1);
            decrire(1, TAMPON, 0, 3, 2);
            decrire(2, STATUT, 1, 2, 0);
            Self {
                carte,
                ram,
                publiees: 0,
            }
        }

        fn secteurs(&mut self) -> u64 {
            let bas = self.carte.port_lire(FENETRE + 0x14, 4).unwrap_or(0);
            let haut = self.carte.port_lire(FENETRE + 0x18, 4).unwrap_or(0);
            u64::from(haut) << 32 | u64::from(bas)
        }

        /// **Une lecture, de bout en bout** : `longueur` octets depuis le
        /// secteur `secteur`, rendus dans la RAM à [`TAMPON`].
        fn lire(&mut self, secteur: u64, longueur: u32) -> &[u8] {
            let ram = &mut self.ram;
            ram.ecrire(ENTETE, &0u32.to_le_bytes());
            ram.ecrire(ENTETE + 8, &secteur.to_le_bytes());
            ram.ecrire(DESCRIPTEURS + 16 + 8, &longueur.to_le_bytes());
            ram.ecrire(STATUT, &[0xFF]);
            let place = u64::from(self.publiees % 128);
            ram.ecrire(DISPONIBLES + 4 + place * 2, &0u16.to_le_bytes());
            self.publiees = self.publiees.wrapping_add(1);
            ram.ecrire(DISPONIBLES + 2, &self.publiees.to_le_bytes());
            assert!(self.carte.port_ecrire(FENETRE + 0x10, 2, 0), "notifier");
            self.carte.servir(ram);
            // Ce que fait le gestionnaire d'interruption du pilote : la
            // ligne, l'acquittement, l'anneau des servies, le statut.
            assert_eq!(self.carte.lignes() & (1 << 5), 1 << 5, "la ligne 5");
            assert_eq!(self.carte.port_lire(FENETRE + 0x13, 1), Some(1));
            let mut rendues = [0u8; 2];
            ram.lire(SERVIES + 2, &mut rendues);
            assert_eq!(u16::from_le_bytes(rendues), self.publiees);
            assert_eq!(ram.0[STATUT as usize], 0, "secteur {secteur}");
            &ram.0[TAMPON as usize..][..longueur as usize]
        }

        /// Le disque entier, par requêtes de `pas` octets. `voir` reçoit
        /// chaque morceau et son décalage.
        fn tout_lire(&mut self, pas: u32, mut voir: impl FnMut(u64, &[u8])) -> f64 {
            let octets = self.secteurs() * 512;
            let debut = Instant::now();
            let mut a = 0u64;
            while a < octets {
                let n = u64::from(pas).min(octets - a) as u32;
                let morceau = self.lire(a / 512, n);
                voir(a, morceau);
                a += u64::from(n);
            }
            debut.elapsed().as_secs_f64()
        }
    }

    /// Trois courses : la médiane et la meilleure, en Mio/s.
    fn courses(octets: u64, mut une: impl FnMut() -> f64) -> (f64, f64) {
        let mut debits: Vec<f64> = (0..3).map(|_| octets as f64 / MIO / une()).collect();
        debits.sort_by(f64::total_cmp);
        (debits[1], debits[2])
    }

    struct Couche(PathBuf);

    impl Couche {
        fn nouvelle(dossier: &Path, nom: &str) -> Self {
            let chemin = dossier.join(format!("wisq-debit-{}-{nom}.writes", std::process::id()));
            let couche = Self(chemin);
            couche.effacer();
            couche
        }
        fn effacer(&self) {
            let _ = std::fs::remove_file(&self.0);
            let mut carte = self.0.clone().into_os_string();
            carte.push(".map");
            let _ = std::fs::remove_file(carte);
        }
    }

    impl Drop for Couche {
        fn drop(&mut self) {
            self.effacer();
        }
    }

    pub fn main() {
        let mut arguments = std::env::args_os().skip(1);
        let Some(image) = arguments.next().map(PathBuf::from) else {
            eprintln!("usage : debit-disque image.iso [dossier de la couche]");
            std::process::exit(2);
        };
        let dossier = arguments
            .next()
            .map_or_else(std::env::temp_dir, PathBuf::from);
        let fichier = File::open(&image).expect("ouvrir l'image");
        let taille = fichier.metadata().expect("sa taille").len() / 512 * 512;
        println!(
            "{} : {} octets ({:.1} Mio)",
            image.display(),
            taille,
            taille as f64 / MIO
        );

        // La vérification d'abord : chaque octet rendu par la carte est celui
        // du fichier.
        let couche = Couche::nouvelle(&dossier, "carte");
        let disque = DisqueFichier::ouvrir(&image, &couche.0).expect("le disque sur fichier");
        let mut pilote = Pilote::nouveau(disque);
        assert_eq!(pilote.secteurs() * 512, taille);
        // La toute première lecture, avec le cache de l'hôte tel qu'il est :
        // vidé juste avant (`echo 3 > /proc/sys/vm/drop_caches`), c'est le
        // débit à froid, celui du stockage de l'hôte.
        let premiere = pilote.tout_lire(128 << 10, |_, _| {});
        println!(
            "première lecture, par 128 Kio : {:.0} Mio/s ({premiere:.2} s)",
            taille as f64 / MIO / premiere
        );
        let mut temoin = vec![0u8; 1 << 20];
        let mut compares = 0u64;
        pilote.tout_lire(1 << 20, |a, morceau| {
            let temoin = &mut temoin[..morceau.len()];
            fichier.read_exact_at(temoin, a).expect("lire le témoin");
            assert!(morceau == temoin, "octets différents à {a}");
            compares += morceau.len() as u64;
        });
        assert_eq!(compares, taille);
        println!("vérifié : {compares} octets identiques à ceux du fichier");

        println!(
            "\nrequête   | carte, DisqueFichier | carte, secteur par secteur | pread sans la carte"
        );
        println!(
            "          | médiane   meilleure  | médiane   meilleure        | médiane   meilleure"
        );
        let couche_vm = Couche::nouvelle(&dossier, "vm");
        let magasin = FileStore::open(&image, &couche_vm.0).expect("le magasin de wisq-vm");
        let mut par_secteur = Pilote::nouveau(ParSecteur(Store::File(magasin)));
        for kio in [4u32, 64, 128, 512, 1024, 1280] {
            let pas = kio << 10;
            let carte = courses(taille, || pilote.tout_lire(pas, |_, _| {}));
            let secteur = courses(taille, || par_secteur.tout_lire(pas, |_, _| {}));
            let direct = courses(taille, || {
                let mut tampon = vec![0u8; pas as usize];
                let debut = Instant::now();
                let mut a = 0u64;
                while a < taille {
                    let n = u64::from(pas).min(taille - a) as usize;
                    fichier.read_exact_at(&mut tampon[..n], a).expect("pread");
                    a += n as u64;
                }
                debut.elapsed().as_secs_f64()
            });
            println!(
                "{kio:>5} Kio | {:>7.0}   {:>7.0}    | {:>7.0}   {:>7.0}          | {:>7.0}   {:>7.0}   Mio/s",
                carte.0, carte.1, secteur.0, secteur.1, direct.0, direct.1
            );
        }
    }
}
