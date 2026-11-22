//! **Un disque dont la base est lue par un autre**, vu par un invité : le
//! pilote disque minimal (`noyau_factice::DISQUE`) lit 1 024 octets du
//! premier disque et les écrit au port série. La base est un [`Lecteur`] —
//! dans l'application, le lecteur qcow2 ou VMDK du cœur Swift, tendu par
//! l'ABI (`wisq_pc_attach_disk_reader`) ; ici, un disque rangé à l'envers
//! que le lecteur remet à l'endroit, pour qu'une base lue telle quelle se
//! voie. Le programme C (`abi/pc.c`) juge le même branchement à travers
//! l'en-tête, et `RustPCDiskImageTests` côté Swift le mène sur de vraies
//! images de `qemu-img`.

use std::path::PathBuf;
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::{Arc, Mutex};

use wisq_carte::fichier::{DisqueFichier, Lecteur};
use wisq_carte::pc::Disque;
use wisq_vm::pc::{Fin, Poste};

mod noyau_factice;
use noyau_factice::image_disque;

const RAM: u64 = 128 << 20;
const SECTEURS: u64 = 64;

/// Un dossier à soi, effacé à la fin.
struct Dossier(PathBuf);

impl Dossier {
    fn nouveau() -> Self {
        static RANG: AtomicU32 = AtomicU32::new(0);
        let chemin = std::env::temp_dir().join(format!(
            "wisq-pc-disque-{}-{}",
            std::process::id(),
            RANG.fetch_add(1, Ordering::Relaxed)
        ));
        let _ = std::fs::remove_dir_all(&chemin);
        std::fs::create_dir_all(&chemin).unwrap();
        Self(chemin)
    }
}

impl Drop for Dossier {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// Le disque tel que l'invité doit le voir : chaque octet dit où il est.
fn disque_vu() -> Vec<u8> {
    (0..SECTEURS * 512)
        .map(|i| (i * 7 + i / 512) as u8)
        .collect()
}

/// **Un disque rangé à l'envers** — le secteur `n` à la place `SECTEURS - 1
/// - n` —, que le lecteur remet à l'endroit, comme un qcow2 traduit ses
/// clusters par ses tables. `panne` : un secteur qu'il ne sait pas rendre.
struct ALEnvers {
    ranges: Vec<u8>,
    appels: Arc<Mutex<Vec<(u64, usize)>>>,
    panne: Option<u64>,
}

impl ALEnvers {
    fn nouveau(panne: Option<u64>) -> Self {
        let vu = disque_vu();
        let mut ranges = vec![0u8; vu.len()];
        for n in 0..SECTEURS as usize {
            let place = SECTEURS as usize - 1 - n;
            ranges[place * 512..][..512].copy_from_slice(&vu[n * 512..][..512]);
        }
        Self {
            ranges,
            appels: Arc::default(),
            panne,
        }
    }
}

impl Lecteur for ALEnvers {
    fn taille(&self) -> u64 {
        SECTEURS * 512
    }

    fn lire(&mut self, decalage: u64, vers: &mut [u8]) -> bool {
        self.appels.lock().unwrap().push((decalage, vers.len()));
        for (i, octet) in vers.iter_mut().enumerate() {
            let a = decalage + i as u64;
            let secteur = a / 512;
            if Some(secteur) == self.panne {
                return false;
            }
            let place = SECTEURS - 1 - secteur;
            *octet = self.ranges[(place * 512 + a % 512) as usize];
        }
        true
    }
}

/// Le pilote disque chargé sur un poste dont le premier disque est lu par
/// `lecteur` ; la console de toute sa course.
fn lire_par(lecteur: ALEnvers, secteur: u64, couche: &std::path::Path) -> (Fin, Vec<u8>) {
    let mut poste = Poste::essayer(RAM).expect("la RAM");
    poste.regler_l_heure(1_795_230_600);
    let disque = DisqueFichier::ouvrir_sur(Box::new(lecteur), couche).expect("le disque");
    poste
        .brancher_disque(Disque::Premier, disque)
        .expect("éteinte");
    poste
        .charger(&image_disque(secteur), None, None)
        .expect("le pilote se charge");
    let mut console = Vec::new();
    let fin = poste.courir(50_000_000, &mut |octets: &[u8]| {
        console.extend_from_slice(octets)
    });
    (fin, console)
}

#[test]
fn the_swift_fixture_is_the_disk_guest_built_here() {
    let fixture = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../Tests/Fixtures/pc-noyau-disque.bin"
    );
    let octets = std::fs::read(fixture).expect("Tests/Fixtures/pc-noyau-disque.bin");
    assert_eq!(octets, image_disque(7), "la copie des tests Swift a dérivé");
}

/// **L'invité lit ce que le lecteur traduit** : les secteurs 7 et 8, puis
/// les deux derniers, rendus à l'endroit, et le statut « 0 » ; la lecture
/// d'un kibioctet est **un seul appel** au lecteur, dans le disque.
#[test]
fn a_guest_reads_what_the_reader_translates() {
    for secteur in [7, SECTEURS - 2] {
        let dossier = Dossier::nouveau();
        let lecteur = ALEnvers::nouveau(None);
        let appels = lecteur.appels.clone();
        let (fin, console) = lire_par(lecteur, secteur, &dossier.0.join("couche"));
        assert_eq!(fin, Fin::Eteinte, "secteur {secteur}");
        let debut = (secteur * 512) as usize;
        let mut attendu = disque_vu()[debut..debut + 1024].to_vec();
        attendu.push(b'0');
        assert_eq!(console, attendu, "secteur {secteur}");
        assert_eq!(
            *appels.lock().unwrap(),
            [(secteur * 512, 1024)],
            "un appel, dans le disque"
        );
    }
}

/// **Ce que le lecteur ne sait pas rendre est une erreur pour l'invité**,
/// jamais des zéros donnés pour vrais : le statut dit « 1 »
/// (`VIRTIO_BLK_S_IOERR`).
#[test]
fn a_sector_the_reader_cannot_give_is_an_io_error_for_the_guest() {
    let dossier = Dossier::nouveau();
    let (fin, console) = lire_par(ALEnvers::nouveau(Some(8)), 7, &dossier.0.join("couche"));
    assert_eq!(fin, Fin::Eteinte);
    assert_eq!(console.len(), 1025);
    assert_eq!(console.last(), Some(&b'1'), "une erreur d'entrée-sortie");
    // Et le secteur d'à côté, que le lecteur rend, se lit encore.
    let dossier = Dossier::nouveau();
    let (_, console) = lire_par(ALEnvers::nouveau(Some(8)), 9, &dossier.0.join("couche"));
    assert_eq!(console.last(), Some(&b'0'));
    assert_eq!(console[..1024], disque_vu()[9 * 512..11 * 512]);
}
