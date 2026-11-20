//! Les périphériques hérités de la machine PC : les deux 8259, le 8253, le
//! 16550 et l'horloge CMOS, et ce que la boucle d'exécution en fait. Portés
//! de `X86LegacyDevicesTests.swift`, avec les ports du 16550 tels que le
//! pilote 8250 de Linux les sonde.

use wisq_vm::pc::herites::{
    Herites, HorlogeCmos, Minuterie, INSTRUCTIONS_PAR_BATTEMENT, PLUS_COURT_COUP_UNIQUE,
};
use wisq_vm::pc::systeme::Table;
use wisq_vm::pc::Machine;
use wisq_vm::x86::{Width, IF};

const GESTIONNAIRE: u64 = 0x8000;
const IDT: u64 = 0x9000;
/// Assez pour que l'horloge batte quelques fois.
const QUELQUES_BATTEMENTS: u64 = 7 * INSTRUCTIONS_PAR_BATTEMENT;

/// Une machine sans pagination, du code à 0x100, un gestionnaire qui s'arrête
/// sur `hlt` derrière le vecteur 0x30, et une pile.
fn machine(code: &[u8]) -> Machine {
    let mut machine = Machine::nouvelle(0);
    let ram = &mut machine.cpu.memory;
    ram.bytes[0x100..0x100 + code.len()].copy_from_slice(code);
    ram.bytes[GESTIONNAIRE as usize] = 0xF4;
    // Une porte d'interruption (0x8E) vers le gestionnaire, sous le sélecteur
    // 0x10.
    let bas = (GESTIONNAIRE & 0xFFFF)
        | (0x10 << 16)
        | (0x8E << 40)
        | ((GESTIONNAIRE & 0xFFFF_0000) << 32);
    ram.write(IDT + 0x30 * 16, Width::Qword, bas);
    ram.write(IDT + 0x30 * 16 + 8, Width::Qword, 0);
    machine.systeme.idt = Table {
        base: IDT,
        limite: 0xFFF,
    };
    machine.cpu.rip = 0x100;
    machine.cpu.regs[4] = 0x7000;
    machine
}

/// L'horloge armée : la ligne zéro démasquée, ses vecteurs à 0x30, un
/// rechargement de deux battements, les interruptions permises.
fn armer(machine: &mut Machine) {
    machine.herites.maitre.masque = 0xFE;
    machine.herites.maitre.base_des_vecteurs = 0x30;
    machine.herites.minuterie.rechargement = 2;
    machine.cpu.flags.write(IF);
}

#[test]
fn the_mask_comes_back_from_the_port_it_was_written_to() {
    // mov $0xff,%al ; out %al,$0x21 ; in $0x21,%al ; mov %al,%bl ;
    // mov $0xfb,%al ; out %al,$0x21 ; in $0x21,%al
    let mut machine = machine(&[
        0xB0, 0xFF, 0xE6, 0x21, 0xE4, 0x21, 0x88, 0xC3, 0xB0, 0xFB, 0xE6, 0x21, 0xE4, 0x21,
    ]);
    machine.tourner(7).expect("sans faute");
    assert_eq!(
        machine.cpu.regs[3] & 0xFF,
        0xFF,
        "le premier masque doit revenir"
    );
    assert_eq!(machine.cpu.regs[0] & 0xFF, 0xFB, "et le second aussi");
}

#[test]
fn the_initialisation_words_are_not_mistaken_for_a_mask() {
    // ICW1 sur le port de commande, puis ICW2, ICW3, ICW4 et enfin le masque
    // sur le port de données.
    let mut machine = machine(&[
        0xB0, 0x11, 0xE6, 0x20, 0xB0, 0x30, 0xE6, 0x21, 0xB0, 0x04, 0xE6, 0x21, 0xB0, 0x01, 0xE6,
        0x21, 0xB0, 0xFE, 0xE6, 0x21,
    ]);
    machine.herites.maitre.masque = 0xAA;
    machine.tourner(8).expect("sans faute");
    assert_eq!(
        machine.herites.maitre.masque, 0xAA,
        "ICW2, ICW3 et ICW4 ne sont pas des masques"
    );
    machine.tourner(2).expect("sans faute");
    assert_eq!(machine.herites.maitre.base_des_vecteurs, 0x30);
    assert_eq!(
        machine.herites.maitre.masque, 0xFE,
        "le masque n'arrive qu'à la fin"
    );
    assert_eq!(machine.herites.maitre.etape, 0);
}

#[test]
fn the_second_controller_takes_its_own_initialisation_and_mask() {
    let mut cartes = Herites::default();
    for (port, octet) in [
        (0xA0, 0x11),
        (0xA1, 0x38),
        (0xA1, 0x02),
        (0xA1, 0x01),
        (0xA1, 0xEF),
    ] {
        assert!(cartes.port_ecrire(port, octet, 0));
    }
    assert_eq!(cartes.second.base_des_vecteurs, 0x38);
    assert_eq!(cartes.second.masque, 0xEF);
    assert_eq!(cartes.port_lire(0xA1, 0), Some(0xEF));
    assert_eq!(cartes.maitre.masque, 0xFF, "le maître n'a rien reçu");
}

/// Programmer le canal zéro par ses ports : le mot de commande, puis le
/// compte en deux octets.
fn programme(mode: u8, compte: u16) -> Machine {
    let mut machine = machine(&[
        0xB0,
        mode,
        0xE6,
        0x43,
        0xB0,
        compte as u8,
        0xE6,
        0x40,
        0xB0,
        (compte >> 8) as u8,
        0xE6,
        0x40,
    ]);
    machine.tourner(6).expect("sans faute");
    assert_eq!(machine.herites.minuterie.rechargement, compte);
    machine
}

#[test]
fn a_one_shot_of_a_millisecond_waits_for_four_milliseconds() {
    let minuterie = programme(0x38, 1193).herites.minuterie;
    assert!(minuterie.coup_unique, "le mode 4 compte une fois");
    let depart = minuterie.recharge_a;
    assert_eq!(
        minuterie.echeances(depart + 1193),
        0,
        "pas après une milliseconde"
    );
    assert_eq!(minuterie.echeances(depart + PLUS_COURT_COUP_UNIQUE - 1), 0);
    assert_eq!(
        minuterie.echeances(depart + PLUS_COURT_COUP_UNIQUE),
        1,
        "mais au bout de quatre"
    );
}

#[test]
fn a_longer_one_shot_keeps_its_own_deadline() {
    let minuterie = programme(0x30, 20_000).herites.minuterie;
    assert!(
        minuterie.coup_unique,
        "le mode 0 compte une fois, lui aussi"
    );
    let depart = minuterie.recharge_a;
    assert_eq!(minuterie.echeances(depart + 19_999), 0);
    assert_eq!(minuterie.echeances(depart + 20_000), 1);
}

#[test]
fn the_periodic_modes_keep_every_beat() {
    let minuterie = programme(0x34, 1193).herites.minuterie;
    assert!(!minuterie.coup_unique, "le mode 2 bat");
    let depart = minuterie.recharge_a;
    assert_eq!(minuterie.echeances(depart + 1193), 1, "chaque milliseconde");
    assert_eq!(minuterie.echeances(depart + 4 * 1193), 4);
    assert!(
        !programme(0x36, 1193).herites.minuterie.coup_unique,
        "le mode 3 bat aussi"
    );
}

#[test]
fn the_timer_reaches_the_handler() {
    let mut machine = machine(&[0xEB, 0xFE]); // une boucle infinie
    armer(&mut machine);
    machine.tourner(QUELQUES_BATTEMENTS).expect("sans faute");
    assert!(machine.arretee, "le gestionnaire s'arrête sur un hlt");
    assert_eq!(machine.cpu.rip, GESTIONNAIRE + 1);
    assert_eq!(
        machine.herites.maitre.service, 1,
        "la ligne zéro est en service"
    );
    assert_eq!(
        machine.herites.maitre.demande, 0,
        "et n'est plus en demande"
    );
    assert!(
        !machine.cpu.flags.interrupts_enabled(),
        "une porte d'interruption masque"
    );
    assert_eq!(machine.cpu.segments[1], 0x10, "CS vient de la porte");
}

#[test]
fn a_line_in_service_blocks_its_equals_and_its_inferiors() {
    let mut machine = machine(&[0xEB, 0xFE]);
    armer(&mut machine);
    machine.tourner(QUELQUES_BATTEMENTS).expect("sans faute");
    assert_eq!(machine.herites.maitre.service, 1);
    machine.cpu.flags.write(IF);
    machine.arretee = false;
    let entree = machine.cpu.rip;
    machine.herites.maitre.demande |= 1;
    machine.servir().expect("sans faute");
    assert_eq!(machine.cpu.rip, entree, "rien n'est entré une seconde fois");
    assert_ne!(
        machine.herites.maitre.demande & 1,
        0,
        "et la demande attend"
    );
}

#[test]
fn a_more_priority_line_preempts_what_is_in_service() {
    let mut machine = machine(&[0xEB, 0xFE]);
    armer(&mut machine);
    machine.herites.maitre.masque = 0xEE; // les lignes zéro et quatre
    machine.herites.maitre.service = 1 << 4; // la quatre est en service
    machine.herites.maitre.demande |= 1; // la zéro demande
    machine.servir().expect("sans faute");
    assert_eq!(
        machine.cpu.rip, GESTIONNAIRE,
        "la plus prioritaire est entrée"
    );
    assert_eq!(
        machine.herites.maitre.service, 0x11,
        "les deux sont en service"
    );
}

#[test]
fn an_end_of_interrupt_lets_the_next_one_in() {
    let mut machine = machine(&[0xEB, 0xFE]);
    armer(&mut machine);
    machine.herites.maitre.service = 1;
    machine.herites.maitre.demande |= 1;
    machine.servir().expect("sans faute");
    assert_ne!(
        machine.herites.maitre.demande & 1,
        0,
        "bloquée tant qu'elle sert"
    );
    machine.herites.port_ecrire(0x20, 0x20, 0); // fin d'interruption non spécifique
    assert_eq!(machine.herites.maitre.service, 0);
    machine.servir().expect("sans faute");
    assert_eq!(machine.cpu.rip, GESTIONNAIRE, "et elle entre");
}

#[test]
fn the_two_ends_of_interrupt_clear_what_they_name() {
    let mut cartes = Herites::default();
    cartes.maitre.service = 0x11; // les lignes zéro et quatre
    cartes.port_ecrire(0x20, 0x64, 0); // fin d'interruption pour la quatre
    assert_eq!(cartes.maitre.service, 0x01, "la quatre part, la zéro reste");
    cartes.port_ecrire(0x20, 0x60, 0); // et pour la zéro
    assert_eq!(cartes.maitre.service, 0);
    // La forme non spécifique retire la plus urgente.
    cartes.maitre.service = 0x11;
    cartes.port_ecrire(0x20, 0x20, 0);
    assert_eq!(cartes.maitre.service, 0x10, "la zéro part la première");
    // Et le second contrôleur a les deux mêmes formes.
    cartes.second.service = 0x12;
    cartes.port_ecrire(0xA0, 0x64, 0);
    assert_eq!(cartes.second.service, 0x02);
    cartes.port_ecrire(0xA0, 0x20, 0);
    assert_eq!(cartes.second.service, 0);
}

#[test]
fn a_masked_line_stays_pending() {
    let mut machine = machine(&[0xEB, 0xFE]);
    armer(&mut machine);
    machine.herites.maitre.masque = 0xFF;
    machine.tourner(QUELQUES_BATTEMENTS).expect("sans faute");
    assert!(!machine.arretee);
    assert_eq!(
        machine.herites.maitre.demande, 1,
        "la demande attend le démasquage"
    );
}

#[test]
fn interrupts_disabled_in_the_flags_hold_the_line_too() {
    let mut machine = machine(&[0xEB, 0xFE]);
    armer(&mut machine);
    machine.cpu.flags.write(0);
    machine.tourner(QUELQUES_BATTEMENTS).expect("sans faute");
    assert!(!machine.arretee);
    assert_eq!(machine.herites.maitre.demande, 1);
}

#[test]
fn a_line_with_no_gate_yet_stays_pending() {
    let mut machine = machine(&[0xEB, 0xFE]);
    armer(&mut machine);
    machine.herites.maitre.base_des_vecteurs = 0x40; // aucun gestionnaire à ce numéro
    machine.tourner(QUELQUES_BATTEMENTS).expect("sans faute");
    assert!(!machine.arretee);
    assert_eq!(
        machine.herites.maitre.demande, 1,
        "la demande attend sa porte"
    );
    assert_eq!(
        machine.herites.maitre.service, 0,
        "et n'est jamais entrée en service"
    );
}

#[test]
fn an_end_of_interrupt_written_by_the_guest_clears_the_service_bit() {
    let mut machine = machine(&[0xEB, 0xFE]);
    armer(&mut machine);
    machine.tourner(QUELQUES_BATTEMENTS).expect("sans faute");
    assert_eq!(machine.herites.maitre.service, 1);
    // mov $0x20,%al ; out %al,$0x20
    machine.cpu.memory.bytes[0x200..0x204].copy_from_slice(&[0xB0, 0x20, 0xE6, 0x20]);
    machine.cpu.rip = 0x200;
    machine.arretee = false;
    machine.tourner(2).expect("sans faute");
    assert_eq!(machine.herites.maitre.service, 0);
}

#[test]
fn hlt_waits_for_the_timer_rather_than_stopping() {
    let mut machine = machine(&[0xF4]);
    armer(&mut machine);
    machine.tourner(QUELQUES_BATTEMENTS).expect("sans faute");
    assert_eq!(
        machine.cpu.rip,
        GESTIONNAIRE + 1,
        "le battement doit l'avoir réveillé"
    );
    assert!(
        machine.attente > 0,
        "et du temps doit avoir passé pendant l'attente"
    );
    // Le saut d'attente va droit à l'échéance : deux battements, pas un tour
    // de plus.
    assert_eq!(
        machine.retirees + machine.attente,
        2 * INSTRUCTIONS_PAR_BATTEMENT + 1,
        "un hlt, l'attente jusqu'au battement, et le hlt du gestionnaire"
    );
}

#[test]
fn hlt_without_a_clock_stops_instead_of_burning_the_budget() {
    let mut machine = machine(&[0xF4]);
    machine.cpu.flags.write(IF);
    let faites = machine.tourner(1_000_000).expect("sans faute");
    assert!(
        faites < 10,
        "rien ne peut plus arriver : inutile d'attendre"
    );
    assert!(machine.arretee);
    // Et la boucle de la machine le nomme : éteinte.
    assert_eq!(machine.executer(1_000_000), wisq_vm::pc::Issue::Eteinte);
}

#[test]
fn the_counter_counts_down_and_reloads() {
    let minuterie = Minuterie {
        rechargement: 100,
        ..Default::default()
    };
    assert_eq!(minuterie.compte(0), 100);
    assert_eq!(minuterie.compte(30), 70);
    assert_eq!(
        minuterie.compte(100),
        100,
        "au débordement, il repart d'en haut"
    );
    assert_eq!(minuterie.echeances(250), 2);
    assert_eq!(minuterie.prochaine(), Some(100));
    assert_eq!(
        Minuterie::default().prochaine(),
        None,
        "un canal jamais armé"
    );
}

#[test]
fn the_latch_freezes_the_count_for_both_halves_of_a_reading() {
    // Verrouiller, lire l'octet bas, laisser passer du temps, lire l'octet
    // haut : les deux moitiés doivent venir du même instant.
    let mut code = vec![0xB0, 0x00, 0xE6, 0x43, 0xE4, 0x40, 0x88, 0xC3];
    code.extend([0x90; 600]);
    code.extend([0xE4, 0x40]);
    let mut machine = machine(&code);
    machine.herites.minuterie.rechargement = 0x3000;
    machine.tourner(4 + 600 + 1).expect("sans faute");
    let bas = machine.cpu.regs[3] & 0xFF;
    let haut = machine.cpu.regs[0] & 0xFF;
    assert_eq!(haut << 8 | bas, 0x3000);
    // Sans verrou, la lecture suit le temps.
    let mut cartes = Herites::default();
    cartes.minuterie.rechargement = 0x3000;
    assert_eq!(cartes.port_lire(0x40, 0x10), Some(0xF0));
    assert_eq!(cartes.port_lire(0x40, 0x10), Some(0x2F));
}

#[test]
fn port_sixty_one_reports_the_second_channel_finishing() {
    let mut minuterie = Minuterie {
        haut_parleur: 50,
        ..Default::default()
    };
    assert!(!minuterie.haut_parleur_fini(100), "la porte est fermée");
    minuterie.porte = true;
    minuterie.haut_parleur_parti_a = 100;
    assert!(!minuterie.haut_parleur_fini(120));
    assert!(minuterie.haut_parleur_fini(150));
    assert_eq!(minuterie.compte_du_haut_parleur(120), 30);
    assert_eq!(minuterie.compte_du_haut_parleur(200), 0);
    // Par les ports, comme Linux étalonne son compteur de cycles : le compte
    // sur le canal deux, la porte ouverte par le port 0x61, et le bit 5 qui
    // dit quand c'est fini.
    let mut cartes = Herites::default();
    cartes.port_ecrire(0x43, 0xB0, 1000);
    cartes.port_ecrire(0x42, 0x32, 1000);
    cartes.port_ecrire(0x42, 0x00, 1000);
    cartes.port_ecrire(0x61, 0x01, 1000);
    assert_eq!(cartes.port_lire(0x61, 1020).unwrap() & 0x20, 0);
    assert_eq!(cartes.port_lire(0x61, 1050).unwrap() & 0x21, 0x21);
}

/// La cascade : une ligne du second contrôleur entre par la ligne deux du
/// maître, avec le vecteur du second, et les deux la gardent en service.
#[test]
fn a_line_of_the_second_controller_comes_through_the_cascade() {
    let mut cartes = Herites::default();
    cartes.maitre.masque = 0xFB; // seule la cascade est démasquée
    cartes.maitre.base_des_vecteurs = 0x30;
    cartes.second.masque = 0xEF; // la ligne douze
    cartes.second.base_des_vecteurs = 0x38;
    cartes.lever(0, 1 << 12);
    let candidat = cartes.candidat().expect("la ligne douze demande");
    assert_eq!(candidat.vecteur, 0x38 + 4);
    assert_eq!(candidat.seconde, Some(4));
    cartes.livree(candidat);
    assert_eq!(cartes.second.service, 1 << 4);
    assert_eq!(cartes.maitre.service, 1 << 2);
    // La ligne retombe : à niveau, la demande suit la condition.
    cartes.lever(0, 0);
    assert_eq!(cartes.second.demande, 0);
    assert_eq!(cartes.maitre.demande & 4, 0);
    // Une ligne du maître, à niveau elle aussi ; les lignes 0, 2 et 4
    // appartiennent à la carte et ne se lèvent pas de l'extérieur.
    cartes.lever(0, (1 << 1) | 1 | (1 << 4));
    assert_eq!(cartes.maitre.demande, 1 << 1);
}

// ---- Le 16550, tel que le pilote 8250 de Linux le sonde ----

const SERIE: u16 = 0x3F8;

#[test]
fn the_serial_port_answers_the_probe_of_the_8250_driver() {
    let mut cartes = Herites::default();
    // Le registre d'autorisation se relit (quatre bits).
    cartes.port_ecrire(SERIE + 1, 0x0F, 0);
    assert_eq!(cartes.port_lire(SERIE + 1, 0), Some(0x0F));
    cartes.port_ecrire(SERIE + 1, 0, 0);
    // En boucle, les sorties du modem reviennent sur ses entrées : la sonde
    // écrit OUT2 | RTS et attend DCD | CTS.
    cartes.port_ecrire(SERIE + 4, 0x10 | 0x0A, 0);
    assert_eq!(cartes.port_lire(SERIE + 6, 0).unwrap() & 0xF0, 0x90);
    cartes.port_ecrire(SERIE + 4, 0, 0);
    assert_eq!(
        cartes.port_lire(SERIE + 6, 0),
        Some(0xB0),
        "sinon, un câble branché"
    );
    // Le brouillon garde ce qu'on y met.
    cartes.port_ecrire(SERIE + 7, 0x5A, 0);
    assert_eq!(cartes.port_lire(SERIE + 7, 0), Some(0x5A));
    // L'identification dit s'il y a une FIFO : « 16550A ».
    assert_eq!(cartes.port_lire(SERIE + 2, 0), Some(0x01));
    cartes.port_ecrire(SERIE + 2, 0x01, 0);
    assert_eq!(cartes.port_lire(SERIE + 2, 0), Some(0xC1));
    // Le diviseur apparaît derrière DLAB, à la place du tampon.
    cartes.port_ecrire(SERIE + 3, 0x80, 0);
    cartes.port_ecrire(SERIE, 12, 0);
    cartes.port_ecrire(SERIE + 1, 0, 0);
    assert_eq!(cartes.serie.diviseur, 12);
    assert_eq!(cartes.port_lire(SERIE, 0), Some(12));
    cartes.port_ecrire(SERIE + 3, 0x03, 0);
    assert!(
        cartes.serie.sortie.is_empty(),
        "le diviseur n'est pas sorti sur la ligne"
    );
}

#[test]
fn the_serial_port_carries_bytes_both_ways_and_interrupts_for_each() {
    let mut cartes = Herites::default();
    cartes.maitre.masque = 0xEF;
    cartes.maitre.base_des_vecteurs = 0x30;
    // La sortie : l'octet part, le transmetteur est vide aussitôt.
    cartes.port_ecrire(SERIE, u32::from(b'A'), 0);
    assert_eq!(cartes.serie.sortie, b"A");
    assert_eq!(
        cartes.port_lire(SERIE + 5, 0),
        Some(0x60),
        "le transmetteur est vide"
    );
    // L'émission n'interrompt que si on l'autorise, et l'identification
    // l'acquitte.
    cartes.lever(0, 0);
    assert_eq!(cartes.candidat(), None);
    cartes.port_ecrire(SERIE + 1, 0x02, 0);
    cartes.lever(0, 0);
    assert_eq!(cartes.candidat().map(|c| c.vecteur), Some(0x34));
    assert_eq!(
        cartes.port_lire(SERIE + 2, 0),
        Some(0x02),
        "la cause : l'émission"
    );
    cartes.lever(0, 0);
    assert_eq!(
        cartes.candidat(),
        None,
        "à niveau : acquittée, la demande retombe"
    );
    // L'entrée : la réception passe devant l'émission, et la donnée prête se
    // lit dans l'état de la ligne.
    cartes.port_ecrire(SERIE + 1, 0x03, 0);
    cartes.serie.entree.extend(b"ok");
    cartes.port_ecrire(SERIE, u32::from(b'B'), 0);
    assert_eq!(cartes.port_lire(SERIE + 5, 0), Some(0x61));
    cartes.lever(0, 0);
    assert!(cartes.candidat().is_some());
    assert_eq!(
        cartes.port_lire(SERIE + 2, 0),
        Some(0x04),
        "la cause : la réception"
    );
    assert_eq!(cartes.port_lire(SERIE, 0), Some(u32::from(b'o')));
    assert_eq!(cartes.port_lire(SERIE, 0), Some(u32::from(b'k')));
    assert_eq!(cartes.port_lire(SERIE, 0), Some(0), "plus rien à lire");
    assert_eq!(
        cartes.port_lire(SERIE + 2, 0),
        Some(0x02),
        "reste l'émission"
    );
    // En boucle, ce qu'on écrit revient par la réception.
    cartes.port_ecrire(SERIE + 4, 0x10, 0);
    cartes.port_ecrire(SERIE, 0x77, 0);
    assert_eq!(cartes.port_lire(SERIE, 0), Some(0x77));
    assert_eq!(cartes.serie.sortie, b"AB", "et ne sort pas sur la ligne");
}

/// Ce que l'invité écrit sort par `sortie`, ce que l'hôte tape entre par
/// `taper` et réveille un invité qui dort.
#[test]
fn typing_wakes_a_halted_guest_through_the_serial_interrupt() {
    // Le gestionnaire lit l'octet (in $0x3f8,%al → mov $0x3f8,%dx ; in (%dx),%al),
    // le réécrit, et s'arrête.
    let mut machine = machine(&[0xF4]);
    let gestionnaire = [0xBA, 0xF8, 0x03, 0x00, 0x00, 0xEC, 0xEE, 0xF4];
    let ou = GESTIONNAIRE as usize;
    machine.cpu.memory.bytes[ou..ou + gestionnaire.len()].copy_from_slice(&gestionnaire);
    // La porte du vecteur 0x34 : la ligne quatre.
    let bas = (GESTIONNAIRE & 0xFFFF) | (0x10 << 16) | (0x8E << 40);
    machine.cpu.memory.write(IDT + 0x34 * 16, Width::Qword, bas);
    machine.herites.maitre.masque = 0xEF;
    machine.herites.maitre.base_des_vecteurs = 0x30;
    machine.herites.serie.autorisation = 0x01;
    machine.cpu.flags.write(IF);
    // Rien de tapé : la machine dort, et la boucle rend la main sans rien
    // exécuter de plus — mais elle n'est pas éteinte, le port série écoute.
    machine.tourner(1000).expect("sans faute");
    assert!(machine.arretee);
    machine.taper(b"x");
    machine.tourner(1000).expect("sans faute");
    assert_eq!(machine.sortie(), b"x", "l'octet tapé est revenu");
    assert!(
        machine.sortie().is_empty(),
        "et la sortie se prend une fois"
    );
}

// ---- L'horloge CMOS ----

#[test]
fn the_cmos_clock_reads_the_date_it_was_given_in_bcd() {
    let mut horloge = HorlogeCmos::default();
    // Le 20 novembre 2026 à 12:15:34 UTC, un vendredi.
    horloge.regler(1_795_176_934);
    assert_eq!(horloge.date(), [2026, 11, 20, 12, 15, 34, 6]);
    let mut cartes = Herites {
        cmos: horloge,
        ..Default::default()
    };
    let mut lire = |registre: u8| {
        cartes.port_ecrire(0x70, u32::from(registre), 0);
        cartes.port_lire(0x71, 0).unwrap()
    };
    assert_eq!(lire(0x00), 0x34, "les secondes, en BCD");
    assert_eq!(lire(0x02), 0x15);
    assert_eq!(lire(0x04), 0x12);
    assert_eq!(lire(0x07), 0x20);
    assert_eq!(lire(0x08), 0x11);
    assert_eq!(lire(0x09), 0x26);
    assert_eq!(lire(0x32), 0x20, "le siècle");
    assert_eq!(lire(0x0A) & 0x80, 0, "aucune mise à jour en cours");
    assert_eq!(lire(0x0B), 0x02, "vingt-quatre heures, BCD");
    assert_eq!(lire(0x0D), 0x80, "la pile est bonne");
    // En binaire quand le registre B le demande.
    cartes.port_ecrire(0x70, 0x0B, 0);
    cartes.port_ecrire(0x71, 0x06, 0);
    cartes.port_ecrire(0x70, 0x00, 0);
    assert_eq!(cartes.port_lire(0x71, 0), Some(34));
    // Et la mémoire garde ce qu'on y met.
    cartes.port_ecrire(0x70, 0x40, 0);
    cartes.port_ecrire(0x71, 0xAB, 0);
    assert_eq!(cartes.port_lire(0x71, 0), Some(0xAB));
}

#[test]
fn the_calendar_knows_leap_years_and_the_epoch() {
    let mut horloge = HorlogeCmos::default();
    assert_eq!(horloge.date(), [1970, 1, 1, 0, 0, 0, 5], "un jeudi");
    horloge.regler(951_782_400); // le 29 février 2000
    assert_eq!(horloge.date()[..3], [2000, 2, 29]);
    horloge.regler(4_107_542_399); // le 28 février 2100, 23:59:59 : pas bissextile
    assert_eq!(horloge.date()[..3], [2100, 2, 28]);
    horloge.regler(4_107_542_400);
    assert_eq!(horloge.date()[..3], [2100, 3, 1]);
}

/// Un port où personne ne répond rend des uns, comme le bus d'un vrai PC, et
/// la machine le note.
#[test]
fn a_port_nobody_answers_reads_as_ones_and_is_remembered() {
    // in $0x64,%al ; in $0x64,%eax (66 = 16 bits) ; out %al,$0x80
    let mut machine = machine(&[0xE4, 0x64, 0x66, 0xE5, 0x64, 0xE6, 0x80]);
    machine.cpu.regs[0] = 0x1122_3344_5566_7788;
    machine.tourner(1).expect("sans faute");
    assert_eq!(machine.cpu.regs[0], 0x1122_3344_5566_77FF);
    machine.tourner(2).expect("sans faute");
    assert_eq!(machine.cpu.regs[0], 0x1122_3344_5566_FFFF);
    assert_eq!(machine.ports_muets.get(&0x64), Some(&2));
    assert_eq!(machine.ports_muets.get(&0x80), Some(&1));
}
