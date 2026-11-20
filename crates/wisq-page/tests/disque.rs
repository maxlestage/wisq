//! **Le disque sur fichier de la carte écrit la même couche que les deux
//! autres.**
//!
//! Le format de la couche d'écriture existe trois fois : `FileDiskStore` du
//! cœur Swift, `wisq_vm::store::FileStore` pour la machine RISC-V, et
//! `wisq_carte::fichier::DisqueFichier` pour la machine PC — qui ne peut pas
//! emprunter le second, parce que `wisq-carte` ne dépend de rien. Les couches
//! que l'application a déjà écrites sur les téléphones (`disk-writes/`)
//! doivent se relire telles quelles, quel que soit le cœur qui les rouvre.
//!
//! Le cœur Swift et `wisq-vm` sont déjà comparés octet pour octet
//! (`Tests/WisqVMRustTests/DifferentialDiskTests.swift`). Ce fichier compare
//! `wisq-vm` et la carte : mêmes écritures, mêmes deux fichiers ; et chacun
//! rouvre la couche de l'autre. Il vit ici parce que `wisq-page` est le crate
//! qui voit les deux.
//!
//! Et **le mode d'emploi du JOURNAL**, tel qu'il y est écrit, compilé et
//! exécuté : le flux « cœur » le recopie, il doit être vrai.

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU32, Ordering};

use wisq_page::carte::fichier::{DisqueFichier, Refus};
use wisq_page::carte::pc::{horloge_du_systeme, Arriere, CartePc, Disque};
use wisq_page::carte::RamPlate;
use wisq_vm::store::{FileStore, Store, StoreError};

/// Un dossier à soi, effacé à la fin.
struct Dossier(PathBuf);

impl Dossier {
    fn nouveau() -> Self {
        static RANG: AtomicU32 = AtomicU32::new(0);
        let chemin = std::env::temp_dir().join(format!(
            "wisq-page-disque-{}-{}",
            std::process::id(),
            RANG.fetch_add(1, Ordering::Relaxed)
        ));
        let _ = std::fs::remove_dir_all(&chemin);
        std::fs::create_dir_all(&chemin).unwrap();
        Self(chemin)
    }

    fn base(&self, secteurs: usize, nom: &str) -> PathBuf {
        let chemin = self.0.join(nom);
        std::fs::write(&chemin, image(secteurs)).unwrap();
        chemin
    }

    fn chemin(&self, nom: &str) -> PathBuf {
        self.0.join(nom)
    }
}

impl Drop for Dossier {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// Chaque secteur rempli de son numéro plus un : la base des tests Swift.
fn image(secteurs: usize) -> Vec<u8> {
    (0..secteurs)
        .flat_map(|s| [(s as u8).wrapping_add(1); 512])
        .collect()
}

fn carte_de(couche: &Path) -> PathBuf {
    let mut chemin = couche.as_os_str().to_owned();
    chemin.push(".map");
    PathBuf::from(chemin)
}

/// Un générateur congruentiel : des écritures au hasard, les mêmes à chaque
/// course.
struct Hasard(u64);

impl Hasard {
    fn suivant(&mut self) -> u64 {
        self.0 = self
            .0
            .wrapping_mul(6_364_136_223_846_793_005)
            .wrapping_add(1_442_695_040_888_963_407);
        self.0 >> 33
    }
}

/// **Une suite d'écritures qui touche à tout** : des secteurs entiers, des
/// morceaux, des écritures à cheval, des réécritures, des écritures de
/// plusieurs secteurs, et quelques-unes au-delà de la fin (refusées).
fn ecritures(secteurs: u64, combien: usize) -> Vec<(u64, Vec<u8>)> {
    let mut hasard = Hasard(0x57_69_73_71);
    let taille = secteurs * 512;
    let mut suite = vec![
        (512, vec![0xAB; 512]),
        (512 + 8, vec![9; 4]),
        (1020, vec![7; 8]),
        ((secteurs - 1) * 512, vec![1; 512]),
        (0, vec![7; 3]),
        (taille - 1, vec![0xEE; 2]),
        (taille, vec![1]),
    ];
    for _ in 0..combien {
        let longueur = match hasard.suivant() % 4 {
            0 => 512,
            1 => 1 + hasard.suivant() % 511,
            2 => 512 * (1 + hasard.suivant() % 5),
            _ => 1 + hasard.suivant() % 3000,
        };
        // Un secteur sur quatre du disque seulement : les réécritures sont
        // fréquentes.
        let decalage = hasard.suivant() % (taille / 4);
        let octet = hasard.suivant() as u8;
        suite.push((decalage, vec![octet; longueur as usize]));
    }
    suite
}

fn tout(disque: &mut DisqueFichier) -> Vec<u8> {
    let mut octets = vec![0; (disque.secteurs() * 512) as usize];
    assert!(disque.lire(0, &mut octets));
    octets
}

/// **Les mêmes écritures, les deux mêmes fichiers.** Octet pour octet : la
/// couche, et sa carte.
#[test]
fn the_card_and_the_riscv_store_write_the_same_overlay_byte_for_byte() {
    let dossier = Dossier::nouveau();
    let base = dossier.base(256, "base.img");
    let (couche_vm, couche_carte) = (dossier.chemin("vm.writes"), dossier.chemin("carte.writes"));
    let mut vm = Store::File(FileStore::open(&base, &couche_vm).unwrap());
    let mut carte = DisqueFichier::ouvrir(&base, &couche_carte).unwrap();
    let mut temoin = image(256);
    let suite = ecritures(256, 400);
    let mut refusees = 0;
    for (rang, (decalage, octets)) in suite.iter().enumerate() {
        let attendu = *decalage as usize + octets.len() <= temoin.len();
        assert_eq!(vm.write(*decalage, octets), attendu, "wisq-vm, {rang}");
        assert_eq!(carte.ecrire(*decalage, octets), attendu, "la carte, {rang}");
        if attendu {
            temoin[*decalage as usize..][..octets.len()].copy_from_slice(octets);
        } else {
            refusees += 1;
        }
    }
    assert_eq!(refusees, 2, "les deux au-delà de la fin");
    vm.flush();
    assert!(carte.vider());

    let ecrits = std::fs::read(&couche_carte).unwrap();
    assert!(ecrits.len() > 50 * 512, "la suite a bien rempli la couche");
    assert_eq!(ecrits, std::fs::read(&couche_vm).unwrap(), "la couche");
    assert_eq!(
        std::fs::read(carte_de(&couche_carte)).unwrap(),
        std::fs::read(carte_de(&couche_vm)).unwrap(),
        "sa carte"
    );
    assert_eq!(carte.octets_ecrits(), vm.bytes_written());
    // Et les deux rendent le même disque, celui du témoin.
    assert_eq!(tout(&mut carte), temoin);
    assert_eq!(vm.image(), temoin);
    assert_eq!(
        std::fs::read(&base).unwrap(),
        image(256),
        "la base, intacte"
    );
}

/// **Chacun rouvre la couche de l'autre**, la lit, et continue d'y écrire :
/// une machine passée d'un cœur à l'autre garde son disque.
#[test]
fn each_reopens_the_overlay_the_other_wrote() {
    let dossier = Dossier::nouveau();
    let base = dossier.base(64, "base.img");
    let couche = dossier.chemin("disk.writes");
    let mut temoin = image(64);
    let suite = ecritures(64, 120);
    let (premiere, seconde) = suite.split_at(suite.len() / 2);
    let applique = |temoin: &mut Vec<u8>, decalage: u64, octets: &[u8]| {
        if decalage as usize + octets.len() <= temoin.len() {
            temoin[decalage as usize..][..octets.len()].copy_from_slice(octets);
        }
    };

    // wisq-vm écrit la première moitié.
    {
        let mut vm = Store::File(FileStore::open(&base, &couche).unwrap());
        for (decalage, octets) in premiere {
            vm.write(*decalage, octets);
            applique(&mut temoin, *decalage, octets);
        }
        vm.flush();
    }
    // La carte la relit, et écrit la seconde.
    {
        let mut carte = DisqueFichier::ouvrir(&base, &couche).unwrap();
        assert_eq!(tout(&mut carte), temoin, "la couche de wisq-vm, relue");
        for (decalage, octets) in seconde {
            carte.ecrire(*decalage, octets);
            applique(&mut temoin, *decalage, octets);
        }
        assert!(carte.vider());
    }
    // wisq-vm relit le tout, et écrit encore.
    {
        let mut vm = Store::File(FileStore::open(&base, &couche).unwrap());
        assert_eq!(vm.image(), temoin, "la couche de la carte, relue");
        assert!(vm.write(63 * 512, &[0x42; 512]));
        applique(&mut temoin, 63 * 512, &[0x42; 512]);
        vm.flush();
    }
    let mut carte = DisqueFichier::ouvrir(&base, &couche).unwrap();
    assert_eq!(tout(&mut carte), temoin);
}

/// **Les mêmes refus, sur les mêmes fichiers** : une couche d'un autre
/// disque, une couche tronquée, une base trop petite, une base absente.
#[test]
fn both_refuse_the_same_overlays_for_the_same_reason() {
    let dossier = Dossier::nouveau();
    let base = dossier.base(8, "base.img");
    let couche = dossier.chemin("disk.writes");
    {
        let mut carte = DisqueFichier::ouvrir(&base, &couche).unwrap();
        assert!(carte.ecrire(512, &[0xAB; 512]));
        assert!(carte.ecrire(1024, &[0xCD; 512]));
        assert!(carte.vider());
    }
    let les_deux = |base: &Path, couche: &Path| {
        (
            FileStore::open(base, couche).err(),
            DisqueFichier::ouvrir(base, couche).err(),
        )
    };
    let autre = dossier.base(16, "autre.img");
    assert_eq!(
        les_deux(&autre, &couche),
        (
            Some(StoreError::OverlayBelongsToAnotherDisk),
            Some(Refus::CoucheDUnAutreDisque)
        )
    );
    let contenu = std::fs::read(&couche).unwrap();
    std::fs::write(&couche, &contenu[..512]).unwrap();
    assert_eq!(
        les_deux(&base, &couche),
        (
            Some(StoreError::OverlayIsTruncated),
            Some(Refus::CoucheTronquee)
        )
    );
    let minuscule = dossier.chemin("tiny");
    std::fs::write(&minuscule, [1, 2, 3]).unwrap();
    assert_eq!(
        les_deux(&minuscule, &dossier.chemin("t.writes")),
        (Some(StoreError::NotADisk), Some(Refus::PasUnDisque))
    );
    assert_eq!(
        les_deux(&dossier.chemin("absente.img"), &dossier.chemin("a.writes")),
        (Some(StoreError::CannotOpenBase), Some(Refus::BaseIllisible))
    );
    assert!(!dossier.chemin("t.writes").exists() && !dossier.chemin("a.writes").exists());
}

/// **Le mode d'emploi du JOURNAL (20 novembre 2026), tel quel** : les dix
/// lignes que le flux « cœur » recopie, entre les deux marques. Autour, ce
/// qu'il faut pour qu'elles tournent — deux fichiers, et un invité réduit à
/// ce qu'il écrirait dans les ports.
#[test]
fn the_ten_lines_of_the_journal_compile_and_run() -> Result<(), Refus> {
    let dossier = Dossier::nouveau();
    let (iso, vierge) = (dossier.base(8, "live.iso"), dossier.base(16, "vierge.img"));
    let (couche, couche2) = (dossier.chemin("a.writes"), dossier.chemin("b.writes"));
    let (port, largeur, valeur, tics) = (0x70u16, 1u8, 0x09u32, 1_193u64);
    let mut ram = RamPlate(vec![0; 1 << 20]);

    // ---- les dix lignes ----
    let mut carte = CartePc::nouvelle();
    carte.horloge(horloge_du_systeme); // l'heure, lue avant chaque accès à la CMOS
    carte.brancher(Disque::Premier, DisqueFichier::ouvrir(&iso, &couche)?); // vda, 00:03.0, ligne 5
    carte.brancher(Disque::Second, DisqueFichier::ouvrir(&vierge, &couche2)?); // vdb, 00:04.0, ligne 6
    let pris = carte.port_ecrire(port, largeur, valeur); // `out` ; false : pas à la carte
    carte.servir(&mut ram); // après un `out` pris : le disque avance, sa ligne se lève
    let lu: Option<u32> = carte.port_lire(port + 1, largeur); // `in` ; None : pas à la carte
    carte.battre(tics); // à chaque tour : les frappes à leur heure (tics du 8254)
    let (levees, tenues, reveil) = (carte.lignes(), carte.tenues(), carte.reveil());
    carte.vider(); // au passage en arrière-plan : fsync des couches

    // ---- fin ----

    assert!(pris, "l'index de la CMOS est à la carte");
    let annee = lu.expect("la donnée de la CMOS aussi");
    assert!(
        (0x24..=0x99).contains(&annee),
        "une année d'après 2024, en BCD"
    );
    assert_eq!(levees, 0);
    assert_eq!(tenues, (1 << 1) | (1 << 5) | (1 << 6) | (1 << 12));
    assert!(!reveil);
    // Les deux disques sont là, avec la capacité de leur fichier.
    let bus = &carte.carte().pci;
    assert_eq!(bus.premier.disque.as_ref().map(|d| d.secteurs()), Some(8));
    assert_eq!(bus.second.disque.as_ref().map(|d| d.secteurs()), Some(16));
    Ok(())
}

/// **Les cinq lignes de l'écran du JOURNAL, telles quelles** : ce que le
/// flux « cœur » ajoute aux dix lignes pour brancher l'écran et sa tablette,
/// et diriger vers la carte les accès de l'invité qui tombent hors de sa
/// RAM. Autour, un invité réduit à un pixel écrit, et une application qui
/// touche l'écran avant que le pilote n'ait pris la tablette.
#[test]
fn the_five_screen_lines_of_the_journal_compile_and_run() {
    let mut carte = CartePc::nouvelle();
    let (adresse, largeur, valeur) = (0xE000_0000u64, 4u8, 0x00AB_CDEFu64);
    let (x, y, boutons, crans) = (0.5f64, 0.5f64, 1u8, 1i32);

    // ---- les cinq lignes de l'écran ----
    carte.brancher_ecran(1024, 768); // avant le démarrage : l'écran en 00:02.0, sa tablette en 00:07.0, ligne 10
    let pris = carte.mem_ecrire(adresse, largeur, valeur); // un accès hors RAM ; false : la faute « hors mémoire »
    let lu: Option<u64> = carte.mem_lire(adresse + 4, largeur); // None : la faute aussi
    let touche = carte.toucher(x, y, boutons) || carte.defiler(crans); // false : pas encore prise, la souris PS/2
    let cadre = &carte.ecran().expect("branché").cadre; // la vue : revision(), mode(), octets(), image_dans(…)

    // ---- fin ----

    assert!(pris, "le premier pixel est à la carte");
    assert_eq!(lu, Some(0), "le deuxième aussi, encore noir");
    assert!(!touche, "aucun pilote n'a pris la tablette");
    assert_eq!(cadre.base(), 0xE000_0000);
    assert_eq!(cadre.taille(), 16 << 20);
    assert_eq!(cadre.revision(), 1, "une écriture, une révision");
    assert_eq!(
        (
            cadre.mode().largeur,
            cadre.mode().hauteur,
            cadre.mode().octets_par_ligne
        ),
        (1024, 768, 4096)
    );
    assert_eq!(cadre.octets()[..4], [0xEF, 0xCD, 0xAB, 0]);
    assert_eq!(carte.tenues() & (1 << 10), 1 << 10, "la ligne 10 est tenue");
}
