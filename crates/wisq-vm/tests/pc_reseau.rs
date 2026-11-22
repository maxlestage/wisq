//! **La carte réseau du poste** : ce que l'invité émet sort par la file que
//! l'hôte vide (`Commandes::prendre_trame`, `wisq_pc_net_take`), ce que l'hôte
//! remet (`Commandes::remettre_trame`, `wisq_pc_net_give`) entre dans la RAM
//! de l'invité — et s'y exécute quand il tombe sur du code déjà décodé —, les
//! files sont bornées, et la carte interroge le câble au rythme du cœur Swift.
//! Le programme C (`abi/pc.c`) juge la même chose à travers l'en-tête.

use wisq_carte::pc::MAC_PAR_DEFAUT;
use wisq_vm::pc::poste::RefusDeBranchement;
use wisq_vm::pc::reseau::{Remise, TRAMES_EN_FILE};
use wisq_vm::pc::{Fin, Poste};

mod noyau_factice;
use noyau_factice::{image_de, image_reseau};

const RAM: u64 = 128 << 20;

/// Un poste, la carte réseau branchée, le noyau chargé.
fn poste_en_reseau(noyau: &[u8]) -> Poste {
    let mut poste = Poste::essayer(RAM).expect("la RAM");
    poste.regler_l_heure(1_795_230_600);
    poste
        .brancher_reseau(MAC_PAR_DEFAUT)
        .expect("la carte se branche");
    poste
        .charger(noyau, None, None)
        .expect("le noyau se charge");
    poste
}

fn courir(poste: &mut Poste, budget: u64) -> (Fin, Vec<u8>) {
    let mut console = Vec::new();
    let fin = poste.courir(budget, &mut |octets: &[u8]| {
        console.extend_from_slice(octets)
    });
    (fin, console)
}

/// La trame que le pilote minimal émet : diffusée, depuis l'adresse de la
/// carte, de type 0x88B5, puis son texte.
fn trame_de_l_invite() -> Vec<u8> {
    let mut trame = vec![0xFF; 6];
    trame.extend_from_slice(&MAC_PAR_DEFAUT);
    trame.extend_from_slice(&[0x88, 0xB5]);
    trame.extend_from_slice(b"wisq-reseau : une trame de l'invite vers l'hote");
    trame
}

/// Une trame pour l'invité qui commence par `mov $'R', %eax ; ret` : posée
/// sur son code, elle lui fait dire « R ».
fn trame_de_code() -> Vec<u8> {
    let mut trame = vec![0xB8, b'R', 0x00, 0x00, 0x00, 0xC3];
    trame.resize(60, 0x5A);
    trame
}

#[test]
fn the_swift_fixture_is_the_network_guest_built_here() {
    let fixture = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../Tests/Fixtures/pc-noyau-reseau.bin"
    );
    let octets = std::fs::read(fixture).expect("Tests/Fixtures/pc-noyau-reseau.bin");
    assert_eq!(octets, image_reseau(), "la copie des tests Swift a dérivé");
}

/// **Une trame reçue par-dessus du code décodé est exécutée** — l'équivalent,
/// pour le réseau, de `a_disk_read_into_decoded_code_is_executed`. La trame
/// est remise avant la course : la carte la prend au quatrième tour du
/// matériel (l'invité travaille), la range au tour, par `Ram::ecrire`, dans
/// le tampon que le pilote a posé sur le code qu'il vient d'appeler ; le
/// second appel, dans la même tranche, doit exécuter les octets neufs. Avec
/// et sans blocs. Et la trame que l'invité a émise sort par la file de
/// l'hôte, octet pour octet.
#[test]
fn a_frame_received_over_decoded_code_is_executed_and_the_sent_one_leaves() {
    for blocs in [true, false] {
        let mut poste = poste_en_reseau(&image_reseau());
        poste.machine.blocs_actifs = blocs;
        let commandes = poste.commandes().clone();
        assert_eq!(
            commandes.remettre_trame(&trame_de_code()),
            Some(Remise::Prise)
        );
        let (fin, console) = courir(&mut poste, 10_000_000);
        assert_eq!(fin, Fin::Eteinte, "blocs {blocs}");
        assert_eq!(
            console, b"oR",
            "blocs {blocs} : « o » le code d'avant, « R » celui que la trame a rangé"
        );
        if blocs {
            assert!(poste.machine.blocs.construits >= 3, "des blocs ont servi");
        }
        let mut tampon = [0u8; 1514];
        let longueur = commandes
            .prendre_trame(&mut tampon)
            .expect("la trame émise");
        assert_eq!(&tampon[..longueur], &trame_de_l_invite()[..]);
        assert_eq!(commandes.prendre_trame(&mut tampon), None, "une seule");
        let ((emises, livrees, perdues), files) = commandes
            .compteurs_du_reseau()
            .expect("la carte est branchée");
        assert_eq!((emises, livrees, perdues), (1, 1, 0));
        assert_eq!(
            (
                files.entrantes,
                files.sortantes,
                files.refusees,
                files.perdues
            ),
            (0, 0, 0, 0)
        );
    }
}

/// **L'aller et le retour, comme l'application les fait** : une tranche, la
/// trame émise vidée de la file, une trame remise pendant que l'invité
/// attend, une autre tranche — et l'invité l'a reçue.
#[test]
fn a_frame_given_while_the_guest_waits_reaches_it() {
    let mut poste = poste_en_reseau(&image_reseau());
    let commandes = poste.commandes().clone();
    let (fin, console) = courir(&mut poste, 1_000_000);
    assert_eq!(fin, Fin::Budget, "il attend sa trame");
    assert_eq!(console, b"o");
    let mut tampon = [0u8; 1514];
    let longueur = commandes
        .prendre_trame(&mut tampon)
        .expect("émise dès l'`out`");
    assert_eq!(&tampon[..longueur], &trame_de_l_invite()[..]);
    assert_eq!(
        commandes.remettre_trame(&trame_de_code()),
        Some(Remise::Prise)
    );
    let (fin, console) = courir(&mut poste, 1_000_000);
    assert_eq!((fin, console), (Fin::Eteinte, b"R".to_vec()));
}

/// **La file entrante pleine refuse** : `TRAMES_EN_FILE` trames prises,
/// la suivante refusée et comptée ; la carte les prend toutes au tour suivant
/// (l'invité n'a qu'un tampon : une livrée, le reste attend chez la carte),
/// et la file reprend. Sans carte, rien n'entre ; ce qui n'est pas une trame
/// non plus ; et la carte ne se branche qu'une fois, machine éteinte.
#[test]
fn a_full_incoming_queue_refuses_until_the_card_takes() {
    let mut sans = Poste::essayer(RAM).expect("la RAM");
    assert_eq!(
        sans.commandes().remettre_trame(&[1; 60]),
        None,
        "pas de carte"
    );
    assert!(sans.commandes().compteurs_du_reseau().is_none());
    sans.brancher_reseau(MAC_PAR_DEFAUT).expect("branchée");
    assert_eq!(
        sans.brancher_reseau(MAC_PAR_DEFAUT),
        Err(RefusDeBranchement::ReseauDejaLa)
    );

    let mut poste = poste_en_reseau(&image_reseau());
    assert_eq!(
        poste.brancher_reseau(MAC_PAR_DEFAUT),
        Err(RefusDeBranchement::DejaDemarree)
    );
    let commandes = poste.commandes().clone();
    assert_eq!(commandes.remettre_trame(&[]), Some(Remise::PasUneTrame));
    assert_eq!(
        commandes.remettre_trame(&[0; 1515]),
        Some(Remise::PasUneTrame)
    );
    assert_eq!(
        commandes.remettre_trame(&trame_de_code()),
        Some(Remise::Prise)
    );
    for _ in 1..TRAMES_EN_FILE {
        assert_eq!(commandes.remettre_trame(&[0x33; 60]), Some(Remise::Prise));
    }
    assert_eq!(commandes.remettre_trame(&[0x44; 60]), Some(Remise::Pleine));
    let (_, files) = commandes.compteurs_du_reseau().expect("branchée");
    assert_eq!((files.entrantes, files.refusees), (TRAMES_EN_FILE, 1));
    let (fin, console) = courir(&mut poste, 10_000_000);
    assert_eq!((fin, console), (Fin::Eteinte, b"oR".to_vec()));
    let ((_, livrees, _), files) = commandes.compteurs_du_reseau().expect("branchée");
    assert_eq!((livrees, files.entrantes), (1, 0), "la carte a tout pris");
    assert_eq!(
        commandes.remettre_trame(&[0x55; 60]),
        Some(Remise::Prise),
        "elle reprend"
    );
}

/// **Le rythme du cœur Swift** (`VirtioNet.poll(busy:)`) : un invité qui
/// travaille fait interroger le câble un tour sur quatre (toutes les 1 024
/// instructions) ; un invité qui dort, à chaque tour.
#[test]
fn the_card_asks_the_cable_every_fourth_pass_at_work_and_every_pass_asleep() {
    // `cli ; jmp .` : 102 400 instructions, quatre cents tours.
    let mut travail = poste_en_reseau(&image_de(&[0xFA, 0xEB, 0xFE]));
    assert_eq!(courir(&mut travail, 102_400).0, Fin::Budget);
    assert_eq!(travail.commandes().reseau().questions(), 100);

    // `sti ; hlt` sans horloge armée : la carte branchée tient l'invité en
    // vie, et chaque pas d'attente est un tour.
    let mut sommeil = poste_en_reseau(&image_de(&[0xFB, 0xF4, 0xEB, 0xFE]));
    assert_eq!(courir(&mut sommeil, 1_000).0, Fin::Budget);
    assert!(sommeil.machine.arretee, "endormi");
    let questions = sommeil.commandes().reseau().questions();
    assert!(
        (990..=1_010).contains(&questions),
        "un tour par pas d'attente : {questions}"
    );
}
