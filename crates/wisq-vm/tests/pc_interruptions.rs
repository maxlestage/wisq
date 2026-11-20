//! La livraison des fautes et des interruptions en mode long, et les
//! instructions de système de la machine PC. Portés de
//! `X86InterruptTests.swift`, puis ce que ce cœur ajoute : les contrôles de
//! privilège, `syscall`, `swapgs`, les registres spécifiques au modèle.

use wisq_vm::pc::machine::{Alea, GRAINE_REPRODUCTIBLE};
use wisq_vm::pc::systeme::{
    cpuid, Table, MSR_EFER, MSR_FS_BASE, MSR_GS_BASE, MSR_KERNEL_GS_BASE, MSR_LSTAR, MSR_SFMASK,
    MSR_STAR,
};
use wisq_vm::pc::Machine;
use wisq_vm::x86::{Width, CF, IF};

const IDT: u64 = 0x9000;
const GESTIONNAIRE: u64 = 0x8000;
const SOMMET: u64 = 0x7000;
/// Une adresse dont la page n'est pas cartographiée.
const ABSENTE: u64 = 0xB123;
const PAGES: [u64; 9] = [
    0x1000, 0x2000, 0x3000, 0x4000, 0x5000, 0x6000, 0x8000, 0x9000, 0xA000,
];

fn ecrire(machine: &mut Machine, adresse: u64, valeur: u64) {
    machine
        .cpu
        .memory
        .write(adresse, Width::Qword, valeur)
        .expect("dans la RAM");
}

fn lire(machine: &Machine, adresse: u64) -> u64 {
    machine
        .cpu
        .memory
        .read(adresse, Width::Qword)
        .expect("dans la RAM")
}

fn poser(machine: &mut Machine, adresse: u64, octets: &[u8]) {
    let ou = adresse as usize;
    machine.cpu.memory.bytes[ou..ou + octets.len()].copy_from_slice(octets);
}

/// Une porte de l'IDT : la cible, le sélecteur, et l'octet de genre (0x8E une
/// porte d'interruption, 0x8F de trappe, 0xEE ouverte à l'anneau trois).
fn porte(machine: &mut Machine, vecteur: u64, cible: u64, genre: u64) {
    let bas = (cible & 0xFFFF) | (0x10 << 16) | (genre << 40) | ((cible & 0xFFFF_0000) << 32);
    ecrire(machine, IDT + vecteur * 16, bas);
    ecrire(machine, IDT + vecteur * 16 + 8, cible >> 32);
}

/// Une machine en mode long : quatre niveaux de tables à 0x2000, les pages de
/// `PAGES` cartographiées en identité (présentes, inscriptibles, ouvertes à
/// l'anneau trois), du code à 0x1000, une pile, une IDT de trente-deux portes.
fn nouvelle(code: &[u8]) -> Machine {
    let mut machine = Machine::nouvelle(0);
    let ouverte = 0x7;
    ecrire(&mut machine, 0x2000, 0x3000 | ouverte);
    ecrire(&mut machine, 0x3000, 0x4000 | ouverte);
    ecrire(&mut machine, 0x4000, 0x5000 | ouverte);
    for page in PAGES {
        ecrire(
            &mut machine,
            0x5000 + ((page >> 12) & 0x1FF) * 8,
            page | ouverte,
        );
    }
    poser(&mut machine, 0x1000, code);
    poser(&mut machine, GESTIONNAIRE, &[0xF4]);
    machine.cpu.rip = 0x1000;
    machine.cpu.control[3] = 0x2000;
    machine.cpu.control[4] = 1 << 5;
    machine.cpu.efer = (1 << 8) | (1 << 10);
    machine.cpu.control[0] = (1 << 31) | 1;
    machine.cpu.regs[4] = SOMMET;
    machine.systeme.idt = Table {
        base: IDT,
        limite: 0x1FF,
    };
    machine
}

/// Avec une porte pour la faute de page.
fn preparee(code: &[u8]) -> Machine {
    let mut machine = nouvelle(code);
    porte(&mut machine, 14, GESTIONNAIRE, 0x8E);
    machine
}

/// Une GDT avec un segment d'état de tâche, et `ltr` : la pile du noyau que
/// le processeur prendra en quittant l'anneau trois.
fn charger_la_tache(machine: &mut Machine, pile_du_noyau: u64) {
    let (gdt, tss) = (0x6000u64, 0x6100u64);
    ecrire(
        machine,
        gdt + 0x40,
        0x67 | ((tss & 0xFF_FFFF) << 16) | (0x89 << 40),
    );
    ecrire(machine, gdt + 0x48, 0);
    ecrire(machine, tss + 4, pile_du_noyau);
    machine.systeme.gdt = Table {
        base: gdt,
        limite: 0x7F,
    };
    machine
        .systeme
        .charger_la_tache(&mut machine.cpu, 0x40)
        .expect("un TSS dans la GDT");
}

#[test]
fn the_stack_frame_is_the_one_a_handler_expects() {
    // mov %al,(%rbx)
    let mut machine = preparee(&[0x88, 0x03]);
    machine.cpu.regs[3] = ABSENTE;
    machine.cpu.segments[1] = 0x08;
    machine.cpu.segments[2] = 0x18;
    let avant = machine.cpu.flags.read();
    machine.tourner(1).expect("livrée");
    assert_eq!(
        machine.cpu.rip, GESTIONNAIRE,
        "la reprise est dans le gestionnaire"
    );
    assert_eq!(
        machine.cpu.segments[1], 0x10,
        "CS vient du sélecteur de la porte"
    );
    let pointeur = SOMMET - 48;
    assert_eq!(machine.cpu.regs[4], pointeur);
    assert_eq!(
        lire(&machine, pointeur),
        2,
        "code d'erreur : absente, en écriture"
    );
    assert_eq!(
        lire(&machine, pointeur + 8),
        0x1000,
        "l'adresse empilée est celle de l'instruction **fautive**"
    );
    assert_eq!(lire(&machine, pointeur + 16), 0x08, "l'ancien CS");
    assert_eq!(lire(&machine, pointeur + 24), avant);
    assert_eq!(lire(&machine, pointeur + 32), SOMMET, "l'ancien RSP");
    assert_eq!(lire(&machine, pointeur + 40), 0x18, "l'ancien SS");
    assert_eq!(
        machine.cpu.control[2], ABSENTE,
        "CR2 porte l'adresse entière"
    );
    assert_eq!(
        machine.retirees, 0,
        "une instruction qui faute n'est pas retirée"
    );
}

#[test]
fn the_error_code_says_what_the_access_was() {
    // Une lecture : aucun bit.
    let mut lecture = preparee(&[0x8A, 0x03]);
    lecture.cpu.regs[3] = ABSENTE;
    lecture.tourner(1).expect("livrée");
    assert_eq!(lire(&lecture, lecture.cpu.regs[4]), 0);
    // Une écriture.
    let mut ecriture = preparee(&[0x88, 0x03]);
    ecriture.cpu.regs[3] = ABSENTE;
    ecriture.tourner(1).expect("livrée");
    assert_eq!(lire(&ecriture, ecriture.cpu.regs[4]), 1 << 1);
    // Une lecture d'instruction.
    let mut instruction = preparee(&[0x90]);
    instruction.cpu.rip = 0xB000;
    instruction.tourner(1).expect("livrée");
    assert_eq!(lire(&instruction, instruction.cpu.regs[4]), 1 << 4);
    assert_eq!(instruction.cpu.control[2], 0xB000);
}

#[test]
fn the_error_code_says_when_the_fault_came_from_a_program() {
    for (selecteur, programme) in [(0x10u16, false), (0x33, true)] {
        let mut machine = preparee(&[0x8A, 0x03]);
        machine.cpu.regs[3] = ABSENTE;
        machine.cpu.segments[1] = selecteur;
        charger_la_tache(&mut machine, SOMMET);
        machine.tourner(1).expect("livrée");
        let code = lire(&machine, machine.cpu.regs[4]);
        assert_eq!(code & (1 << 2) != 0, programme, "sélecteur {selecteur:#x}");
    }
}

#[test]
fn the_frame_is_aligned_but_the_old_pointer_is_not() {
    let mut machine = preparee(&[0x88, 0x03]);
    machine.cpu.regs[3] = ABSENTE;
    machine.cpu.regs[4] = SOMMET - 4;
    machine.tourner(1).expect("livrée");
    assert_eq!(
        machine.cpu.regs[4] % 16,
        0,
        "le cadre part d'une pile alignée"
    );
    assert_eq!(machine.cpu.regs[4], SOMMET - 16 - 48);
    assert_eq!(
        lire(&machine, machine.cpu.regs[4] + 32),
        SOMMET - 4,
        "et l'ancien RSP est rendu sans arrondi"
    );
}

#[test]
fn an_interrupt_gate_masks_and_a_trap_gate_does_not() {
    for (genre, masquees) in [(0x8E, true), (0x8F, false)] {
        let mut machine = nouvelle(&[0x88, 0x03]);
        porte(&mut machine, 14, GESTIONNAIRE, genre);
        machine.cpu.regs[3] = ABSENTE;
        machine.cpu.flags.write(IF);
        machine.tourner(1).expect("livrée");
        assert_eq!(
            !machine.cpu.flags.interrupts_enabled(),
            masquees,
            "porte {genre:#x}"
        );
    }
}

#[test]
fn a_fault_that_cannot_be_delivered_stops_the_machine_and_names_itself() {
    // Sans IDT.
    let mut sans_table = nouvelle(&[0x88, 0x03]);
    sans_table.systeme.idt = Table::default();
    sans_table.cpu.regs[3] = ABSENTE;
    let pourquoi = sans_table.tourner(1).expect_err("rien pour la recevoir");
    assert!(pourquoi.contains("FauteDePage"), "{pourquoi}");
    assert!(pourquoi.contains("b123"), "l'adresse est dite : {pourquoi}");
    assert_eq!(sans_table.cpu.rip, 0x1000, "RIP reste sur l'instruction");
    assert_eq!(sans_table.cpu.regs[4], SOMMET, "et la pile n'a pas bougé");
    // Une porte absente (le bit de présence à zéro).
    let mut absente = nouvelle(&[0x88, 0x03]);
    porte(&mut absente, 14, GESTIONNAIRE, 0x0E);
    absente.cpu.regs[3] = ABSENTE;
    assert!(absente.tourner(1).is_err());
    // `ud2` sans porte sort avec son nom.
    let mut indefinie = nouvelle(&[0x0F, 0x0B]);
    let pourquoi = indefinie.tourner(1).expect_err("pas de porte");
    assert!(pourquoi.contains("Indefinie"), "{pourquoi}");
}

#[test]
fn a_short_limit_stops_at_the_vector_it_covers() {
    // div %ecx, ECX nul : le vecteur zéro, couvert par une limite de quinze.
    let mut division = nouvelle(&[0xF7, 0xF1]);
    porte(&mut division, 0, GESTIONNAIRE, 0x8E);
    porte(&mut division, 14, GESTIONNAIRE, 0x8E);
    division.systeme.idt.limite = 15;
    division.tourner(1).expect("livrée");
    assert_eq!(division.cpu.rip, GESTIONNAIRE);
    assert_eq!(division.cpu.regs[4], SOMMET - 40, "cinq cases, pas six");
    assert_eq!(
        lire(&division, division.cpu.regs[4]),
        0x1000,
        "en haut de la pile : l'adresse de reprise, pas un code d'erreur"
    );
    // Le vecteur quatorze ne l'est pas.
    let mut faute = nouvelle(&[0x88, 0x03]);
    porte(&mut faute, 14, GESTIONNAIRE, 0x8E);
    faute.systeme.idt.limite = 15;
    faute.cpu.regs[3] = ABSENTE;
    assert!(faute.tourner(1).is_err());
}

#[test]
fn ud2_is_delivered_to_vector_six_and_resumes_on_itself() {
    let mut machine = nouvelle(&[0x0F, 0x0B]);
    porte(&mut machine, 6, GESTIONNAIRE, 0x8E);
    machine.tourner(1).expect("livrée");
    assert_eq!(machine.cpu.rip, GESTIONNAIRE);
    assert_eq!(
        machine.cpu.regs[4],
        SOMMET - 40,
        "cinq cases : pas de code d'erreur"
    );
    assert_eq!(
        lire(&machine, machine.cpu.regs[4]),
        0x1000,
        "la reprise pointe sur le ud2 lui-même"
    );
}

/// `0F 0E` (`femms`, du 3DNow!) : une forme qu'aucun des deux décodeurs ne
/// lit.
const INCONNUE: [u8; 2] = [0x0F, 0x0E];

#[test]
fn an_unknown_form_in_the_kernel_stops_the_machine_by_name() {
    let mut machine = nouvelle(&INCONNUE);
    for vecteur in 0..32 {
        porte(&mut machine, vecteur, GESTIONNAIRE, 0x8E);
    }
    let pourquoi = machine
        .tourner(1)
        .expect_err("un refus nommé, pas une exception");
    assert!(
        pourquoi.contains("0f 0e"),
        "les octets sont dits : {pourquoi}"
    );
    assert!(pourquoi.contains("0x1000"), "et l'adresse : {pourquoi}");
    assert_eq!(machine.cpu.rip, 0x1000);
    assert!(machine.refus.is_empty());
}

#[test]
fn an_unknown_form_in_a_program_is_delivered_as_invalid_opcode_and_remembered() {
    let mut machine = nouvelle(&INCONNUE);
    porte(&mut machine, 6, GESTIONNAIRE, 0x8E);
    machine.cpu.segments[1] = 0x33;
    charger_la_tache(&mut machine, SOMMET);
    machine.tourner(1).expect("livrée au programme");
    assert_eq!(machine.cpu.rip, GESTIONNAIRE, "livrée au vecteur 6");
    assert_eq!(machine.refus.len(), 1);
    assert!(
        machine.refus[0].contains("(0f 0e "),
        "et nommée : {:?}",
        machine.refus
    );
    // Sans porte, le refus sort quand même, par son nom.
    let mut sans_porte = nouvelle(&INCONNUE);
    sans_porte.cpu.segments[1] = 0x33;
    charger_la_tache(&mut sans_porte, SOMMET);
    assert!(sans_porte.tourner(1).is_err());
}

#[test]
fn the_handler_maps_the_page_and_the_instruction_runs_again() {
    // Le programme : mov %al,(%rbx) ; hlt.
    let mut machine = preparee(&[0x88, 0x03, 0xF4]);
    // Le gestionnaire : compter son passage en 0xA000, cartographier la page
    // manquante (une entrée de table en 0x5058), défaire le code d'erreur,
    // `iretq`.
    poser(
        &mut machine,
        GESTIONNAIRE,
        &[
            0xFF, 0x04, 0x25, 0x00, 0xA0, 0x00, 0x00, // incl 0xa000
            0x50, // push %rax
            0x48, 0xC7, 0x04, 0x25, 0x58, 0x50, 0x00, 0x00, 0x01, 0xB0, 0x00,
            0x00, // movq $0xb001,0x5058
            0x58, // pop %rax
            0x48, 0x83, 0xC4, 0x08, // add $8,%rsp
            0x48, 0xCF, // iretq
        ],
    );
    machine.cpu.regs[0] = 0x5A;
    machine.cpu.regs[3] = ABSENTE;
    machine.cpu.segments[1] = 0x08;
    machine.cpu.segments[2] = 0x18;
    let drapeaux = machine.cpu.flags.read();
    machine.tourner(100).expect("sans arrêt");
    assert!(
        machine.arretee,
        "le hlt qui suit l'écriture doit être atteint"
    );
    assert_eq!(
        lire(&machine, 0xA000) & 0xFFFF_FFFF,
        1,
        "la première instruction du gestionnaire s'exécute une fois, pas deux"
    );
    assert_eq!(
        machine.cpu.memory.bytes[ABSENTE as usize], 0x5A,
        "l'instruction fautive doit s'être exécutée pour de bon"
    );
    assert_eq!(
        machine.cpu.regs[4], SOMMET,
        "la pile est revenue où elle était"
    );
    assert_eq!(machine.cpu.segments[1], 0x08, "iretq rend l'ancien CS");
    assert_eq!(machine.cpu.segments[2], 0x18, "et l'ancien SS");
    assert_eq!(
        machine.cpu.flags.read(),
        drapeaux,
        "et les anciens drapeaux"
    );
    assert_eq!(
        machine.cpu.control[2], ABSENTE,
        "CR2 garde la dernière faute"
    );
    // Six du gestionnaire, l'écriture rejouée, le hlt.
    assert_eq!(machine.retirees, 8);
    // Et le processeur a marqué la page : accédée et salie.
    assert_eq!(lire(&machine, 0x5058) & 0x61, 0x61);
}

#[test]
fn iretq_leaves_the_error_code_to_the_handler() {
    let mut machine = nouvelle(&[0x48, 0xCF]);
    let pointeur = SOMMET - 48;
    for (rang, valeur) in [7, 0x1234, 0x08, CF | 2, SOMMET, 0x18]
        .into_iter()
        .enumerate()
    {
        ecrire(&mut machine, pointeur + 8 * rang as u64, valeur);
    }
    machine.cpu.regs[4] = pointeur + 8;
    machine.tourner(1).expect("sans faute");
    assert_eq!(machine.cpu.rip, 0x1234);
    assert_eq!(machine.cpu.segments[1], 0x08);
    assert_eq!(machine.cpu.flags.read(), CF | 2);
    assert_eq!(machine.cpu.regs[4], SOMMET);
    assert_eq!(machine.cpu.segments[2], 0x18);
}

#[test]
fn lidt_copies_the_descriptor_rather_than_remembering_where_it_was() {
    // lidt 0xa000 ; sidt 0xa020
    let mut machine = nouvelle(&[
        0x0F, 0x01, 0x1C, 0x25, 0x00, 0xA0, 0x00, 0x00, 0x0F, 0x01, 0x0C, 0x25, 0x20, 0xA0, 0x00,
        0x00,
    ]);
    machine.systeme.idt = Table::default();
    poser(&mut machine, 0xA000, &0x1FFu16.to_le_bytes());
    ecrire(&mut machine, 0xA002, IDT);
    machine.tourner(1).expect("sans faute");
    // Ce que la mémoire devient ensuite ne change plus la table chargée.
    poser(&mut machine, 0xA000, &[0, 0]);
    ecrire(&mut machine, 0xA002, 0xDEAD);
    machine.tourner(1).expect("sans faute");
    assert_eq!(
        machine.systeme.idt,
        Table {
            base: IDT,
            limite: 0x1FF
        }
    );
    assert_eq!(
        lire(&machine, 0xA020) & 0xFFFF,
        0x1FF,
        "sidt rend la limite"
    );
    assert_eq!(
        lire(&machine, 0xA022),
        IDT,
        "et la base, dans la même forme"
    );
}

// ---- Ce que ce cœur ajoute au cœur Swift ----

/// Une instruction réservée au noyau, exécutée par un programme : `#GP(0)`, et
/// rien n'a été fait.
#[test]
fn privileged_instructions_fault_in_ring_three() {
    let reservees: [(&str, &[u8]); 9] = [
        ("hlt", &[0xF4]),
        ("cli", &[0xFA]),
        ("in $0x21,%al", &[0xE4, 0x21]),
        ("out %al,$0x21", &[0xE6, 0x21]),
        ("rdmsr", &[0x0F, 0x32]),
        ("wrmsr", &[0x0F, 0x30]),
        ("mov %cr3,%rax", &[0x0F, 0x20, 0xD8]),
        ("mov %rax,%cr3", &[0x0F, 0x22, 0xD8]),
        ("swapgs", &[0x0F, 0x01, 0xF8]),
    ];
    for (nom, code) in reservees {
        let mut machine = nouvelle(code);
        porte(&mut machine, 13, GESTIONNAIRE, 0x8E);
        machine.cpu.segments[1] = 0x33;
        machine.cpu.regs[1] = u64::from(MSR_GS_BASE);
        machine.herites.maitre.masque = 0x55;
        charger_la_tache(&mut machine, SOMMET);
        machine.tourner(1).expect("livrée");
        assert_eq!(machine.cpu.rip, GESTIONNAIRE, "{nom} : #GP livrée");
        assert_eq!(
            lire(&machine, machine.cpu.regs[4]),
            0,
            "{nom} : code d'erreur nul"
        );
        assert_eq!(
            lire(&machine, machine.cpu.regs[4] + 8),
            0x1000,
            "{nom} : sur l'instruction"
        );
        assert!(!machine.arretee, "{nom}");
        assert_eq!(
            machine.herites.maitre.masque, 0x55,
            "{nom} : rien n'a été écrit"
        );
        assert_eq!(machine.cpu.control[3], 0x2000, "{nom}");
        assert_eq!(machine.retirees, 0, "{nom}");
    }
}

/// `int n` : un appel, pas une faute — l'adresse empilée est celle de
/// l'instruction suivante. Et un programme n'entre que par une porte qui
/// l'admet.
#[test]
fn a_software_interrupt_is_a_call_and_respects_the_gates_privilege() {
    // int $0x80, par une porte ouverte à l'anneau trois.
    let mut machine = nouvelle(&[0xCD, 0x80]);
    machine.systeme.idt.limite = 0xFFF;
    porte(&mut machine, 0x80, GESTIONNAIRE, 0xEE);
    machine.cpu.segments[1] = 0x33;
    machine.cpu.segments[2] = 0x2B;
    charger_la_tache(&mut machine, SOMMET);
    machine.cpu.regs[4] = 0xA800;
    machine.tourner(1).expect("livrée");
    assert_eq!(machine.cpu.rip, GESTIONNAIRE);
    assert_eq!(
        machine.cpu.regs[4],
        SOMMET - 40,
        "sur la pile du noyau, sans code d'erreur"
    );
    assert_eq!(
        lire(&machine, SOMMET - 40),
        0x1002,
        "l'instruction **suivante**"
    );
    assert_eq!(lire(&machine, SOMMET - 32), 0x33);
    assert_eq!(lire(&machine, SOMMET - 16), 0xA800, "la pile du programme");
    assert_eq!(lire(&machine, SOMMET - 8), 0x2B);
    assert_eq!(machine.cpu.segments[2], 0, "SS devient nul avec la pile");
    assert_eq!(machine.retirees, 1, "un appel est retiré");

    // int $14 par un programme : la porte de la faute de page ne l'admet pas.
    let mut refusee = nouvelle(&[0xCD, 0x0E]);
    porte(&mut refusee, 14, GESTIONNAIRE, 0x8E);
    porte(&mut refusee, 13, GESTIONNAIRE + 0x10, 0x8E);
    refusee.cpu.segments[1] = 0x33;
    charger_la_tache(&mut refusee, SOMMET);
    refusee.tourner(1).expect("livrée");
    assert_eq!(
        refusee.cpu.rip,
        GESTIONNAIRE + 0x10,
        "#GP, pas la porte demandée"
    );
    assert_eq!(
        lire(&refusee, refusee.cpu.regs[4]),
        14 * 8 + 2,
        "le code nomme le vecteur dans l'IDT"
    );
    assert_eq!(
        lire(&refusee, refusee.cpu.regs[4] + 8),
        0x1000,
        "sur le `int` lui-même"
    );

    // Le noyau, lui, y entre.
    let mut noyau = nouvelle(&[0xCC]);
    porte(&mut noyau, 3, GESTIONNAIRE, 0x8E);
    noyau.tourner(1).expect("livrée");
    assert_eq!(noyau.cpu.rip, GESTIONNAIRE);
    assert_eq!(lire(&noyau, noyau.cpu.regs[4]), 0x1001);
}

/// Un programme ne revient pas « en anneau zéro » par un cadre fabriqué.
#[test]
fn iretq_never_raises_privilege() {
    let mut machine = nouvelle(&[0x48, 0xCF]);
    porte(&mut machine, 13, GESTIONNAIRE, 0x8E);
    machine.cpu.segments[1] = 0x33;
    charger_la_tache(&mut machine, SOMMET);
    let pile = 0xA800;
    for (rang, valeur) in [0x1234, 0x08, 2, 0xA900, 0x10].into_iter().enumerate() {
        ecrire(&mut machine, pile + 8 * rang as u64, valeur);
    }
    machine.cpu.regs[4] = pile;
    machine.tourner(1).expect("livrée");
    assert_eq!(machine.cpu.rip, GESTIONNAIRE, "#GP");
    assert_eq!(
        lire(&machine, machine.cpu.regs[4]),
        0x08,
        "le sélecteur refusé"
    );
    assert_eq!(
        lire(&machine, machine.cpu.regs[4] + 16),
        0x33,
        "parti de l'anneau trois"
    );
}

/// `popf` en anneau trois ne touche ni IOPL ni le drapeau d'interruption.
#[test]
fn popf_in_ring_three_cannot_grant_itself_interrupts_or_ports() {
    // popfq
    let mut programme = nouvelle(&[0x9D]);
    programme.cpu.segments[1] = 0x33;
    programme.cpu.regs[4] = 0xA800;
    ecrire(&mut programme, 0xA800, 0x3000 | IF | CF);
    programme.tourner(1).expect("sans faute");
    assert_eq!(
        programme.cpu.flags.read(),
        CF | 2,
        "la retenue passe, le reste non"
    );
    assert_eq!(programme.cpu.regs[4], 0xA808);
    // Le noyau, lui, pose ce qu'il veut.
    let mut noyau = nouvelle(&[0x9D, 0x9C]);
    noyau.cpu.regs[4] = 0xA800;
    ecrire(&mut noyau, 0xA800, 0x3000 | IF | CF);
    noyau.tourner(1).expect("sans faute");
    assert_eq!(noyau.cpu.flags.read(), 0x3000 | IF | CF | 2);
    // Et `pushfq` les rend.
    noyau.tourner(1).expect("sans faute");
    assert_eq!(lire(&noyau, 0xA800), 0x3000 | IF | CF | 2);
}

/// `sti` retarde les interruptions d'une instruction : `sti ; hlt` ne laisse
/// pas passer le réveil entre les deux.
#[test]
fn sti_holds_interrupts_for_one_instruction() {
    // sti ; hlt — avec une ligne déjà en demande.
    let mut machine = nouvelle(&[0xFB, 0xF4]);
    machine.systeme.idt.limite = 0xFFF;
    porte(&mut machine, 0x31, GESTIONNAIRE, 0x8E);
    machine.herites.maitre.masque = 0xFD;
    machine.herites.maitre.base_des_vecteurs = 0x30;
    machine.herites.serie.autorisation = 1; // de quoi regarder le matériel
    struct Ligne;
    impl wisq_vm::pc::Peripheriques for Ligne {
        fn port_lire(&mut self, _: u16, _: u8, _: &mut [u8]) -> Option<u32> {
            None
        }
        fn port_ecrire(&mut self, _: u16, _: u8, _: u32, _: &mut [u8]) -> bool {
            false
        }
        fn lignes(&self) -> u16 {
            1 << 1
        }
    }
    machine.peripheriques = Some(Box::new(Ligne));
    machine.tourner(1).expect("sti");
    assert!(machine.cpu.flags.interrupts_enabled());
    // Le matériel est regardé ici, entre `sti` et `hlt` : rien ne doit entrer.
    machine.servir().expect("sans faute");
    assert_eq!(machine.cpu.rip, 0x1001, "l'ombre de sti couvre le hlt");
    machine.tourner(2).expect("hlt, puis le réveil");
    assert_eq!(
        machine.cpu.rip,
        GESTIONNAIRE + 1,
        "réveillée, entrée, arrêtée sur son hlt"
    );
    assert_eq!(
        lire(&machine, SOMMET - 40),
        0x1002,
        "l'adresse d'après le hlt"
    );
    assert_eq!(machine.herites.maitre.service, 1 << 1);
}

/// `syscall` et `sysretq`, par les MSR que `syscall_init` pose.
#[test]
fn syscall_enters_through_the_msrs_and_sysret_comes_back() {
    // Le programme : syscall. Le noyau, à 0x8000 : sysretq.
    let mut machine = nouvelle(&[0x0F, 0x05]);
    poser(&mut machine, GESTIONNAIRE, &[0x48, 0x0F, 0x07]);
    machine.cpu.segments[1] = 0x33;
    machine.cpu.segments[2] = 0x2B;
    machine.cpu.flags.write(IF | CF);
    machine.cpu.regs[4] = 0xA800;
    // Sans EFER.SCE, `syscall` n'existe pas : #UD.
    let mut sans = machine_sans_sce();
    sans.tourner(1).expect("livrée");
    assert_eq!(sans.cpu.rip, GESTIONNAIRE + 0x20);

    machine.cpu.efer |= 1;
    machine.systeme.star = (0x10 << 32) | (0x23 << 48);
    machine.systeme.lstar = GESTIONNAIRE;
    machine.systeme.masque_d_appel = IF;
    machine.tourner(1).expect("syscall");
    assert_eq!(machine.cpu.rip, GESTIONNAIRE);
    assert_eq!(machine.cpu.regs[1], 0x1002, "RCX : l'adresse de retour");
    assert_eq!(machine.cpu.regs[11], IF | CF | 2, "R11 : les drapeaux");
    assert_eq!(machine.cpu.flags.read(), CF | 2, "le masque éteint IF");
    assert_eq!(machine.cpu.segments[1], 0x10);
    assert_eq!(machine.cpu.segments[2], 0x18);
    assert_eq!(machine.cpu.regs[4], 0xA800, "syscall ne change pas de pile");
    machine.tourner(1).expect("sysretq");
    assert_eq!(machine.cpu.rip, 0x1002);
    assert_eq!(
        machine.cpu.segments[1], 0x33,
        "STAR[63:48] + 16, anneau trois"
    );
    assert_eq!(
        machine.cpu.segments[2], 0x2B,
        "STAR[63:48] + 8, anneau trois"
    );
    assert_eq!(machine.cpu.flags.read(), IF | CF | 2);
}

fn machine_sans_sce() -> Machine {
    let mut machine = nouvelle(&[0x0F, 0x05]);
    porte(&mut machine, 6, GESTIONNAIRE + 0x20, 0x8E);
    machine
}

/// Les registres spécifiques au modèle : ceux que le cœur tient, et les
/// autres, qui gardent ce qu'on y met.
#[test]
fn model_specific_registers_read_back_and_drive_what_they_name() {
    // wrmsr ; rdmsr
    let mut machine = nouvelle(&[0x0F, 0x30, 0x0F, 0x32]);
    for (numero, valeur) in [
        (MSR_FS_BASE, 0x7fff_1234_5000u64),
        (MSR_GS_BASE, 0xffff_8880_0000_1000),
        (MSR_KERNEL_GS_BASE, 0x1122_3344_5566_7788),
        (MSR_STAR, 0x0023_0010_0000_0000),
        (MSR_LSTAR, 0xffff_ffff_8100_0000),
        (MSR_SFMASK, 0x4_7700),
        (0x0000_0277, 0x0007_0406_0007_0406),
        (0xC001_0015, 0x100_0000),
    ] {
        machine.cpu.rip = 0x1000;
        machine.cpu.regs[1] = u64::from(numero);
        machine.cpu.regs[0] = valeur & 0xFFFF_FFFF;
        machine.cpu.regs[2] = valeur >> 32;
        machine.tourner(1).expect("wrmsr");
        machine.cpu.regs[0] = 0;
        machine.cpu.regs[2] = 0;
        machine.tourner(1).expect("rdmsr");
        assert_eq!(
            (machine.cpu.regs[2] << 32) | machine.cpu.regs[0],
            valeur,
            "MSR {numero:#x}"
        );
    }
    assert_eq!(machine.cpu.fs_base, 0x7fff_1234_5000);
    assert_eq!(machine.cpu.gs_base, 0xffff_8880_0000_1000);
    assert_eq!(machine.systeme.gs_du_noyau, 0x1122_3344_5566_7788);
    // Un registre jamais écrit rend zéro.
    machine.cpu.rip = 0x1002;
    machine.cpu.regs[1] = 0x1B;
    machine.cpu.regs[0] = 0xFFFF;
    machine.tourner(1).expect("rdmsr");
    assert_eq!(machine.cpu.regs[0], 0);
    // EFER garde LMA tant que la pagination et LME tiennent, quoi qu'on écrive.
    machine.cpu.rip = 0x1000;
    machine.cpu.regs[1] = u64::from(MSR_EFER);
    machine.cpu.regs[0] = (1 << 8) | 1 | (1 << 11);
    machine.cpu.regs[2] = 0;
    machine.tourner(1).expect("wrmsr");
    assert_eq!(machine.cpu.efer, (1 << 8) | (1 << 10) | 1 | (1 << 11));
}

/// `swapgs` échange les deux bases, et `mov` vers FS ou GS avec le sélecteur
/// nul remet la base à zéro.
#[test]
fn swapgs_and_the_null_selector_move_the_bases() {
    // swapgs ; mov %eax,%fs (8e e0) ; mov %fs,%ebx (8c e3)
    let mut machine = nouvelle(&[0x0F, 0x01, 0xF8, 0x8E, 0xE0, 0x8C, 0xE3]);
    machine.cpu.gs_base = 0x1111;
    machine.systeme.gs_du_noyau = 0x2222;
    machine.cpu.fs_base = 0x3333;
    machine.tourner(1).expect("swapgs");
    assert_eq!(
        (machine.cpu.gs_base, machine.systeme.gs_du_noyau),
        (0x2222, 0x1111)
    );
    machine.cpu.regs[0] = 0;
    machine.cpu.regs[3] = u64::MAX;
    machine.tourner(2).expect("les deux mov");
    assert_eq!(machine.cpu.fs_base, 0, "le sélecteur nul n'a pas de base");
    assert_eq!(machine.cpu.segments[4], 0);
    assert_eq!(
        machine.cpu.regs[3], 0,
        "sans préfixe, le registre entier est écrit"
    );
}

/// `ltr` lit le descripteur de seize octets ; hors de la GDT, c'est une `#GP`
/// qui nomme le sélecteur.
#[test]
fn ltr_reads_the_task_segment_from_the_gdt() {
    // ltr %ax
    let mut machine = nouvelle(&[0x0F, 0x00, 0xD8]);
    porte(&mut machine, 13, GESTIONNAIRE, 0x8E);
    let (gdt, tss) = (0x6000u64, 0xffff_8880_0012_3000u64);
    let bas = 0x67 | ((tss & 0xFF_FFFF) << 16) | (0x89 << 40) | (((tss >> 24) & 0xFF) << 56);
    ecrire(&mut machine, gdt + 0x40, bas);
    ecrire(&mut machine, gdt + 0x48, tss >> 32);
    machine.systeme.gdt = Table {
        base: gdt,
        limite: 0x4F,
    };
    machine.cpu.regs[0] = 0x40;
    machine.tourner(1).expect("ltr");
    assert_eq!(machine.systeme.tache, 0x40);
    assert_eq!(
        machine.systeme.base_de_tache, tss,
        "la base, de ses quatre morceaux"
    );
    assert_eq!(machine.systeme.limite_de_tache, 0x67);
    // Un sélecteur hors de la table.
    machine.cpu.rip = 0x1000;
    machine.cpu.regs[0] = 0x48;
    machine.tourner(1).expect("livrée");
    assert_eq!(machine.cpu.rip, GESTIONNAIRE);
    assert_eq!(lire(&machine, machine.cpu.regs[4]), 0x48);
    assert_eq!(machine.systeme.tache, 0x40, "et rien n'a changé");
}

/// Une interruption prise par un programme change de pile ; sans TSS chargé,
/// le processeur ne sait pas laquelle prendre, et la machine le dit.
#[test]
fn leaving_ring_three_needs_a_task_segment() {
    let mut machine = preparee(&[0x8A, 0x03]);
    machine.cpu.regs[3] = ABSENTE;
    machine.cpu.segments[1] = 0x33;
    let pourquoi = machine.tourner(1).expect_err("pas de TSS");
    assert!(pourquoi.contains("SansTss"), "{pourquoi}");
    // Une porte qui nomme une pile d'interruption la prend toujours, même
    // sans changer d'anneau.
    let mut avec = machine_avec_pile_d_interruption();
    avec.tourner(1).expect("livrée");
    assert_eq!(
        avec.cpu.regs[4],
        0xA800 - 48,
        "IST1, et non la pile courante"
    );
    assert_eq!(lire(&avec, avec.cpu.regs[4] + 32), SOMMET);
}

fn machine_avec_pile_d_interruption() -> Machine {
    let mut machine = nouvelle(&[0x88, 0x03]);
    machine.cpu.regs[3] = ABSENTE;
    charger_la_tache(&mut machine, SOMMET);
    ecrire(&mut machine, 0x6100 + 0x24, 0xA800);
    // La porte 14 avec IST = 1.
    let bas = (GESTIONNAIRE & 0xFFFF) | (0x10 << 16) | (0x8E << 40) | (1 << 32);
    ecrire(&mut machine, IDT + 14 * 16, bas);
    ecrire(&mut machine, IDT + 14 * 16 + 8, 0);
    machine
}

/// Ce que `CPUID` annonce : un x86-64 de base, sous le nom du cœur Swift.
#[test]
fn cpuid_promises_a_baseline_x86_64_and_nothing_this_core_cannot_run() {
    let [max, ebx, ecx, edx] = cpuid(0, 0);
    assert_eq!(max, 7);
    let mut nom = Vec::new();
    for mot in [ebx, edx, ecx] {
        nom.extend(mot.to_le_bytes());
    }
    assert_eq!(nom, b"AuthenticAMD");
    let [signature, _, ecx, edx] = cpuid(1, 0);
    assert_eq!(signature, 0x0006_0FB1, "la signature du cœur Swift");
    for (bit, nom) in [
        (0, "FPU"),
        (4, "TSC"),
        (5, "MSR"),
        (6, "PAE"),
        (8, "CX8"),
        (13, "PGE"),
        (15, "CMOV"),
        (23, "MMX"),
        (24, "FXSR"),
        (25, "SSE"),
        (26, "SSE2"),
    ] {
        assert_ne!(edx & (1 << bit), 0, "{nom} fait partie de x86-64");
    }
    assert_eq!(edx & (1 << 9), 0, "pas d'APIC : deux 8259");
    assert_eq!(
        ecx,
        (1 << 13) | (1 << 30),
        "cmpxchg16b et rdrand, et rien d'autre : ni SSE3, ni SSSE3, ni SSE4, ni XSAVE, ni AVX"
    );
    let [_, ebx, ecx, edx] = cpuid(7, 0);
    assert_eq!(
        ebx,
        (1 << 9) | (1 << 18),
        "ERMS et RDSEED : ni BMI, ni AVX2, ni SHA"
    );
    assert_eq!((ecx, edx), (0, 1 << 4), "FSRM");
    assert_eq!(cpuid(0x8000_0000, 0)[0], 0x8000_0004);
    assert_eq!(cpuid(0x8000_0001, 0), [0, 0, 0, 1 << 29], "le mode long");
    let marque: Vec<u8> = (0x8000_0002..=0x8000_0004)
        .flat_map(|feuille| cpuid(feuille, 0))
        .flat_map(u32::to_le_bytes)
        .collect();
    assert!(marque.starts_with(b"wisq x86-64 (coeur Rust)\0"));
    assert_eq!(cpuid(0xD, 0), [0; 4], "pas de XSAVE");
    assert_eq!(cpuid(0x4000_0000, 0), [0; 4], "pas d'hyperviseur");
}

/// `rdrand` et `rdseed` rendent la suite fixée par la graine — la même que
/// celle du cœur Swift —, la retenue posée, et à la largeur demandée.
#[test]
fn rdrand_draws_a_reproducible_sequence_and_sets_carry() {
    let mut alea = Alea::Fixe(GRAINE_REPRODUCTIBLE);
    let attendus = [alea.suivant(), alea.suivant(), alea.suivant()];
    assert_ne!(attendus[0], attendus[1]);
    // rdrand %rax (48 0f c7 f0) ; rdseed %ebx (0f c7 fb) ; cpuid ; rdtsc
    let mut machine = nouvelle(&[
        0x48, 0x0F, 0xC7, 0xF0, 0x0F, 0xC7, 0xFB, 0x0F, 0xA2, 0x0F, 0x31,
    ]);
    machine.cpu.regs[3] = u64::MAX;
    machine.cpu.flags.write(0x8D5); // tous les drapeaux arithmétiques
    machine.tourner(1).expect("rdrand");
    assert_eq!(machine.cpu.regs[0], attendus[0]);
    assert_eq!(machine.cpu.flags.read(), CF | 2, "la retenue seule");
    machine.tourner(1).expect("rdseed");
    assert_eq!(
        machine.cpu.regs[3],
        attendus[1] & 0xFFFF_FFFF,
        "trente-deux bits écrits"
    );
    // Une source de l'hôte prend la place de la suite.
    machine.alea = Alea::Hote(Box::new(|| 42));
    machine.cpu.rip = 0x1000;
    machine.tourner(1).expect("rdrand");
    assert_eq!(machine.cpu.regs[0], 42);
    // `cpuid` écrit les quatre registres, `rdtsc` rend le temps de l'invité.
    machine.cpu.rip = 0x1007;
    machine.cpu.regs[0] = 0;
    machine.tourner(1).expect("cpuid");
    assert_eq!(machine.cpu.regs[0], 7);
    assert_eq!(machine.cpu.regs[3], u64::from(u32::from_le_bytes(*b"Auth")));
    machine.attente = 5 << 32;
    machine.tourner(1).expect("rdtsc");
    assert_eq!(
        machine.cpu.regs[0],
        machine.retirees - 1,
        "les instructions retirées…"
    );
    assert_eq!(machine.cpu.regs[2], 5, "…et l'attente");
}

// ---- La lecture des instructions ----

/// **Du code réécrit sur place exécute ses nouveaux octets.** Le cache de
/// décodage se vérifie contre la mémoire à chaque passage : c'est ce qui rend
/// justes les alternatives du noyau, un module chargé, une page rendue puis
/// redonnée — sans rien avoir à vider.
#[test]
fn code_rewritten_in_place_runs_its_new_bytes() {
    // 0x1000 : mov $1,%al
    // 0x1002 : movb $7,-8(%rip)   — réécrit l'immédiat du premier mov
    // 0x1009 : jmp 0x1000
    let mut machine = nouvelle(&[
        0xB0, 0x01, 0xC6, 0x05, 0xF8, 0xFF, 0xFF, 0xFF, 0x07, 0xEB, 0xF5,
    ]);
    machine.tourner(3).expect("sans faute");
    assert_eq!(machine.cpu.regs[0] & 0xFF, 1, "le premier passage");
    assert_eq!(machine.cpu.rip, 0x1000);
    machine.tourner(1).expect("sans faute");
    assert_eq!(
        machine.cpu.regs[0] & 0xFF,
        7,
        "le second lit l'octet réécrit"
    );
    // Et l'hôte qui réécrit la mémoire sous la machine est vu de même.
    machine.cpu.memory.bytes[0x1001] = 0x2A;
    machine.cpu.rip = 0x1000;
    machine.tourner(1).expect("sans faute");
    assert_eq!(machine.cpu.regs[0] & 0xFF, 0x2A);
}

/// **Une instruction à cheval sur deux pages se lit dans les deux**, et ne se
/// garde pas : la seconde moitié réécrite, elle rend sa nouvelle valeur.
#[test]
fn an_instruction_across_two_pages_is_read_from_both() {
    // movabs $0x1122334455667788,%rax, posée à 0x8ffa : six octets dans la
    // page 0x8000, quatre dans la page 0x9000.
    let mut machine = nouvelle(&[]);
    poser(
        &mut machine,
        0x8FFA,
        &[0x48, 0xB8, 0x88, 0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11],
    );
    machine.cpu.rip = 0x8FFA;
    machine.tourner(1).expect("sans faute");
    assert_eq!(machine.cpu.regs[0], 0x1122_3344_5566_7788);
    assert_eq!(machine.cpu.rip, 0x9004);
    machine.cpu.memory.bytes[0x9003] = 0x99;
    machine.cpu.rip = 0x8FFA;
    machine.tourner(1).expect("sans faute");
    assert_eq!(machine.cpu.regs[0], 0x9922_3344_5566_7788);
}

/// **La page suivante n'est chargée que si l'instruction déborde** — et c'est
/// alors elle qui faute, à sa propre adresse. Une instruction complète au bout
/// d'une page ne faute pas, même si la page d'après manque.
#[test]
fn only_an_instruction_that_overflows_its_page_loads_the_next_one() {
    // Un `nop` au dernier octet de la page 0xa000 ; la page 0xb000 manque.
    let mut complete = preparee(&[]);
    poser(&mut complete, 0xAFFF, &[0x90]);
    complete.cpu.rip = 0xAFFF;
    assert_eq!(complete.tourner(1), Ok(1));
    assert_eq!(complete.retirees, 1, "le nop est retiré, sans faute");
    assert_eq!(complete.cpu.rip, 0xB000);
    assert_eq!(complete.cpu.regs[4], SOMMET, "rien n'a été livré");

    // Les deux premiers octets d'un `movabs` au même endroit : la suite est
    // dans la page absente.
    let mut coupee = preparee(&[]);
    poser(&mut coupee, 0xAFFE, &[0x48, 0xB8]);
    coupee.cpu.rip = 0xAFFE;
    coupee.tourner(1).expect("livrée");
    assert_eq!(coupee.cpu.rip, GESTIONNAIRE, "une faute de page");
    assert_eq!(
        coupee.cpu.control[2], 0xB000,
        "à l'adresse de la page manquante"
    );
    assert_eq!(
        lire(&coupee, coupee.cpu.regs[4]),
        1 << 4,
        "en lecture d'instruction"
    );
    assert_eq!(
        lire(&coupee, coupee.cpu.regs[4] + 8),
        0xAFFE,
        "et la reprise est au début de l'instruction"
    );
    assert_eq!(coupee.retirees, 0);

    // **Deux octets complets que ce cœur ne lit pas, au même endroit** : ils
    // ne débordent pas, donc la page d'après n'est pas chargée, et le refus
    // garde son nom au lieu de devenir une faute de page.
    let mut inconnue = preparee(&[]);
    poser(&mut inconnue, 0xAFFE, &INCONNUE);
    inconnue.cpu.rip = 0xAFFE;
    let pourquoi = inconnue.tourner(1).expect_err("un refus nommé");
    assert!(pourquoi.contains("0f 0e"), "{pourquoi}");
    assert_eq!(inconnue.cpu.rip, 0xAFFE);
    assert_eq!(
        inconnue.cpu.regs[4], SOMMET,
        "aucune faute de page n'a été livrée"
    );
}
