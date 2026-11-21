//! **Le poste** : la machine PC menée comme une application la mène — ce que
//! l'ABI C (`wisq_pc_*`) tend à Swift. Le programme C (`abi/pc.c`) juge la
//! frontière ; ceci juge ce qui est derrière elle, au détail : la frappe et
//! son annulation, le temps passé dehors, l'écran copié, l'instantané champ par
//! champ.

use std::sync::Arc;

use wisq_carte::ecran::{BASE_DE_LA_MEMOIRE_VIDEO, PORT_DONNEE, PORT_INDEX};
use wisq_carte::i8042::{CodeTouche, LIMITE_DE_FRAPPE};
use wisq_vm::pc::instantane::{self, RefusDInstantane, MAGIE, VERSION};
use wisq_vm::pc::poste::{
    frappes_du_jeu_1, RefusDeBranchement, RefusDeTouches, FRAPPES_REMISES,
    PAS_DE_RATTRAPAGE_EN_SECONDES,
};
use wisq_vm::pc::{Fin, Poste};

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
