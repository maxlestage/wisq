//! **Le poste** : la machine PC menée comme une application la mène — ce que
//! l'ABI C (`wisq_pc_*`) tend à Swift. Le programme C (`abi/pc.c`) juge la
//! frontière ; ceci juge ce qui est derrière elle, au détail : la frappe et
//! son annulation, le temps passé dehors, l'écran copié, l'instantané champ par
//! champ.

use std::sync::Arc;

use wisq_carte::ecran::{BASE_DE_LA_MEMOIRE_VIDEO, PORT_DONNEE, PORT_INDEX};
use wisq_carte::i8042::{CodeTouche, LIMITE_DE_FRAPPE};
use wisq_carte::tablette::BASE_DE_LA_TABLETTE;
use wisq_vm::pc::instantane::{self, RefusDInstantane, MAGIE, VERSION};
use wisq_vm::pc::machine::Alea;
use wisq_vm::pc::poste::{
    frappes_du_jeu_1, RefusDeBranchement, RefusDeTouches, DERNIERE_SECONDE, FRAPPES_REMISES,
    PAS_DE_RATTRAPAGE_EN_SECONDES,
};
use wisq_vm::pc::{Fin, Poste};
use wisq_vm::x86_paging::{Access, Unmapped};

/// Le bit LMA d'EFER : le mode long actif.
const EFER_LMA: u64 = 1 << 10;

mod noyau_factice;
use noyau_factice::{image, image_de, BOUCLE, FAUTE, REMISE};

const RAM: u64 = 128 << 20;

fn poste_charge(noyau: &[u8], ligne: Option<&str>) -> Poste {
    let mut poste = Poste::essayer(RAM).expect("la RAM");
    poste.regler_l_heure(1_795_230_600);
    poste
        .charger(noyau, ligne, None)
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

/// Le fichier que les tests Swift démarrent sur les deux cœurs est bien le
/// noyau factice d'ici : une copie qui dériverait jugerait autre chose.
#[test]
fn the_swift_fixture_is_the_tiny_kernel_built_here() {
    let fixture = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../Tests/Fixtures/pc-noyau-factice.bin"
    );
    let octets = std::fs::read(fixture).expect("Tests/Fixtures/pc-noyau-factice.bin");
    assert_eq!(octets, image(), "la copie des tests Swift a dérivé");
}

#[test]
fn a_run_ends_the_way_the_guest_does() {
    let mut poste = poste_charge(&image(), Some("a=b"));
    let (fin, console) = courir(&mut poste, 50_000_000);
    assert_eq!(fin, Fin::Eteinte);
    assert_eq!(console, b"wisq-noyau-factice\na=b\n.....\nFIN\n");

    let mut boucle = poste_charge(&image_de(&BOUCLE), None);
    assert_eq!(courir(&mut boucle, 1_000_000).0, Fin::Budget);
    assert_eq!(
        boucle.temps(),
        1_000_000,
        "le budget compte le temps, au compte près"
    );

    let mut faute = poste_charge(&image_de(&FAUTE), None);
    assert!(
        matches!(courir(&mut faute, 1_000_000).0, Fin::Faute(ref nom) if !nom.is_empty()),
        "ud2 sans IDT est une faute nommée"
    );

    let mut remise = poste_charge(&image_de(&REMISE), None);
    assert_eq!(courir(&mut remise, 1_000_000).0, Fin::Remise);

    let mut vide = Poste::essayer(RAM).expect("la RAM");
    assert!(matches!(courir(&mut vide, 1000).0, Fin::Faute(_)));
}

#[test]
fn a_stop_asked_before_the_run_is_taken_once() {
    let mut poste = poste_charge(&image_de(&BOUCLE), None);
    poste.commandes().arreter();
    assert_eq!(courir(&mut poste, u64::MAX).0, Fin::Arretee);
    assert_eq!(poste.temps(), 0, "rendue avant la première tranche");
    assert_eq!(courir(&mut poste, 400_000).0, Fin::Budget, "consommée");
}

#[test]
fn a_run_is_stopped_from_another_thread_and_published_meanwhile() {
    let mut poste = poste_charge(&image_de(&BOUCLE), None);
    let commandes = Arc::clone(poste.commandes());
    assert_eq!(commandes.avancement(), None);
    let fil = std::thread::spawn(move || {
        while commandes
            .avancement()
            .is_none_or(|(retirees, _)| retirees < 1_000_000)
        {
            std::thread::yield_now();
        }
        commandes.arreter();
        commandes.avancement()
    });
    let (fin, _) = courir(&mut poste, u64::MAX);
    let vu = fil.join().expect("le fil");
    assert_eq!(fin, Fin::Arretee);
    let (retirees, rip) = vu.expect("publié");
    assert!(retirees >= 1_000_000 && retirees <= poste.machine.retirees);
    assert!(rip > 0);
}

#[test]
fn serial_bytes_sent_from_anywhere_reach_the_uart() {
    let mut poste = poste_charge(&image(), None);
    poste.commandes().envoyer(b"bonjour");
    courir(&mut poste, 1000);
    let entree: Vec<u8> = poste.machine.herites.serie.entree.iter().copied().collect();
    assert_eq!(entree, b"bonjour");
}

#[test]
fn set_one_codes_are_read_as_keystrokes() {
    let a = CodeTouche::simple(0x1E);
    let haut = CodeTouche::etendue(0x48);
    assert_eq!(
        frappes_du_jeu_1(&[0x1E, 0x9E, 0xE0, 0x48, 0xE0, 0xC8]),
        Ok(vec![(a, true), (a, false), (haut, true), (haut, false)])
    );
    assert_eq!(frappes_du_jeu_1(&[]), Ok(vec![]));
    assert_eq!(
        frappes_du_jeu_1(&[0x1E, 0xE0]),
        Err(RefusDeTouches::PrefixeSeul)
    );
    assert_eq!(
        frappes_du_jeu_1(&[0xE1, 0x1D]),
        Err(RefusDeTouches::PrefixeInconnu)
    );
    assert_eq!(
        frappes_du_jeu_1(&[0xE0, 0xE0]),
        Err(RefusDeTouches::PrefixeInconnu)
    );
    assert_eq!(frappes_du_jeu_1(&[0x80]), Err(RefusDeTouches::CodeNul));
    assert_eq!(
        frappes_du_jeu_1(&[0xE0, 0x00]),
        Err(RefusDeTouches::CodeNul)
    );
}

#[test]
fn keystrokes_are_taken_whole_or_not_at_all_up_to_the_bound() {
    let poste = Poste::essayer(RAM).expect("la RAM");
    let commandes = poste.commandes();
    let (a, b, c) = (
        CodeTouche::simple(0x1E),
        CodeTouche::simple(0x30),
        CodeTouche::simple(0x2E),
    );
    assert!(commandes.frapper(&[(c, true)]), "C enfoncée");
    let paires: Vec<_> = (0..(LIMITE_DE_FRAPPE - 1) / 2)
        .flat_map(|_| [(a, true), (a, false)])
        .collect();
    assert!(commandes.frapper(&paires));
    assert!(commandes.frapper(&[(a, true)]));
    assert_eq!(
        commandes.frappes_en_attente(),
        LIMITE_DE_FRAPPE,
        "à la borne"
    );
    assert!(
        !commandes.frapper(&[(b, true), (b, false)]),
        "un groupe de plus est refusé"
    );
    assert!(
        !commandes.frapper(&[(b, false), (b, true)]),
        "un enfoncement aussi, même derrière un relâchement"
    );
    assert_eq!(
        commandes.frappes_en_attente(),
        LIMITE_DE_FRAPPE,
        "et rien n'est entré"
    );
    assert!(
        commandes.frapper(&[(b, false)]),
        "un relâchement seul passe…"
    );
    assert_eq!(
        commandes.frappes_en_attente(),
        LIMITE_DE_FRAPPE,
        "…sans rien ajouter pour une touche relevée"
    );
    assert!(commandes.frapper(&[(c, false), (a, false)]));
    assert_eq!(
        commandes.frappes_en_attente(),
        LIMITE_DE_FRAPPE + 2,
        "mais il entre au-delà pour les touches que la file laisse enfoncées"
    );
}

/// **La borne compte aussi ce que la carte tient encore** : trente-deux
/// frappes remises à l'i8042 d'un invité qui ne lit pas son clavier y
/// restent, et une frappe de plus que la borne ne passe pas, même si ce qui
/// attend dans le poste seul la laisserait passer.
#[test]
fn the_bound_counts_what_the_card_still_holds() {
    let mut poste = poste_charge(&image_de(&BOUCLE), None);
    let commandes = Arc::clone(poste.commandes());
    let (a, b) = (CodeTouche::simple(0x1E), CodeTouche::simple(0x30));
    let paires: Vec<_> = (0..FRAPPES_REMISES)
        .flat_map(|_| [(a, true), (a, false)])
        .collect();
    assert!(commandes.frapper(&paires));
    courir(&mut poste, 1000);
    // La première est posée au port de l'i8042 ; les trente et une suivantes
    // attendent dans sa file, les trente-deux autres ici.
    let dans_la_carte = commandes.carte().tenir().carte().ps2.frappes.len();
    assert_eq!(dans_la_carte, FRAPPES_REMISES - 1);
    let en_attente = commandes.frappes_en_attente();
    assert_eq!(en_attente, 2 * FRAPPES_REMISES - 1);
    let jusqu_a_la_borne: Vec<_> = (0..LIMITE_DE_FRAPPE - en_attente)
        .map(|rang| (a, rang % 2 == 0))
        .collect();
    assert!(commandes.frapper(&jusqu_a_la_borne));
    assert_eq!(commandes.frappes_en_attente(), LIMITE_DE_FRAPPE);
    assert!(
        !commandes.frapper(&[(b, true)]),
        "la borne est atteinte avec la file de la carte, pas sans elle"
    );
    assert_eq!(commandes.frappes_en_attente(), LIMITE_DE_FRAPPE);
}

/// **Une annulation oublie aussi ce que la frappe jetée laissait enfoncé** :
/// une touche enfoncée puis jetée avant d'être remise n'est plus à relâcher,
/// et un relâchement seul au-delà de la borne n'ajoute rien pour elle.
#[test]
fn abandoning_forgets_what_the_dropped_keystrokes_left_down() {
    let poste = Poste::essayer(RAM).expect("la RAM");
    let commandes = poste.commandes();
    let (a, b) = (CodeTouche::simple(0x1E), CodeTouche::simple(0x30));
    assert!(commandes.frapper(&[(a, true)]));
    commandes.abandonner_la_frappe();
    assert_eq!(commandes.frappes_en_attente(), 0, "jetée, rien à relâcher");
    let paires: Vec<_> = (0..LIMITE_DE_FRAPPE / 2)
        .flat_map(|_| [(b, true), (b, false)])
        .collect();
    assert!(commandes.frapper(&paires));
    assert_eq!(commandes.frappes_en_attente(), LIMITE_DE_FRAPPE);
    assert!(
        commandes.frapper(&[(a, false)]),
        "un relâchement seul passe…"
    );
    assert_eq!(
        commandes.frappes_en_attente(),
        LIMITE_DE_FRAPPE,
        "…sans rien ajouter : A n'est plus enfoncée"
    );
}

/// **Un noyau qui lit son clavier** et renvoie chaque octet de l'i8042 sur le
/// port série : `in $0x64 ; test $1 ; jz ; in $0x60 ; out` vers 0x3F8.
const ECHO_DU_CLAVIER: [u8; 15] = [
    0xE4, 0x64, 0xA8, 0x01, 0x74, 0xFA, 0xE4, 0x60, 0x66, 0xBA, 0xF8, 0x03, 0xEE, 0xEB, 0xF1,
];

/// Un poste dont l'invité renvoie son clavier, un battement par
/// instruction : une frappe se joue en quelques dizaines de milliers
/// d'instructions au lieu de dizaines de millions.
fn poste_qui_renvoie_son_clavier() -> Poste {
    let mut poste = poste_charge(&image_de(&ECHO_DU_CLAVIER), None);
    poste.machine.instructions_par_battement = 1;
    poste
}

#[test]
fn keystrokes_reach_a_guest_that_reads_its_keyboard_in_order() {
    let mut poste = poste_qui_renvoie_son_clavier();
    let frappes = frappes_du_jeu_1(&[0x1E, 0x9E, 0xE0, 0x48, 0xE0, 0xC8]).expect("jeu 1");
    assert!(poste.commandes().frapper(&frappes));
    let (_, console) = courir(&mut poste, 2_000_000);
    assert_eq!(console, [0x1E, 0x9E, 0xE0, 0x48, 0xE0, 0xC8]);
    assert_eq!(poste.commandes().frappes_en_attente(), 0);
}

#[test]
fn abandoning_drops_what_waits_and_releases_what_was_handed_over() {
    let mut poste = poste_qui_renvoie_son_clavier();
    let (a, b) = (CodeTouche::simple(0x1E), CodeTouche::simple(0x30));
    let commandes = Arc::clone(poste.commandes());
    assert!(commandes.frapper(&[(a, true)]));
    for _ in 0..20 {
        assert!(commandes.frapper(&[(b, true), (b, false)]));
    }
    assert_eq!(commandes.frappes_en_attente(), 41);
    // Une instruction : la course remet les trente-deux premières à l'i8042,
    // qui pose aussitôt la première à son port (l'invité ne l'a pas lue).
    courir(&mut poste, 1);
    assert_eq!(commandes.frappes_en_attente(), 40);
    commandes.abandonner_la_frappe();
    // Les neuf qui attendaient ici sont jetées. Les trente-deux remises
    // laissent A et B enfoncées : les deux sont relâchées derrière elles.
    assert_eq!(commandes.frappes_en_attente(), FRAPPES_REMISES - 1 + 2);
    let (_, console) = courir(&mut poste, 10_000_000);
    let mut attendu = vec![0x1E];
    for _ in 0..15 {
        attendu.extend([0x30, 0xB0]);
    }
    attendu.extend([0x30, 0x9E, 0xB0]);
    assert_eq!(console, attendu);
    assert_eq!(commandes.frappes_en_attente(), 0);

    // Rien d'enfoncé : l'annulation ne relâche rien.
    assert!(commandes.frapper(&[(a, true), (a, false)]));
    commandes.abandonner_la_frappe();
    assert_eq!(commandes.frappes_en_attente(), 0);
    // Une touche enfoncée et pas encore remise : jetée, rien à relâcher.
    assert!(commandes.frapper(&[(a, true)]));
    commandes.abandonner_la_frappe();
    assert_eq!(commandes.frappes_en_attente(), 0);
    let (_, console) = courir(&mut poste, 1_000_000);
    assert!(console.is_empty());
    // Ce qu'on tape après une annulation passe.
    assert!(commandes.frapper(&[(b, true), (b, false)]));
    let (_, console) = courir(&mut poste, 1_000_000);
    assert_eq!(console, [0x30, 0xB0]);
}

/// **Une touche étendue remise à l'i8042 se relâche étendue** : Ctrl droit
/// (`E0 1D`), AltGr (`E0 38`) et la flèche du haut (`E0 48`) tenus quand la
/// frappe est annulée reçoivent `E0 9D`, `E0 B8` et `E0 C8` — pas le
/// relâchement de Ctrl gauche, d'Alt gauche ou du 8 du pavé.
#[test]
fn abandoning_releases_an_extended_key_as_an_extended_key() {
    let mut poste = poste_qui_renvoie_son_clavier();
    let commandes = Arc::clone(poste.commandes());
    let tenues = frappes_du_jeu_1(&[0xE0, 0x1D, 0xE0, 0x38, 0xE0, 0x48]).expect("jeu 1");
    assert!(commandes.frapper(&tenues));
    let b = CodeTouche::simple(0x30);
    for _ in 0..20 {
        assert!(commandes.frapper(&[(b, true), (b, false)]));
    }
    // Les trois touches étendues et vingt-neuf frappes de B sont remises.
    courir(&mut poste, 1);
    commandes.abandonner_la_frappe();
    let (_, console) = courir(&mut poste, 10_000_000);
    let mut attendu = vec![0xE0, 0x1D, 0xE0, 0x38, 0xE0, 0x48];
    for _ in 0..14 {
        attendu.extend([0x30, 0xB0]);
    }
    attendu.push(0x30);
    // Relâchées dans l'ordre de leur rang : B, puis les trois étendues.
    attendu.extend([0xB0, 0xE0, 0x9D, 0xE0, 0xB8, 0xE0, 0xC8]);
    assert_eq!(console, attendu);
    assert_eq!(commandes.frappes_en_attente(), 0);
}

#[test]
fn time_spent_outside_is_paid_while_the_guest_sleeps_and_kept_out_of_its_time() {
    let mut reference = poste_charge(&image(), None);
    let (fin, console) = courir(&mut reference, 50_000_000);
    assert_eq!(fin, Fin::Eteinte);

    let mut poste = poste_charge(&image(), None);
    let hertz = poste.hertz();
    poste.rattraper(-1.0);
    poste.rattraper(f64::NAN);
    poste.rattraper(f64::INFINITY);
    assert_eq!(
        poste.temps_du(),
        0,
        "ni un écart négatif, ni ce qui n'est pas un nombre"
    );
    poste.rattraper(25.0);
    assert_eq!(poste.temps_du(), 25 * hertz);
    let (fin, rattrapee) = courir(&mut poste, 50_000_000);
    assert_eq!(fin, Fin::Eteinte);
    assert_eq!(rattrapee, console, "l'invité dit la même chose");
    assert_eq!(
        poste.temps_du(),
        0,
        "tout est payé : trois sommeils, dix, dix et cinq secondes"
    );
    assert!(
        poste.machine.retirees.wrapping_add(poste.machine.attente) >= 25 * hertz,
        "son horloge a avancé d'autant"
    );
    assert!(
        poste.temps() < 25 * hertz,
        "le rattrapage n'entre pas dans le temps de l'invité"
    );

    let mut borne = Poste::essayer(RAM).expect("la RAM");
    borne.rattraper(1e300);
    assert_eq!(
        borne.temps_du(),
        (10.0 * 365.0 * 86_400.0 * borne.hertz() as f64) as u64,
        "borné à dix ans"
    );
    assert_eq!(PAS_DE_RATTRAPAGE_EN_SECONDES, 10);
}

#[test]
fn a_step_of_catching_up_is_ten_seconds_at_most() {
    let mut poste = poste_charge(&image(), None);
    let hertz = poste.hertz();
    poste.rattraper(25.0);
    // Jusqu'au premier sommeil : un seul pas est payé, de dix secondes.
    while poste.temps_du() == 25 * hertz {
        let (fin, _) = courir(&mut poste, 1000);
        assert_eq!(fin, Fin::Budget);
    }
    assert_eq!(poste.temps_du(), 15 * hertz);
}

#[test]
fn the_screen_is_attached_once_before_the_kernel_and_copied_with_its_stride() {
    let mut poste = Poste::essayer(RAM).expect("la RAM");
    assert!(poste.commandes().ecran().is_none());
    assert_eq!(
        poste.brancher_ecran(0, 10),
        Err(RefusDeBranchement::EcranTropGrand)
    );
    assert_eq!(
        poste.brancher_ecran(4096, 4096),
        Err(RefusDeBranchement::EcranTropGrand)
    );
    assert_eq!(poste.brancher_ecran(640, 480), Ok(()));
    assert_eq!(
        poste.brancher_ecran(640, 480),
        Err(RefusDeBranchement::EcranDejaLa)
    );
    let vue = poste.commandes().ecran().expect("l'écran");
    assert_eq!(
        (vue.largeur, vue.hauteur, vue.octets_par_ligne, vue.debut),
        (640, 480, 2560, 0)
    );
    assert_eq!(vue.taille, 16 << 20);

    // Un mode de quatre pixels sur deux lignes, une ligne virtuelle de huit,
    // décalé d'un pixel : ce que la carte de Bochs règle par ses ports.
    {
        let carte = poste.commandes().carte().clone();
        let mut carte = carte.tenir();
        for (registre, valeur) in [(1u32, 4u32), (2, 2), (3, 32), (4, 0x41), (6, 8), (8, 1)] {
            assert!(carte.port_ecrire(PORT_INDEX, 2, registre));
            assert!(carte.port_ecrire(PORT_DONNEE, 2, valeur));
        }
        for decalage in 0..64u64 {
            assert!(carte.mem_ecrire(BASE_DE_LA_MEMOIRE_VIDEO + decalage * 4, 4, decalage));
        }
    }
    let avant = poste.commandes().ecran().expect("l'écran");
    assert_eq!(
        (
            avant.largeur,
            avant.hauteur,
            avant.octets_par_ligne,
            avant.debut
        ),
        (4, 2, 32, 4)
    );
    let mut trop_court = [0u8; 31];
    assert_eq!(
        poste.commandes().copier_l_image(&mut trop_court),
        Some(Err(avant)),
        "un tampon trop court : rien de copié, et la taille qu'il faut"
    );
    assert_eq!(trop_court, [0; 31]);
    let mut pixels_copies = [0u8; 32];
    assert_eq!(
        poste.commandes().copier_l_image(&mut pixels_copies),
        Some(Ok(avant))
    );
    let pixels: Vec<u32> = pixels_copies
        .chunks_exact(4)
        .map(|pixel| u32::from_le_bytes(pixel.try_into().unwrap()))
        .collect();
    assert_eq!(
        pixels,
        [1, 2, 3, 4, 9, 10, 11, 12],
        "les lignes au pas de la ligne virtuelle"
    );

    poste.charger(&image(), None, None).expect("chargé");
    assert_eq!(
        poste.brancher_ecran(640, 480),
        Err(RefusDeBranchement::DejaDemarree)
    );
    assert!(
        poste.commandes().copier_l_image(&mut [0u8; 0]).is_some(),
        "l'écran reste là"
    );
}

#[test]
fn the_tablet_and_the_wheel_wait_for_the_guest() {
    let mut poste = Poste::essayer(RAM).expect("la RAM");
    assert!(!poste.commandes().toucher(0.5, 0.5, 1), "pas d'écran");
    poste.brancher_ecran(640, 480).expect("l'écran");
    assert!(
        !poste.commandes().toucher(0.5, 0.5, 1),
        "la tablette n'est pas prise"
    );
    assert!(!poste.commandes().toucher(f64::NAN, 0.5, 1));
    assert!(!poste.commandes().defiler(1));
    poste.commandes().souris(5, -5, 1);

    // **La tablette prise**, comme son pilote la prend : la commande PCI de
    // l'emplacement 7, puis la file des événements et `DRIVER_OK` par sa
    // BAR0.
    {
        let carte = poste.commandes().carte().clone();
        let mut carte = carte.tenir();
        assert!(carte.port_ecrire(0xCF8, 4, 0x8000_0000 | (7 << 11) | 0x04));
        assert!(carte.port_ecrire(0xCFC, 2, 0x0006));
        for (decalage, largeur, valeur) in [(0x16, 2, 0), (0x1C, 2, 1), (0x14, 1, 15)] {
            assert!(carte.mem_ecrire(BASE_DE_LA_TABLETTE + decalage, largeur, valeur));
        }
    }
    let commandes = poste.commandes();
    assert!(commandes.toucher(0.5, 0.5, 1), "prise, elle répond");
    // Une coordonnée qui n'est pas un nombre ne part pas : la carte la
    // rabattrait sur un bord (`NaN as u32` vaut zéro, l'infini le maximum).
    assert!(!commandes.toucher(f64::NAN, 0.5, 1));
    assert!(!commandes.toucher(0.5, f64::NAN, 1));
    assert!(!commandes.toucher(f64::INFINITY, 0.5, 1));
    assert!(!commandes.toucher(0.5, f64::NEG_INFINITY, 1));
    // Zéro cran ne part pas non plus, tablette prise : la règle est celle de
    // la carte, et l'enveloppe Swift n'a pas à la redire.
    assert!(!commandes.defiler(0));
    assert!(commandes.defiler(1));
}

/// Un poste dont chaque champ que l'instantané porte a une valeur à lui,
/// pour qu'un champ sauvé mais pas repris (ou l'inverse) se voie.
fn poste_bariole() -> Poste {
    let mut poste = poste_charge(&image(), Some("x=y"));
    let (_, _) = courir(&mut poste, 1_000_000);
    poste.rattraper(3.5);
    poste.semer(0xDEAD_BEEF);
    let m = &mut poste.machine;
    m.instructions_par_battement = 289;
    m.attente = m.attente.wrapping_add(7);
    for (rang, registre) in m.cpu.regs.iter_mut().enumerate() {
        *registre = 0x1111 * (rang as u64 + 1);
    }
    m.cpu.gs_base = 0xFFFF_8880_0000_1000;
    m.cpu.fs_base = 0x7F00_0000_2000;
    m.cpu.control[2] = 0xDEAD_0000;
    m.cpu.control[8] = 3;
    m.cpu.xmm[15] = [0x0123_4567_89AB_CDEF, 0xFEDC_BA98_7654_3210];
    m.cpu.mxcsr = 0x1FA0;
    m.cpu.fpu_control = 0x027F;
    m.cpu.fpu_status = 0x3800;
    m.cpu.x87[7] = (0x8000_0000_0000_0001, 0x3FFF);
    m.cpu.fpu_tags = 0x81;
    m.cpu.segments = [0x18, 0x10, 0x18, 0x18, 0x2B, 0x33];
    m.cpu.fault_code = 6;
    let s = &mut m.systeme;
    s.gdt.base = 0x1000;
    s.gdt.limite = 0x7F;
    s.idt.limite = 0xFFF;
    s.tache = 0x40;
    s.base_de_tache = 0x5000;
    s.limite_de_tache = 0x67;
    s.ldt = 0x50;
    s.gs_du_noyau = 0x9000;
    s.star = 0x0023_0010_0000_0000;
    s.lstar = 0xFFFF_FFFF_8100_0000;
    s.cstar = 0xFFFF_FFFF_8100_1000;
    s.masque_d_appel = 0x4_7700;
    s.tsc_aux = 1;
    s.autres.insert(0x1B, 0xFEE0_0900);
    s.autres.insert(0xC000_0103, 2);
    s.debug[7] = 0x400;
    let h = &mut m.herites;
    h.maitre.demande = 0x11;
    h.second.service = 0x22;
    h.minuterie.verrou = Some(0x1234);
    h.minuterie.haut_parleur = 0x5678;
    h.minuterie.porte = true;
    h.serie.entree.extend(b"attend");
    h.serie.sortie.extend_from_slice(b"pas lu");
    h.serie.brouillon = 0x5A;
    h.cmos.index = 0x0B;
    h.cmos.memoire[0x40] = 0x99;
    m.cpu.memory.bytes[(RAM - 1) as usize] = 0xAB;
    poste
}

#[test]
fn a_snapshot_carries_every_field_it_names() {
    let original = poste_bariole();
    let sauve = instantane::sauver(&original);
    assert_eq!(&sauve[..8], &MAGIE);
    assert_eq!(
        u32::from_le_bytes(sauve[8..12].try_into().unwrap()),
        VERSION
    );
    assert!(
        sauve.len() < (RAM / 16) as usize,
        "les pages nulles n'y sont pas : {} octets",
        sauve.len()
    );

    let mut reprise = Poste::essayer(RAM).expect("la RAM");
    instantane::reprendre(&mut reprise, &sauve).expect("la reprise");
    assert_eq!(
        instantane::sauver(&reprise),
        sauve,
        "sauvée à nouveau, la machine reprise est octet pour octet celle d'avant"
    );
    assert_eq!(
        reprise.machine.cpu.memory.bytes,
        original.machine.cpu.memory.bytes
    );
    assert_eq!(reprise.machine.systeme, original.machine.systeme);
    assert_eq!(reprise.machine.herites, original.machine.herites);
    assert_eq!(
        reprise.machine.cpu.flags.read(),
        original.machine.cpu.flags.read()
    );
    assert_eq!(reprise.machine.ombre(), original.machine.ombre());
    assert_eq!(reprise.machine.placement(), original.machine.placement());
    assert_eq!(reprise.temps_du(), original.temps_du());
    assert_eq!(reprise.temps(), original.temps());
    assert!(reprise.pret());
}

#[test]
fn a_snapshot_taken_mid_run_finishes_the_run_elsewhere() {
    let mut entiere = poste_charge(&image(), Some("x=y"));
    let (_, toute) = courir(&mut entiere, 50_000_000);

    let mut coupee = poste_charge(&image(), Some("x=y"));
    let (fin, debut) = courir(&mut coupee, 1_000_000);
    assert_eq!(fin, Fin::Budget);
    let sauve = instantane::sauver(&coupee);
    let mut reprise = Poste::essayer(RAM).expect("la RAM");
    instantane::reprendre(&mut reprise, &sauve).expect("la reprise");
    let (fin, suite) = courir(&mut reprise, 50_000_000);
    assert_eq!(fin, Fin::Eteinte);
    assert!(!debut.is_empty() && !suite.is_empty());
    assert_eq!([debut, suite].concat(), toute);
    assert_eq!(reprise.machine.retirees, entiere.machine.retirees);
    assert_eq!(reprise.temps(), entiere.temps());
}

#[test]
fn a_snapshot_is_refused_before_anything_is_put_back() {
    let original = poste_bariole();
    let sauve = instantane::sauver(&original);
    let temoin = || {
        let mut poste = poste_charge(&image_de(&BOUCLE), None);
        courir(&mut poste, 1000);
        poste
    };
    let mut poste = temoin();
    let avant = instantane::sauver(&poste);
    let refus = |poste: &mut Poste, octets: &[u8]| instantane::reprendre(poste, octets);

    assert_eq!(
        refus(&mut poste, b"rien"),
        Err(RefusDInstantane::PasUnInstantane)
    );
    let mut version = sauve.clone();
    version[8] = 2;
    assert_eq!(
        refus(&mut poste, &version),
        Err(RefusDInstantane::VersionInconnue(2))
    );
    for coupe in [12, 30, 200, sauve.len() / 2, sauve.len() - 1] {
        assert_eq!(
            refus(&mut poste, &sauve[..coupe]),
            Err(RefusDInstantane::Abime),
            "coupé à {coupe}"
        );
    }
    let mut de_trop = sauve.clone();
    de_trop.push(0);
    assert_eq!(
        refus(&mut poste, &de_trop),
        Err(RefusDInstantane::Abime),
        "un octet de trop"
    );
    // Un booléen qui n'en est pas un : l'arrêt sur `hlt`, juste après les
    // trois compteurs de la machine.
    let mut booleen = sauve.clone();
    booleen[12 + 8 + 8 + 24] = 2;
    assert_eq!(refus(&mut poste, &booleen), Err(RefusDInstantane::Abime));

    // **Un battement de zéro instruction** : repris, il ferait diviser par
    // zéro le premier calcul du temps de l'invité (`Machine::tics`).
    const BATTEMENT: usize = 12 + 8 + 8;
    assert_eq!(
        u64::from_le_bytes(sauve[BATTEMENT..BATTEMENT + 8].try_into().unwrap()),
        289,
        "le battement du poste bariolé"
    );
    let mut sans_battement = sauve.clone();
    sans_battement[BATTEMENT..BATTEMENT + 8].fill(0);
    assert_eq!(
        refus(&mut poste, &sans_battement),
        Err(RefusDInstantane::Abime),
        "un battement nul"
    );

    // **Une étiquette d'aléa inconnue** : ni la graine (0), ni l'hôte (1).
    // Elle suit les compteurs, l'arrêt, l'ombre (neuf octets) et la page zéro
    // (cinquante-sept).
    const ALEA: usize = BATTEMENT + 24 + 1 + 9 + 57;
    assert_eq!(sauve[ALEA], 0, "le poste bariolé a sa graine");
    assert_eq!(
        u64::from_le_bytes(sauve[ALEA + 1..ALEA + 9].try_into().unwrap()),
        0xDEAD_BEEF
    );
    let mut alea = sauve.clone();
    alea[ALEA] = 2;
    assert_eq!(
        refus(&mut poste, &alea),
        Err(RefusDInstantane::Abime),
        "une étiquette d'aléa inconnue"
    );

    // **Deux fois le même MSR** : le second numéro des « autres » (0x1B,
    // puis 0xC000_0103) récrit en 0x1B.
    let mut motif = 0x1Bu32.to_le_bytes().to_vec();
    motif.extend_from_slice(&0xFEE0_0900u64.to_le_bytes());
    let msr = sauve
        .windows(motif.len())
        .position(|fenetre| fenetre == motif)
        .expect("le MSR 0x1B du poste bariolé")
        + motif.len();
    assert_eq!(&sauve[msr..msr + 4], &0xC000_0103u32.to_le_bytes());
    let mut double = sauve.clone();
    double[msr..msr + 4].copy_from_slice(&0x1Bu32.to_le_bytes());
    assert_eq!(
        refus(&mut poste, &double),
        Err(RefusDInstantane::Abime),
        "deux fois le même MSR"
    );
    assert_eq!(instantane::sauver(&poste), avant, "rien n'a été reposé");

    let mut autre = Poste::essayer(RAM * 2).expect("la RAM");
    assert_eq!(
        refus(&mut autre, &sauve),
        Err(RefusDInstantane::AutreMemoire {
            sauvee: RAM,
            ici: RAM * 2
        })
    );
    let mut ecran = Poste::essayer(RAM).expect("la RAM");
    ecran.brancher_ecran(640, 480).expect("l'écran");
    assert_eq!(refus(&mut ecran, &sauve), Err(RefusDInstantane::AutreEcran));
}

/// **Une RAM qui n'est pas un multiple de trente-deux kibioctets** : sa
/// dernière page est partielle, le dernier octet de la carte des pages n'est
/// pas plein, et un bit posé au-delà de la dernière page est refusé.
#[test]
fn a_page_map_with_bits_past_the_last_page_is_refused() {
    let ram = RAM + 100;
    let mut poste = Poste::essayer(ram).expect("la RAM");
    poste.charger(&image(), None, None).expect("chargé");
    poste.machine.cpu.memory.bytes[ram as usize - 1] = 0xCD;
    let sauve = instantane::sauver(&poste);

    let mut reprise = Poste::essayer(ram).expect("la RAM");
    instantane::reprendre(&mut reprise, &sauve).expect("sauvée et reprise, telle quelle");
    assert_eq!(reprise.machine.cpu.memory.bytes[ram as usize - 1], 0xCD);

    // La carte est juste devant les pages non nulles.
    let octets = &poste.machine.cpu.memory.bytes;
    assert_eq!(octets.len() as u64, ram);
    let pages = octets.len().div_ceil(instantane::PAGE);
    assert_eq!(pages % 8, 1, "une page seule dans le dernier octet");
    let pleines: usize = octets
        .chunks(instantane::PAGE)
        .filter(|page| page.iter().any(|&octet| octet != 0))
        .map(<[u8]>::len)
        .sum();
    let carte = sauve.len() - pleines - pages.div_ceil(8);
    assert_eq!(&sauve[carte - 8..carte], &ram.to_le_bytes());
    let dernier = carte + pages / 8;
    assert_eq!(sauve[dernier], 1, "la dernière page, partielle, est pleine");
    for bit in 1..8 {
        let mut au_dela = sauve.clone();
        au_dela[dernier] |= 1 << bit;
        assert_eq!(
            instantane::reprendre(&mut reprise, &au_dela),
            Err(RefusDInstantane::Abime),
            "le bit {bit}, au-delà de la dernière page"
        );
    }
}

/// **L'ombre de `sti` passe l'instantané**, et la source de l'hôte n'y
/// passe pas : une machine reprise garde son propre générateur.
#[test]
fn the_sti_shadow_crosses_a_snapshot_and_a_host_generator_does_not() {
    // `sti ; jmp .` arrêtée après `sti` : l'ombre couvre encore le saut.
    let mut poste = poste_charge(&image_de(&[0xFB, 0xEB, 0xFE]), None);
    assert_eq!(courir(&mut poste, 1).0, Fin::Budget);
    assert_eq!(poste.machine.ombre(), Some(1));
    let sauve = instantane::sauver(&poste);
    let mut reprise = Poste::essayer(RAM).expect("la RAM");
    instantane::reprendre(&mut reprise, &sauve).expect("la reprise");
    assert_eq!(reprise.machine.ombre(), Some(1), "l'ombre est reprise");

    // Un générateur de l'hôte ne se sauve pas : la machine reprise garde le
    // sien, à graine…
    poste.machine.alea = Alea::Hote(Box::new(|| 42));
    let sauve = instantane::sauver(&poste);
    let mut a_graine = Poste::essayer(RAM).expect("la RAM");
    a_graine.semer(7);
    instantane::reprendre(&mut a_graine, &sauve).expect("la reprise");
    assert!(
        matches!(a_graine.machine.alea, Alea::Fixe(7)),
        "la graine de la machine reprise, pas une graine lue dans l'instantané"
    );
    // …ou de l'hôte.
    let mut de_l_hote = Poste::essayer(RAM).expect("la RAM");
    de_l_hote.machine.alea = Alea::Hote(Box::new(|| 1234));
    instantane::reprendre(&mut de_l_hote, &sauve).expect("la reprise");
    assert_eq!(de_l_hote.machine.alea.suivant(), 1234);
}

/// **Reprendre dans une machine qui a déjà tourné** : ce que son tampon de
/// traduction gardait ne vaut plus. La machine usée a tourné le même noyau
/// jusqu'au même endroit (son bloc coupé est donc celui de l'instantané),
/// puis ses tables ont envoyé la page de deux mébioctets de RIP sur une
/// région vide, et sa traduction est restée dans le tampon. Reprise, elle
/// finit la course comme une machine neuve.
#[test]
fn a_snapshot_resumed_in_a_machine_that_already_ran_forgets_its_translations() {
    let mut entiere = poste_charge(&image(), Some("x=y"));
    let (_, toute) = courir(&mut entiere, 50_000_000);

    let mut coupee = poste_charge(&image(), Some("x=y"));
    let (fin, debut) = courir(&mut coupee, 1_000_000);
    assert_eq!(fin, Fin::Budget);
    let sauve = instantane::sauver(&coupee);
    let rip = coupee.machine.cpu.rip;

    let mut usee = poste_charge(&image(), Some("x=y"));
    courir(&mut usee, 1_000_000);
    const REPERTOIRE: u64 = 0x700_0000;
    const VIDE: u64 = 0x600_0000;
    let cpu = &mut usee.machine.cpu;
    let mot = |octets: &[u8], adresse: u64| {
        u64::from_le_bytes(octets[adresse as usize..][..8].try_into().unwrap())
    };
    let racine = cpu.control[3] & !0xFFF;
    let tables = mot(&cpu.memory.bytes, racine) & 0x000F_FFFF_FFFF_F000;
    for rang in 0..512u64 {
        let cible = if rang == rip >> 21 { VIDE } else { rang << 21 };
        let entree = (REPERTOIRE + rang * 8) as usize;
        cpu.memory.bytes[entree..entree + 8].copy_from_slice(&(cible | 0x83).to_le_bytes());
    }
    cpu.memory.bytes[tables as usize..tables as usize + 8]
        .copy_from_slice(&(REPERTOIRE | 0x3).to_le_bytes());
    cpu.flush_translations();
    assert_eq!(
        cpu.translate_cached(rip, Access::Fetch),
        Ok(VIDE | (rip & 0x1F_FFFF)),
        "la traduction de l'ancienne table est gardée"
    );

    instantane::reprendre(&mut usee, &sauve).expect("la reprise");
    let (fin, suite) = courir(&mut usee, 50_000_000);
    assert_eq!(fin, Fin::Eteinte);
    assert_eq!([debut, suite].concat(), toute);
    assert_eq!(usee.machine.retirees, entiere.machine.retirees);
}

/// **Une page nulle dans l'instantané, écrite dans la machine usée**, est
/// nulle après la reprise : l'instantané ne porte pas les pages nulles, et la
/// reprise efface donc toute la RAM avant de poser les siennes. Le test
/// précédent ne le voit pas : sa machine usée a tourné le même noyau jusqu'au
/// même point, et ses pages ont déjà le contenu de l'instantané.
#[test]
fn a_page_that_is_zero_in_the_snapshot_is_zero_in_a_used_machine() {
    let mut coupee = poste_charge(&image(), Some("x=y"));
    courir(&mut coupee, 1_000_000);
    let sauve = instantane::sauver(&coupee);
    let ram = coupee.machine.cpu.memory.bytes.len();
    let ecrites = [0x500_0000, 0x500_0FFF, ram - 1];
    for adresse in ecrites {
        assert_eq!(coupee.machine.cpu.memory.bytes[adresse], 0, "{adresse:#x}");
    }

    let mut usee = poste_charge(&image(), Some("x=y"));
    courir(&mut usee, 1_000_000);
    for adresse in ecrites {
        usee.machine.cpu.memory.bytes[adresse] = 0xCD;
    }
    instantane::reprendre(&mut usee, &sauve).expect("la reprise");
    for adresse in ecrites {
        assert_eq!(
            usee.machine.cpu.memory.bytes[adresse], 0,
            "la page nulle de l'instantané, à {adresse:#x}"
        );
    }
    assert!(usee.machine.cpu.memory.bytes == coupee.machine.cpu.memory.bytes);
}

/// **Le temps rattrapé passe l'instantané** : il entre dans le temps de
/// l'invité (`Poste::temps`, `wisq_pc_guest_time`). `cli ; hlt` avec une
/// seconde à rattraper : la machine s'éteint après avoir rattrapé, et ce
/// qu'elle a rattrapé n'est pas nul.
#[test]
fn the_time_caught_up_crosses_a_snapshot() {
    let mut original = poste_charge(&image_de(&[0xFA, 0xF4]), None);
    original.rattraper(1.0);
    let (fin, _) = courir(&mut original, 1000);
    assert_eq!(fin, Fin::Eteinte);
    // Ce qui est rattrapé : l'attente comptée que le temps de l'invité ôte.
    let rattrape = |poste: &Poste| {
        let m = &poste.machine;
        m.retirees
            .wrapping_add(m.attente)
            .wrapping_sub(poste.temps())
    };
    let du = original.temps_du();
    assert!(rattrape(&original) > 0, "le temps rattrapé, {du} encore dû");
    let sauve = instantane::sauver(&original);

    let mut reprise = Poste::essayer(RAM).expect("la RAM");
    instantane::reprendre(&mut reprise, &sauve).expect("la reprise");
    assert_eq!(reprise.temps_du(), du);
    assert_eq!(rattrape(&reprise), rattrape(&original));
    assert_eq!(reprise.temps(), original.temps(), "le temps de l'invité");
}

/// `bswap %eax ; xor %ecx, %ecx ; div %ecx` : une instruction du chemin
/// général (qui lit `faulted` après `execute`), puis une division par zéro
/// (dont la faute regarde `unmapped` d'abord).
const GENERALE_PUIS_DIVISION: [u8; 6] = [0x0F, 0xC8, 0x31, 0xC9, 0xF7, 0xF1];

/// La course entière d'une machine reprise : sa fin, sa console, ses
/// instructions retirées et son RIP.
fn apres_la_reprise(poste: &mut Poste, sauve: &[u8]) -> (Fin, Vec<u8>, u64, u64) {
    instantane::reprendre(poste, sauve).expect("la reprise");
    let (fin, console) = courir(poste, 1_000_000);
    (fin, console, poste.machine.retirees, poste.machine.cpu.rip)
}

/// **Les témoins de faute d'une machine usée ne passent pas la reprise.**
/// `faulted` et `unmapped` ne sont pas dans l'instantané : ils ne valent que
/// pendant une instruction. Une machine usée arrêtée avec l'un d'eux levé —
/// quoi qu'elle ait fait avant — ne doit pas le donner à la machine reprise :
/// `faulted` resté vrai ferait de sa première instruction du chemin général
/// un refus ; `unmapped` resté là ferait de sa division par zéro une faute
/// d'accès hors de la mémoire.
#[test]
fn a_resumed_machine_drops_the_fault_witnesses_of_the_used_one() {
    let bswap = wisq_vm::x86::decode(&GENERALE_PUIS_DIVISION).expect("bswap");
    assert!(
        !wisq_vm::x86::rapide::specialisee(&bswap),
        "bswap passe par le chemin général"
    );
    let chargee = poste_charge(&image_de(&GENERALE_PUIS_DIVISION), None);
    let sauve = instantane::sauver(&chargee);
    let mut neuve = Poste::essayer(RAM).expect("la RAM");
    let attendue = apres_la_reprise(&mut neuve, &sauve);
    // bswap et xor retirées ; la division faute, et rien ne la livre.
    assert_eq!(attendue.2, 2, "{attendue:?}");
    assert!(
        matches!(&attendue.0, Fin::Faute(faute) if faute.starts_with("Division")),
        "{attendue:?}"
    );

    let usee = || {
        let mut usee = poste_charge(&image(), Some("x=y"));
        courir(&mut usee, 1_000_000);
        usee
    };
    let mut leve = usee();
    leve.machine.cpu.faulted = true;
    assert_eq!(apres_la_reprise(&mut leve, &sauve), attendue, "faulted");

    let mut hors = usee();
    hors.machine.cpu.unmapped = Some(Unmapped::Outside {
        address: 0x1234_5678,
    });
    assert_eq!(apres_la_reprise(&mut hors, &sauve), attendue, "unmapped");
}

/// **LMA ne se lit pas dans l'instantané** : sur le silicium, ce bit d'EFER
/// est en lecture seule, le processeur le tire de LME et de la pagination. La
/// reprise le recalcule donc, et un instantané où il est faux (ici effacé,
/// processeur en mode long) reprend en mode long, et finit sa course comme
/// une machine qui n'a pas été coupée.
#[test]
fn the_long_mode_bit_is_recomputed_on_resume() {
    let mut entiere = poste_charge(&image(), Some("x=y"));
    let (_, toute) = courir(&mut entiere, 50_000_000);
    let mut coupee = poste_charge(&image(), Some("x=y"));
    let (_, debut) = courir(&mut coupee, 1_000_000);
    let efer = coupee.machine.cpu.efer;
    assert_ne!(efer & EFER_LMA, 0, "en mode long");
    let mut sauve = instantane::sauver(&coupee);

    // EFER suit les compteurs de la machine (144 octets avec l'en-tête), les
    // seize registres, RIP, les drapeaux, GS, FS, les neuf registres de
    // contrôle, les seize XMM, MXCSR, le contrôle et l'état du x87, ses huit
    // registres, ses étiquettes et les six sélecteurs.
    const EFER: usize = 144 + 16 * 8 + 4 * 8 + 9 * 8 + 16 * 16 + 4 + 2 + 2 + 8 * 10 + 1 + 6 * 2;
    assert_eq!(
        u64::from_le_bytes(sauve[EFER..EFER + 8].try_into().unwrap()),
        efer,
        "EFER à sa place"
    );
    sauve[EFER..EFER + 8].copy_from_slice(&(efer & !EFER_LMA).to_le_bytes());

    let mut reprise = Poste::essayer(RAM).expect("la RAM");
    instantane::reprendre(&mut reprise, &sauve).expect("la reprise");
    assert_eq!(reprise.machine.cpu.efer, efer, "LMA recalculé");
    let (fin, suite) = courir(&mut reprise, 50_000_000);
    assert_eq!(fin, Fin::Eteinte);
    assert_eq!([debut, suite].concat(), toute);
    assert_eq!(reprise.machine.retirees, entiere.machine.retirees);
}

/// **Un instantané qui dit la carte absente, ou une heure des puces au-delà
/// de l'an 9999, est refusé** : `sauver` ne les écrit jamais (le poste
/// branche toujours sa carte, et l'heure est bornée), et repris, ils
/// rendraient les ports 0x70 et 0x71 aux puces de la machine, devant la
/// carte encore branchée, avec une date hors de toute borne.
#[test]
fn a_snapshot_without_the_card_or_past_9999_is_refused() {
    let mut poste = Poste::essayer(RAM).expect("la RAM");
    poste.regler_l_heure(DERNIERE_SECONDE);
    let sauve = instantane::sauver(&poste);
    // `cmos_ailleurs` est le dernier octet des puces, juste avant la longueur
    // de la RAM ; les secondes des puces le précèdent, avant les 128 octets de
    // la mémoire de l'horloge.
    let mut motif = vec![1u8];
    motif.extend_from_slice(&RAM.to_le_bytes());
    let ailleurs = (144..sauve.len() - motif.len())
        .find(|&rang| sauve[rang..rang + motif.len()] == motif[..])
        .expect("la carte dite branchée, avant la RAM");
    let secondes = ailleurs - 128 - 8;
    assert_eq!(
        u64::from_le_bytes(sauve[secondes..secondes + 8].try_into().unwrap()),
        DERNIERE_SECONDE as u64,
        "les secondes des puces à leur place"
    );

    let mut neuf = Poste::essayer(RAM).expect("la RAM");
    instantane::reprendre(&mut neuf, &sauve).expect("l'instantané tel que sauvé");

    let mut sans_carte = sauve.clone();
    sans_carte[ailleurs] = 0;
    let mut neuf = Poste::essayer(RAM).expect("la RAM");
    assert_eq!(
        instantane::reprendre(&mut neuf, &sans_carte),
        Err(RefusDInstantane::Abime)
    );

    let mut trop_tard = sauve.clone();
    trop_tard[secondes..secondes + 8].copy_from_slice(&(DERNIERE_SECONDE as u64 + 1).to_le_bytes());
    let mut neuf = Poste::essayer(RAM).expect("la RAM");
    assert_eq!(
        instantane::reprendre(&mut neuf, &trop_tard),
        Err(RefusDInstantane::Abime)
    );

    let mut au_bout = sauve.clone();
    au_bout[secondes..secondes + 8].copy_from_slice(&u64::MAX.to_le_bytes());
    let mut neuf = Poste::essayer(RAM).expect("la RAM");
    assert_eq!(
        instantane::reprendre(&mut neuf, &au_bout),
        Err(RefusDInstantane::Abime)
    );
}

/// **Une heure d'avant 1970, ou d'après l'an 9999**, s'arrête à la borne,
/// **là où l'invité la lit** : la carte est toujours branchée
/// (`cmos_ailleurs`), donc les ports 0x70 et 0x71 vont à la CMOS de la carte,
/// et c'est elle que ce test lit. Sans la borne, -5 s'y lisait le 31 décembre
/// 1969 à 23:59:55, et `i64::MIN` donnait un siècle 0xFF. L'horloge des puces
/// de la machine, celle que porte l'instantané, reçoit la même heure.
#[test]
fn an_hour_before_1970_stops_at_1970() {
    // Seconde, minute, heure, jour, mois, année, siècle : en BCD.
    const REGISTRES: [u32; 7] = [0x00, 0x02, 0x04, 0x07, 0x08, 0x09, 0x32];
    let lire_la_date = |poste: &Poste| {
        let carte = poste.commandes().carte().clone();
        let mut carte = carte.tenir();
        REGISTRES.map(|registre| {
            assert!(carte.port_ecrire(0x70, 1, registre));
            carte.port_lire(0x71, 1).expect("l'horloge répond")
        })
    };
    let premiere = [0x00, 0x00, 0x00, 0x01, 0x01, 0x70, 0x19];
    let derniere = [0x59, 0x59, 0x23, 0x31, 0x12, 0x99, 0x99];
    let mut poste = Poste::essayer(RAM).expect("la RAM");
    for (heure, attendue, secondes) in [
        (-5, premiere, 0),
        (-1, premiere, 0),
        (i64::MIN, premiere, 0),
        (0, premiere, 0),
        (DERNIERE_SECONDE, derniere, DERNIERE_SECONDE as u64),
        (DERNIERE_SECONDE + 1, derniere, DERNIERE_SECONDE as u64),
        (i64::MAX, derniere, DERNIERE_SECONDE as u64),
    ] {
        poste.regler_l_heure(heure);
        assert_eq!(lire_la_date(&poste), attendue, "{heure}, lue par l'invité");
        assert_eq!(
            poste.machine.herites.cmos.secondes_depuis_1970, secondes,
            "{heure}, dans les puces de la machine"
        );
    }
    assert_eq!(
        poste.machine.herites.cmos.date(),
        [9999, 12, 31, 23, 59, 59, 6],
        "le 31 décembre 9999 est un vendredi"
    );
}

/// **L'heure figée remplace l'horloge donnée** : sans cela, l'horloge de
/// l'hôte, relue au premier accès aux ports 0x70 et 0x71, passerait
/// par-dessus l'heure posée, et deux courses ne liraient plus la même date.
#[test]
fn a_frozen_hour_replaces_the_clock_it_was_given() {
    let mut poste = Poste::essayer(RAM).expect("la RAM");
    poste.horloge(|| 0); // 1970
    poste.regler_l_heure(1_795_230_600); // le 21 novembre 2026, 3 h 10 UTC
    let carte = poste.commandes().carte().clone();
    let mut carte = carte.tenir();
    let mut lire = |registre: u32| {
        assert!(carte.port_ecrire(0x70, 1, registre));
        carte.port_lire(0x71, 1).expect("l'horloge répond")
    };
    assert_eq!(
        (lire(0x09), lire(0x08), lire(0x07)),
        (0x26, 0x11, 0x21),
        "en BCD : 26, 11, 21"
    );
    assert_eq!(
        poste.machine.herites.cmos.secondes_depuis_1970,
        1_795_230_600
    );
}
