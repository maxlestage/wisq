//! La livraison des fautes et des interruptions en mode long, et les
//! instructions de système de la machine PC. Portés de
//! `X86InterruptTests.swift`, puis ce que ce cœur ajoute : les contrôles de
//! privilège, `syscall`, `swapgs`, les registres spécifiques au modèle.

use std::cell::RefCell;
use std::rc::Rc;

use wisq_vm::pc::machine::{Alea, GRAINE_REPRODUCTIBLE};
use wisq_vm::pc::systeme::{
    cpuid, Table, MSR_EFER, MSR_FS_BASE, MSR_GS_BASE, MSR_KERNEL_GS_BASE, MSR_LSTAR, MSR_SFMASK,
    MSR_STAR,
};
use wisq_vm::pc::{Machine, Peripheriques};
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
    let reservees: [(&str, &[u8]); 17] = [
        ("hlt", &[0xF4]),
        ("cli", &[0xFA]),
        ("sti", &[0xFB]),
        ("lgdt (%rbx)", &[0x0F, 0x01, 0x13]),
        ("lidt (%rbx)", &[0x0F, 0x01, 0x1B]),
        ("invlpg (%rbx)", &[0x0F, 0x01, 0x3B]),
        ("ltr %ax", &[0x0F, 0x00, 0xD8]),
        ("lldt %ax", &[0x0F, 0x00, 0xD0]),
        ("mov %rax,%dr7", &[0x0F, 0x23, 0xF8]),
        ("mov %dr7,%rax", &[0x0F, 0x21, 0xF8]),
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
        // De quoi voir ce qu'une instruction admise à tort aurait changé : un
        // descripteur de table lisible sous RBX, un sélecteur de TSS valide
        // dans RAX, un registre de débogage déjà rempli.
        machine.cpu.regs[0] = 0x40;
        machine.cpu.regs[3] = 0xA000;
        poser(&mut machine, 0xA000, &0x77u16.to_le_bytes());
        ecrire(&mut machine, 0xA002, 0x1234_5000);
        machine.systeme.debug[7] = 0x400;
        let tables = (machine.systeme.gdt, machine.systeme.idt);
        machine.tourner(1).expect("livrée");
        assert_eq!(
            (machine.systeme.gdt, machine.systeme.idt),
            tables,
            "{nom} : les tables de descripteurs"
        );
        assert_eq!(machine.systeme.ldt, 0, "{nom}");
        assert_eq!(machine.systeme.debug[7], 0x400, "{nom}");
        assert_eq!(machine.cpu.regs[0], 0x40, "{nom} : RAX");
        assert!(!machine.cpu.flags.interrupts_enabled(), "{nom}");
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

/// Ce que `CPUID` annonce : x86-64-v2, sous le nom du cœur Swift. La glibc
/// de RHEL 9 vérifie exactement ces bits — SSE3, SSSE3, SSE4.1, SSE4.2,
/// POPCNT, CX16 et LAHF en mode long — et s'arrête sans eux.
#[test]
fn cpuid_promises_x86_64_v2_and_nothing_this_core_cannot_run() {
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
        1 | (1 << 9) | (1 << 13) | (1 << 19) | (1 << 20) | (1 << 23) | (1 << 30),
        "SSE3, SSSE3, cmpxchg16b, SSE4.1, SSE4.2, POPCNT et rdrand — x86-64-v2 —, \
         et rien d'autre : ni XSAVE, ni AVX, ni AES"
    );
    let [_, ebx, ecx, edx] = cpuid(7, 0);
    assert_eq!(
        ebx,
        (1 << 9) | (1 << 18),
        "ERMS et RDSEED : ni BMI, ni AVX2, ni SHA"
    );
    assert_eq!((ecx, edx), (0, 1 << 4), "FSRM");
    assert_eq!(cpuid(0x8000_0000, 0)[0], 0x8000_0004);
    assert_eq!(
        cpuid(0x8000_0001, 0),
        [0, 0, 1, 1 << 29],
        "LAHF/SAHF en mode long, et le mode long"
    );
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

// ---- L'ombre de `sti` ----

/// De quoi faire demander la ligne quatre à volonté : le port série, sa
/// réception autorisée, sa porte au vecteur 0x34. Un octet tapé, et la ligne
/// demande au prochain regard sur le matériel.
fn serie_a_l_ecoute(machine: &mut Machine) {
    machine.systeme.idt.limite = 0xFFF;
    porte(machine, 0x34, GESTIONNAIRE, 0x8E);
    machine.herites.maitre.masque = 0xEF;
    machine.herites.maitre.base_des_vecteurs = 0x30;
    machine.herites.serie.autorisation = 1;
}

/// L'horloge, toutes les mille battements, au vecteur 0x20.
fn horloge(machine: &mut Machine) {
    machine.systeme.idt.limite = 0xFFF;
    porte(machine, 0x20, GESTIONNAIRE, 0x8E);
    machine.herites.maitre.masque = 0xFE;
    machine.herites.maitre.base_des_vecteurs = 0x20;
    machine.herites.minuterie.rechargement = 1000;
}

/// **L'ombre couvre une instruction, pas une adresse.** Une boucle d'attente
/// placée juste après `sti` revient sur l'adresse que l'ombre couvrait ;
/// tenue par l'adresse, l'ombre ne se levait jamais quand le matériel était
/// regardé à cet instant-là — et il l'est toutes les 256 instructions, donc
/// toujours au même point d'une boucle de une, deux ou quatre instructions.
#[test]
fn the_shadow_of_sti_lifts_even_when_a_loop_comes_back_under_it() {
    let boucles: [(&str, &[u8]); 4] = [
        ("sti ; jmp .", &[0xFB, 0xEB, 0xFE]),
        (
            "nop ; sti ; L: nop ; jmp L",
            &[0x90, 0xFB, 0x90, 0xEB, 0xFD],
        ),
        ("sti ; L: nop ; jmp L", &[0xFB, 0x90, 0xEB, 0xFD]),
        (
            "nop ; nop ; nop ; sti ; L: nop ; nop ; nop ; jmp L",
            &[0x90, 0x90, 0x90, 0xFB, 0x90, 0x90, 0x90, 0xEB, 0xFB],
        ),
    ];
    for (nom, code) in boucles {
        let mut machine = nouvelle(code);
        horloge(&mut machine);
        // Mille battements font 288 000 instructions : l'échéance tombe dans
        // la troisième tranche.
        for _ in 0..5 {
            machine.tourner(200_000).expect("sans faute");
        }
        assert_eq!(
            machine.cpu.rip,
            GESTIONNAIRE + 1,
            "{nom} : l'horloge interrompt la boucle (demande {:#x})",
            machine.herites.maitre.demande
        );
        assert_eq!(machine.herites.maitre.service, 1, "{nom}");
    }
}

/// Exactement une : l'instruction qui suit `sti` passe, la suivante non.
#[test]
fn the_shadow_of_sti_covers_exactly_one_instruction() {
    // sti ; nop ; nop
    let mut machine = nouvelle(&[0xFB, 0x90, 0x90]);
    serie_a_l_ecoute(&mut machine);
    machine.tourner(1).expect("sti");
    machine.taper(b"x");
    machine.servir().expect("sans faute");
    assert_eq!(machine.cpu.rip, 0x1001, "sous l'ombre, rien n'entre");
    machine.tourner(1).expect("le nop couvert");
    assert_eq!(machine.cpu.rip, 0x1002, "il s'exécute, sans interruption");
    machine.servir().expect("sans faute");
    assert_eq!(machine.cpu.rip, GESTIONNAIRE, "puis l'ombre est levée");
    assert_eq!(lire(&machine, machine.cpu.regs[4]), 0x1002);
}

/// `sti` ne pose l'ombre que s'il **lève** le drapeau : les interruptions déjà
/// permises, il ne retarde rien.
#[test]
fn sti_with_interrupts_already_on_delays_nothing() {
    let mut machine = nouvelle(&[0xFB, 0x90]);
    serie_a_l_ecoute(&mut machine);
    machine.cpu.flags.write(IF);
    machine.tourner(1).expect("sti");
    machine.taper(b"x");
    machine.servir().expect("sans faute");
    assert_eq!(machine.cpu.rip, GESTIONNAIRE, "entrée aussitôt");
    assert_eq!(lire(&machine, machine.cpu.regs[4]), 0x1001);
}

/// Charger SS retarde les interruptions d'une instruction, comme `sti` : c'est
/// ce qui laisse `mov %ax,%ss ; mov %bx,%sp` changer de pile d'un seul geste.
#[test]
fn loading_ss_holds_interrupts_for_one_instruction() {
    // mov %eax,%ss ; nop ; nop
    let mut machine = nouvelle(&[0x8E, 0xD0, 0x90, 0x90]);
    serie_a_l_ecoute(&mut machine);
    machine.cpu.flags.write(IF);
    machine.cpu.regs[0] = 0x18;
    machine.tourner(1).expect("mov ss");
    assert_eq!(machine.cpu.segments[2], 0x18);
    machine.taper(b"x");
    machine.servir().expect("sans faute");
    assert_eq!(machine.cpu.rip, 0x1002, "sous l'ombre");
    machine.tourner(1).expect("le nop couvert");
    machine.servir().expect("sans faute");
    assert_eq!(machine.cpu.rip, GESTIONNAIRE);
    assert_eq!(lire(&machine, machine.cpu.regs[4]), 0x1003);
}

/// L'instruction couverte faute : l'ombre ne passe pas à son gestionnaire.
#[test]
fn the_shadow_does_not_follow_a_fault_into_its_handler() {
    // sti ; ud2 — la porte six est une trappe, qui laisse les interruptions.
    let mut machine = nouvelle(&[0xFB, 0x0F, 0x0B]);
    serie_a_l_ecoute(&mut machine);
    porte(&mut machine, 6, GESTIONNAIRE + 0x10, 0x8F);
    machine.tourner(1).expect("sti");
    machine.taper(b"x");
    machine.tourner(1).expect("ud2, livrée");
    assert_eq!(machine.cpu.rip, GESTIONNAIRE + 0x10, "dans la trappe");
    assert!(machine.cpu.flags.interrupts_enabled());
    machine.servir().expect("sans faute");
    assert_eq!(
        machine.cpu.rip, GESTIONNAIRE,
        "la ligne entre : la faute a fini l'ombre"
    );
    assert_eq!(lire(&machine, machine.cpu.regs[4]), GESTIONNAIRE + 0x10);
}

// ---- `lretq` ----

/// `lretq` à anneau égal — le seul que Linux exécute, pour changer de CS au
/// démarrage : RIP puis CS, seize octets dépilés.
#[test]
fn lretq_pops_the_offset_then_the_selector() {
    let mut machine = nouvelle(&[0x48, 0xCB]);
    machine.cpu.segments[1] = 0x08;
    machine.cpu.segments[2] = 0x18;
    let pile = 0xA800;
    for (rang, valeur) in [0xA000, 0x10, 0xDEAD].into_iter().enumerate() {
        ecrire(&mut machine, pile + 8 * rang as u64, valeur);
    }
    machine.cpu.regs[4] = pile;
    assert_eq!(machine.tourner(1), Ok(1));
    assert_eq!(machine.cpu.rip, 0xA000);
    assert_eq!(machine.cpu.segments[1], 0x10);
    assert_eq!(machine.cpu.regs[4], pile + 16, "deux mots, pas un ni trois");
    assert_eq!(machine.cpu.segments[2], 0x18, "SS ne bouge pas");
    assert_eq!(machine.retirees, 1);
}

/// **Un programme ne se donne pas l'anneau zéro par `lretq`**, pas plus que
/// par `iretq` : `#GP` avec le sélecteur refusé, et rien n'a bougé.
#[test]
fn lretq_never_raises_privilege() {
    let mut machine = nouvelle(&[0x48, 0xCB]);
    poser(&mut machine, 0xA000, &[0xF4]);
    porte(&mut machine, 13, GESTIONNAIRE, 0x8E);
    machine.cpu.segments[1] = 0x33;
    charger_la_tache(&mut machine, SOMMET);
    let pile = 0xA800;
    ecrire(&mut machine, pile, 0xA000);
    ecrire(&mut machine, pile + 8, 0x10);
    machine.cpu.regs[4] = pile;
    machine.tourner(1).expect("livrée");
    assert_eq!(machine.cpu.rip, GESTIONNAIRE, "#GP, pas la cible");
    let cadre = machine.cpu.regs[4];
    assert_eq!(lire(&machine, cadre), 0x10, "le sélecteur refusé");
    assert_eq!(lire(&machine, cadre + 8), 0x1000, "sur le lretq lui-même");
    assert_eq!(lire(&machine, cadre + 16), 0x33, "parti de l'anneau trois");
    assert_eq!(lire(&machine, cadre + 32), pile, "et sa pile n'a pas bougé");
    assert_eq!(machine.retirees, 0);
}

/// Vers un anneau moins privilégié, RSP et SS suivent sur la pile ; et un
/// cadre dont un mot manque laisse tout en place.
#[test]
fn lretq_to_an_outer_ring_pops_the_stack_too() {
    let mut machine = nouvelle(&[0x48, 0xCB]);
    machine.cpu.segments[1] = 0x10;
    let pile = 0x6800;
    for (rang, valeur) in [0xA000, 0x33, 0xA900, 0x2B].into_iter().enumerate() {
        ecrire(&mut machine, pile + 8 * rang as u64, valeur);
    }
    machine.cpu.regs[4] = pile;
    machine.tourner(1).expect("sans faute");
    assert_eq!(machine.cpu.rip, 0xA000);
    assert_eq!(machine.cpu.segments[1], 0x33);
    assert_eq!(machine.cpu.regs[4], 0xA900, "la pile du programme");
    assert_eq!(machine.cpu.segments[2], 0x2B);

    // Le sélecteur est dans une page absente : la faute le dit, et la pile
    // est où elle était.
    let mut coupe = preparee(&[0x48, 0xCB]);
    ecrire(&mut coupe, 0xAFF8, 0xA000);
    coupe.cpu.regs[4] = 0xAFF8;
    coupe.tourner(1).expect("livrée");
    assert_eq!(coupe.cpu.rip, GESTIONNAIRE);
    assert_eq!(coupe.cpu.control[2], 0xB000);
    assert_eq!(lire(&coupe, coupe.cpu.regs[4] + 32), 0xAFF8);
    assert_eq!(
        coupe.cpu.segments[1], 0x10,
        "le CS de la porte, pas un mot lu"
    );
}

// ---- Qui empile un code d'erreur ----

/// **C'est la faute qui porte un code, pas le numéro du vecteur.** Un 8259
/// laissé à sa base d'origine livre ses lignes aux vecteurs huit à quinze —
/// ceux de la double faute, de `#SS`, de `#GP` — et une interruption de
/// matériel n'empile que cinq mots. Un `int $13` non plus.
#[test]
fn only_a_fault_pushes_an_error_code() {
    let mut materiel = nouvelle(&[0x90]);
    serie_a_l_ecoute(&mut materiel);
    materiel.herites.maitre.base_des_vecteurs = 0x08;
    porte(&mut materiel, 0x0C, GESTIONNAIRE, 0x8E);
    materiel.cpu.flags.write(IF);
    materiel.taper(b"x");
    materiel.servir().expect("livrée");
    assert_eq!(materiel.cpu.rip, GESTIONNAIRE);
    assert_eq!(materiel.cpu.regs[4], SOMMET - 40, "cinq mots");
    assert_eq!(lire(&materiel, SOMMET - 40), 0x1000, "RIP en haut du cadre");

    // int $13, depuis le noyau.
    let mut logicielle = nouvelle(&[0xCD, 0x0D]);
    porte(&mut logicielle, 13, GESTIONNAIRE, 0x8E);
    logicielle.tourner(1).expect("livrée");
    assert_eq!(logicielle.cpu.regs[4], SOMMET - 40, "cinq mots");
    assert_eq!(lire(&logicielle, SOMMET - 40), 0x1002);

    // La faute, elle, en empile six : `hlt` en anneau trois.
    let mut faute = nouvelle(&[0xF4]);
    porte(&mut faute, 13, GESTIONNAIRE, 0x8E);
    faute.cpu.segments[1] = 0x33;
    charger_la_tache(&mut faute, SOMMET);
    faute.tourner(1).expect("livrée");
    assert_eq!(faute.cpu.regs[4], SOMMET - 48, "six mots");
}

// ---- La livraison, hors des valeurs commodes ----

/// La cible d'une porte a soixante-quatre bits, en trois morceaux : les
/// gestionnaires d'un noyau sont à 0xffffffff8…, pas sous quatre gibioctets.
#[test]
fn a_gate_reaches_a_handler_above_four_gigabytes() {
    let cible = 0xFFFF_FFFF_8123_4560u64;
    let mut machine = nouvelle(&[0x0F, 0x0B]);
    porte(&mut machine, 6, cible, 0x8E);
    machine.tourner(1).expect("livrée");
    assert_eq!(machine.cpu.rip, cible);
}

/// Le pas-à-pas, la tâche imbriquée et la reprise s'éteignent en entrant ; le
/// cadre garde les drapeaux d'avant, que l'`iretq` rendra.
#[test]
fn entering_a_handler_clears_trap_nested_task_and_resume() {
    const TF: u64 = 1 << 8;
    const NT: u64 = 1 << 14;
    const RF: u64 = 1 << 16;
    let mut machine = nouvelle(&[0x0F, 0x0B]);
    porte(&mut machine, 6, GESTIONNAIRE, 0x8F);
    let avant = TF | NT | RF | IF | CF | 2;
    machine.cpu.flags.write(avant);
    machine.tourner(1).expect("livrée");
    assert_eq!(lire(&machine, machine.cpu.regs[4] + 16), avant);
    assert_eq!(
        machine.cpu.flags.read(),
        IF | CF | 2,
        "une trappe : les interruptions restent, les trois autres non"
    );
}

/// **Le segment d'état de tâche doit porter ce qu'on y lit** : la fin d'IST7
/// est son octet 0x5b. Un octet de moins, et le processeur ne sait pas quelle
/// pile prendre.
#[test]
fn a_task_segment_too_short_cannot_give_a_stack() {
    for (limite, suffit) in [(0x5Au64, false), (0x5B, true)] {
        let mut machine = preparee(&[0x8A, 0x03]);
        machine.cpu.regs[3] = ABSENTE;
        machine.cpu.segments[1] = 0x33;
        charger_la_tache(&mut machine, SOMMET);
        ecrire(
            &mut machine,
            0x6040,
            limite | ((0x6100 & 0xFF_FFFF) << 16) | (0x89 << 40),
        );
        machine
            .systeme
            .charger_la_tache(&mut machine.cpu, 0x40)
            .expect("un TSS dans la GDT");
        assert_eq!(machine.systeme.limite_de_tache, limite);
        let rendu = machine.tourner(1);
        if suffit {
            assert_eq!(rendu, Ok(1), "limite {limite:#x}");
            assert_eq!(machine.cpu.rip, GESTIONNAIRE);
        } else {
            let pourquoi = rendu.expect_err("trop court");
            assert!(pourquoi.contains("SansTss"), "{pourquoi}");
        }
    }
}

/// **Une livraison qui échoue ne laisse rien derrière elle.** La pile du
/// noyau que le TSS désigne n'est pas cartographiée : le processeur avait déjà
/// changé de pile, de SS et de CS pour y écrire, et tout est défait.
#[test]
fn a_delivery_that_fails_undoes_the_stack_and_the_selectors() {
    let mut machine = preparee(&[0x8A, 0x03]);
    machine.cpu.regs[3] = ABSENTE;
    machine.cpu.segments[1] = 0x33;
    machine.cpu.segments[2] = 0x2B;
    machine.cpu.regs[4] = 0xA800;
    charger_la_tache(&mut machine, 0xB800);
    let pourquoi = machine.tourner(1).expect_err("la pile du noyau manque");
    assert!(pourquoi.contains("Memoire"), "{pourquoi}");
    assert_eq!(machine.cpu.regs[4], 0xA800, "RSP");
    assert_eq!(machine.cpu.segments[1], 0x33, "CS");
    assert_eq!(machine.cpu.segments[2], 0x2B, "SS");
    assert_eq!(machine.cpu.rip, 0x1000, "RIP");
}

/// `ltr`, hors du cas commode : la granularité compte la limite en pages, le
/// sélecteur nul est refusé, et un descripteur dans une page absente est une
/// faute de page à **son** adresse.
#[test]
fn ltr_scales_the_limit_refuses_the_null_selector_and_faults_where_it_reads() {
    let mut machine = nouvelle(&[0x0F, 0x00, 0xD8]);
    porte(&mut machine, 13, GESTIONNAIRE, 0x8E);
    porte(&mut machine, 14, GESTIONNAIRE + 0x10, 0x8E);
    let gdt = 0x6000u64;
    // Limite 1, granularité en pages : deux pages, 0x1fff.
    ecrire(
        &mut machine,
        gdt + 0x40,
        0x1 | (0x6100 << 16) | (0x89 << 40) | (1 << 55),
    );
    ecrire(&mut machine, gdt + 0x48, 0);
    machine.systeme.gdt = Table {
        base: gdt,
        limite: 0x4F,
    };
    machine.cpu.regs[0] = 0x40;
    machine.tourner(1).expect("ltr");
    assert_eq!(machine.systeme.limite_de_tache, 0x1FFF);
    assert_eq!(machine.systeme.base_de_tache, 0x6100);

    // Le sélecteur nul, avec ou sans bits de privilège.
    for nul in [0u64, 3] {
        machine.cpu.rip = 0x1000;
        machine.cpu.regs[4] = SOMMET;
        machine.cpu.regs[0] = nul;
        machine.tourner(1).expect("livrée");
        assert_eq!(machine.cpu.rip, GESTIONNAIRE, "sélecteur {nul}");
        assert_eq!(lire(&machine, machine.cpu.regs[4]), 0);
        assert_eq!(machine.systeme.tache, 0x40, "et rien n'a changé");
    }

    // Une GDT dont la page manque.
    machine.cpu.rip = 0x1000;
    machine.cpu.regs[4] = SOMMET;
    machine.cpu.regs[0] = 0x40;
    machine.systeme.gdt.base = 0xB000;
    machine.tourner(1).expect("livrée");
    assert_eq!(machine.cpu.rip, GESTIONNAIRE + 0x10, "une faute de page");
    assert_eq!(machine.cpu.control[2], 0xB040, "à l'adresse du descripteur");
    assert_eq!(
        lire(&machine, machine.cpu.regs[4]),
        0,
        "absente, en lecture"
    );
}

/// `sysretq`, hors des valeurs de Linux : réservé au noyau, absent sans
/// EFER.SCE, et il rend toujours l'anneau trois — quels que soient les deux
/// bits bas de STAR — sans les drapeaux de reprise et de tâche imbriquée.
#[test]
fn sysret_is_for_the_kernel_and_always_lands_in_ring_three() {
    const NT: u64 = 1 << 14;
    const RF: u64 = 1 << 16;
    let prete = || {
        let mut machine = nouvelle(&[0x48, 0x0F, 0x07]);
        porte(&mut machine, 6, GESTIONNAIRE + 0x20, 0x8E);
        porte(&mut machine, 13, GESTIONNAIRE, 0x8E);
        machine.cpu.efer |= 1;
        machine.systeme.star = 0x20 << 48;
        machine.cpu.regs[1] = 0xA000;
        machine.cpu.regs[11] = RF | NT | IF | CF;
        machine
    };
    let mut noyau = prete();
    noyau.tourner(1).expect("sysretq");
    assert_eq!(noyau.cpu.rip, 0xA000);
    assert_eq!(noyau.cpu.segments[1], 0x33, "0x20 + 16, et l'anneau trois");
    assert_eq!(noyau.cpu.segments[2], 0x2B, "0x20 + 8, et l'anneau trois");
    assert_eq!(noyau.cpu.flags.read(), IF | CF | 2, "ni RF ni NT");

    let mut programme = prete();
    programme.cpu.segments[1] = 0x33;
    charger_la_tache(&mut programme, SOMMET);
    programme.tourner(1).expect("livrée");
    assert_eq!(programme.cpu.rip, GESTIONNAIRE, "#GP");
    assert_eq!(lire(&programme, programme.cpu.regs[4]), 0);
    assert_eq!(lire(&programme, programme.cpu.regs[4] + 8), 0x1000);

    let mut sans = prete();
    sans.cpu.efer &= !1;
    sans.tourner(1).expect("livrée");
    assert_eq!(sans.cpu.rip, GESTIONNAIRE + 0x20, "#UD");
}

// ---- Les instructions de système, hors de ce que le démarrage exerce ----

/// Trois instructions que `CPUID` n'annonce pas, et que le noyau porte quand
/// même dans son code : le silicium qui ne les a pas lève `#UD`, et c'est ce
/// que le noyau attend d'elles — pas un arrêt, pas un succès.
#[test]
fn what_cpuid_does_not_announce_raises_invalid_opcode() {
    let absentes: [(&str, &[u8]); 4] = [
        ("lkgs %edi", &[0xF2, 0x0F, 0x00, 0xF7]),
        ("vmcall", &[0x0F, 0x01, 0xC1]),
        ("vmmcall", &[0x0F, 0x01, 0xD9]),
        ("invpcid (%rdi),%rcx", &[0x66, 0x0F, 0x38, 0x82, 0x0F]),
    ];
    for (nom, code) in absentes {
        let mut machine = nouvelle(code);
        porte(&mut machine, 6, GESTIONNAIRE, 0x8E);
        machine.cpu.regs[7] = 0xA000;
        assert_eq!(machine.tourner(1), Ok(1), "{nom}");
        assert_eq!(machine.cpu.rip, GESTIONNAIRE, "{nom} : #UD");
        assert_eq!(machine.cpu.regs[4], SOMMET - 40, "{nom}");
        assert_eq!(lire(&machine, SOMMET - 40), 0x1000, "{nom}");
        assert_eq!(machine.retirees, 0, "{nom}");
        assert!(machine.refus.is_empty(), "{nom} : pas un trou de ce cœur");
    }
}

/// `pushf` n'empile ni VM ni RF, à la largeur demandée ; `popf` en seize bits
/// ne touche pas la moitié haute de RFLAGS.
#[test]
fn pushf_hides_two_flags_and_a_word_popf_keeps_the_high_half() {
    const RF: u64 = 1 << 16;
    const VM: u64 = 1 << 17;
    const AC: u64 = 1 << 18;
    const ID: u64 = 1 << 21;
    // pushfq ; pushfw
    let mut machine = nouvelle(&[0x9C, 0x66, 0x9C]);
    machine.cpu.regs[4] = 0xA800;
    ecrire(&mut machine, 0xA7F0, u64::MAX);
    machine.cpu.flags.write(RF | VM | AC | 0x3000 | IF | CF);
    machine.tourner(1).expect("pushfq");
    assert_eq!(machine.cpu.regs[4], 0xA7F8);
    assert_eq!(lire(&machine, 0xA7F8), AC | 0x3000 | IF | CF | 2);
    machine.tourner(1).expect("pushfw");
    assert_eq!(machine.cpu.regs[4], 0xA7F6, "deux octets");
    assert_eq!(
        lire(&machine, 0xA7F0),
        0x3203_FFFF_FFFF_FFFF,
        "seize bits écrits, et rien autour"
    );

    // popfw
    let mut machine = nouvelle(&[0x66, 0x9D]);
    machine.cpu.regs[4] = 0xA800;
    ecrire(&mut machine, 0xA800, 0xFFFF_FFFF_FFFF_0001);
    machine.cpu.flags.write(AC | ID | IF);
    machine.tourner(1).expect("popfw");
    assert_eq!(machine.cpu.regs[4], 0xA802);
    assert_eq!(
        machine.cpu.flags.read(),
        AC | ID | CF | 2,
        "la moitié basse vient de la pile, la haute reste"
    );
}

/// `sgdt` écrit dix octets ou aucun : à cheval sur une page absente, la faute
/// nomme le dernier octet, et la limite n'a pas été écrite.
#[test]
fn sgdt_writes_its_ten_bytes_or_none() {
    // sgdt (%rbx)
    let mut machine = preparee(&[0x0F, 0x01, 0x03]);
    machine.systeme.gdt = Table {
        base: 0xFFFF_8000_1234_5000,
        limite: 0x7F,
    };
    machine.cpu.regs[3] = 0xAFF8;
    ecrire(&mut machine, 0xAFF8, 0xEEEE_EEEE_EEEE_EEEE);
    machine.tourner(1).expect("livrée");
    assert_eq!(machine.cpu.rip, GESTIONNAIRE);
    assert_eq!(machine.cpu.control[2], 0xB001, "le dixième octet");
    assert_eq!(lire(&machine, machine.cpu.regs[4]), 1 << 1, "en écriture");
    assert_eq!(
        lire(&machine, 0xAFF8),
        0xEEEE_EEEE_EEEE_EEEE,
        "rien d'écrit"
    );
    // Là où ils tiennent, la limite puis la base.
    let mut machine = preparee(&[0x0F, 0x01, 0x03]);
    machine.systeme.gdt = Table {
        base: 0xFFFF_8000_1234_5000,
        limite: 0x7F,
    };
    machine.cpu.regs[3] = 0xA100;
    machine.tourner(1).expect("sans faute");
    assert_eq!(lire(&machine, 0xA100) & 0xFFFF, 0x7F);
    assert_eq!(lire(&machine, 0xA102), 0xFFFF_8000_1234_5000);
}

/// `rdtscp` rend en plus `IA32_TSC_AUX` dans ECX — le numéro du processeur,
/// que `getcpu` lit sans appel système ; `rdtsc` laisse RCX.
#[test]
fn rdtscp_also_reads_the_auxiliary_register() {
    // rdtsc ; rdtscp
    let mut machine = nouvelle(&[0x0F, 0x31, 0x0F, 0x01, 0xF9]);
    machine.systeme.tsc_aux = 0xAB_0000_0007;
    machine.cpu.regs[1] = u64::MAX;
    machine.tourner(1).expect("rdtsc");
    assert_eq!(machine.cpu.regs[1], u64::MAX, "rdtsc ne touche pas RCX");
    machine.tourner(1).expect("rdtscp");
    assert_eq!(machine.cpu.regs[1], 7, "les trente-deux bits bas");
    assert_eq!(machine.cpu.regs[0], 1, "et le compteur : une instruction");
}

/// **EFER.LMA suit la pagination** : écrire CR0 le rafraîchit. Le noyau éteint
/// la pagination pour changer de nombre de niveaux, et relit EFER.
#[test]
fn writing_cr0_refreshes_the_long_mode_active_bit() {
    // mov %rax,%cr0 ; mov %rbx,%cr0
    let mut machine = nouvelle(&[0x0F, 0x22, 0xC0, 0x0F, 0x22, 0xC3]);
    machine.cpu.regs[0] = 1;
    machine.cpu.regs[3] = (1 << 31) | 1;
    assert_ne!(machine.cpu.efer & (1 << 10), 0);
    machine.tourner(1).expect("pagination éteinte");
    assert_eq!(machine.cpu.efer, 1 << 8, "LME reste, LMA tombe");
    machine.tourner(1).expect("pagination rallumée");
    assert_eq!(machine.cpu.efer, (1 << 8) | (1 << 10));
}

/// `fninit` remet les trois mots du coprocesseur à ce que le silicium y
/// laisse : le décompresseur du noyau les relit pour savoir s'il en a un.
#[test]
fn fninit_resets_control_status_and_tags() {
    let mut machine = nouvelle(&[0xDB, 0xE3]);
    machine.cpu.fpu_control = 0x0040;
    machine.cpu.fpu_status = 0x3841;
    machine.cpu.fpu_tags = 0xFF;
    machine.tourner(1).expect("fninit");
    assert_eq!(machine.cpu.fpu_control, 0x037F);
    assert_eq!(machine.cpu.fpu_status, 0);
    assert_eq!(machine.cpu.fpu_tags, 0);
}

/// Un MXCSR aux bits réservés levés est une `#GP(0)`, par `ldmxcsr` comme par
/// `fxrstor` — c'est le signal que `sigreturn` attend d'un cadre abîmé —, et
/// non une `#UD`.
#[test]
fn a_reserved_mxcsr_is_a_general_protection_fault() {
    let formes: [(&str, &[u8], u64); 2] = [
        ("ldmxcsr (%rbx)", &[0x0F, 0xAE, 0x13], 0),
        ("fxrstor (%rbx)", &[0x0F, 0xAE, 0x0B], 24),
    ];
    for (nom, code, ou) in formes {
        let mut machine = nouvelle(code);
        porte(&mut machine, 6, GESTIONNAIRE + 0x10, 0x8E);
        porte(&mut machine, 13, GESTIONNAIRE, 0x8E);
        machine.cpu.regs[3] = 0xA000;
        ecrire(&mut machine, 0xA000 + ou, 0x0001_0000);
        machine.tourner(1).expect("livrée");
        assert_eq!(machine.cpu.rip, GESTIONNAIRE, "{nom} : #GP, pas #UD");
        assert_eq!(lire(&machine, machine.cpu.regs[4]), 0, "{nom}");
        assert_eq!(machine.cpu.mxcsr, 0x1F80, "{nom} : rien de changé");
    }
}

/// Une instruction dans le trou des périphériques n'est pas de la RAM : la
/// machine s'arrête en le disant, plutôt que d'exécuter les zéros du bloc de
/// l'hôte qui couvre le trou.
#[test]
fn an_instruction_in_the_device_hole_stops_the_machine_by_name() {
    let mut machine = nouvelle(&[0x90]);
    machine.cpu.memory_hole = (0x6000, 0x1000);
    machine.cpu.rip = 0x6010;
    let pourquoi = machine.tourner(1).expect_err("pas de la RAM");
    assert!(pourquoi.contains("trou des périphériques"), "{pourquoi}");
    assert!(pourquoi.contains("0x6010"), "{pourquoi}");
    assert_eq!(machine.retirees, 0);
    // Juste avant et juste après le trou, c'est de la RAM.
    for rip in [0x5FFFu64, 0x8000] {
        machine.cpu.memory.bytes[rip as usize] = 0x90;
        machine.cpu.rip = rip;
        assert_eq!(machine.tourner(1), Ok(1), "rip {rip:#x}");
    }
}

/// Charger FS ou GS avec un sélecteur non nul prend la base dans son
/// descripteur de la GDT ; un sélecteur de la LDT, ou hors de la table, la
/// laisse. Et un sélecteur rangé en mémoire fait seize bits, quelle que soit
/// la largeur de l'instruction.
#[test]
fn fs_and_gs_take_their_base_from_the_descriptor() {
    // mov %eax,%fs ; mov %eax,%gs ; mov %fs,(%rbx)
    let mut machine = nouvelle(&[0x8E, 0xE0, 0x8E, 0xE8, 0x8C, 0x23]);
    let gdt = 0x6000u64;
    let base = 0x1234_5678u64;
    ecrire(
        &mut machine,
        gdt + 0x18,
        0xFFFF | ((base & 0xFF_FFFF) << 16) | (0x93 << 40) | ((base >> 24) << 56),
    );
    machine.systeme.gdt = Table {
        base: gdt,
        limite: 0x1F,
    };
    machine.cpu.regs[0] = 0x18;
    machine.cpu.regs[3] = 0xA000;
    ecrire(&mut machine, 0xA000, u64::MAX);
    machine.tourner(3).expect("sans faute");
    assert_eq!(machine.cpu.fs_base, base);
    assert_eq!(machine.cpu.gs_base, base);
    assert_eq!(
        lire(&machine, 0xA000),
        0xFFFF_FFFF_FFFF_0018,
        "seize bits rangés"
    );
    // Le même index, mais dans la LDT (bit 2) ; puis hors de la GDT.
    for selecteur in [0x1Cu64, 0x20] {
        machine.cpu.rip = 0x1000;
        machine.cpu.fs_base = 0x7777;
        machine.cpu.regs[0] = selecteur;
        machine.tourner(1).expect("sans faute");
        assert_eq!(machine.cpu.segments[4], selecteur as u16);
        assert_eq!(machine.cpu.fs_base, 0x7777, "sélecteur {selecteur:#x}");
    }
}

// ---- Ce que la page d'instructions gardée doit oublier ----

/// **Écrire EFER vide le tampon de traduction** : NXE change ce que le bit 63
/// d'une entrée veut dire. Une page exécutée avant que le noyau n'allume NXE
/// ne s'exécute plus après.
#[test]
fn writing_efer_forgets_the_translations_it_changes_the_meaning_of() {
    // wrmsr
    let mut machine = preparee(&[0x0F, 0x30]);
    ecrire(&mut machine, 0x5000 + 0xA * 8, 0xA000 | 0x7 | (1 << 63));
    poser(&mut machine, 0xA000, &[0x90, 0x90]);
    machine.cpu.rip = 0xA000;
    assert_eq!(
        machine.tourner(1),
        Ok(1),
        "sans NXE, le bit 63 n'interdit rien"
    );
    assert_eq!(machine.cpu.rip, 0xA001);
    machine.cpu.rip = 0x1000;
    machine.cpu.regs[1] = u64::from(MSR_EFER);
    machine.cpu.regs[0] = (1 << 8) | (1 << 10) | (1 << 11);
    machine.cpu.regs[2] = 0;
    machine.tourner(1).expect("wrmsr");
    machine.cpu.rip = 0xA001;
    machine.tourner(1).expect("livrée");
    assert_eq!(machine.cpu.rip, GESTIONNAIRE, "la page ne s'exécute plus");
    assert_eq!(machine.cpu.control[2], 0xA001);
    assert_eq!(
        lire(&machine, machine.cpu.regs[4]),
        1 | (1 << 4),
        "présente, en lecture d'instruction"
    );
}

/// **La page d'instructions gardée ne survit pas à un vidage du tampon.** Le
/// noyau change l'entrée de la page où il s'exécute, recharge CR3, et
/// l'instruction suivante vient de la nouvelle page physique — pas de
/// l'ancienne, que la boucle gardait hors du tampon.
#[test]
fn the_current_code_page_is_forgotten_when_translations_are_flushed() {
    let mut machine = nouvelle(&[]);
    // 0xa000 : nop ; mov %rax,%cr3 ; mov $1,%bl
    poser(&mut machine, 0xA000, &[0x90, 0x0F, 0x22, 0xD8, 0xB3, 0x01]);
    // La même place dans une autre page physique : mov $2,%bl.
    poser(&mut machine, 0x6004, &[0xB3, 0x02]);
    machine.cpu.rip = 0xA000;
    machine.cpu.regs[0] = 0x2000;
    machine.tourner(1).expect("nop");
    ecrire(&mut machine, 0x5000 + 0xA * 8, 0x6000 | 0x7);
    machine.tourner(2).expect("mov cr3, puis ce qui le suit");
    assert_eq!(machine.cpu.rip, 0xA006);
    assert_eq!(
        machine.cpu.regs[3] & 0xFF,
        2,
        "l'instruction vient de la nouvelle page"
    );
}

/// **La page d'instructions gardée l'est pour un anneau.** Le noyau rend la
/// main à un programme par `iretq`, à une adresse de la page où il s'exécute
/// lui-même : le programme n'y a pas droit, et la lecture de son instruction
/// faute — elle ne passe pas sur la traduction que le noyau venait d'obtenir.
#[test]
fn the_current_code_page_is_kept_for_one_ring_only() {
    let mut machine = preparee(&[]);
    // La page 0xa000, sans le bit utilisateur.
    ecrire(&mut machine, 0x5000 + 0xA * 8, 0xA000 | 0x3);
    // iretq ; nop
    poser(&mut machine, 0xA000, &[0x48, 0xCF, 0x90]);
    charger_la_tache(&mut machine, SOMMET);
    let cadre = 0x6800;
    for (rang, valeur) in [0xA002, 0x33, 2, 0x6F00, 0x2B].into_iter().enumerate() {
        ecrire(&mut machine, cadre + 8 * rang as u64, valeur);
    }
    machine.cpu.regs[4] = cadre;
    machine.cpu.rip = 0xA000;
    machine.tourner(2).expect("iretq, puis la faute livrée");
    assert_eq!(machine.cpu.rip, GESTIONNAIRE, "le programme n'exécute rien");
    assert_eq!(machine.cpu.control[2], 0xA002);
    assert_eq!(
        lire(&machine, machine.cpu.regs[4]),
        1 | (1 << 2) | (1 << 4),
        "présente, depuis l'anneau trois, en lecture d'instruction"
    );
    assert_eq!(machine.retirees, 1, "seul l'iretq est retiré");
}

// ---- Les adresses qui ne sont pas canoniques ----

/// **Une adresse dont les bits 63 à 47 ne sont pas tous égaux n'est pas
/// traduite comme son alias** : les tables n'en lisent que quarante-huit, et
/// 0x8000_0000_0000_6000 retombait sur la page 0x6000. Le silicium lève
/// `#GP(0)` ; une adresse canonique dont la page manque reste une faute de
/// page.
#[test]
fn a_non_canonical_address_is_a_general_protection_fault() {
    let acces: [(&str, &[u8]); 2] = [
        ("mov (%rbx),%al", &[0x8A, 0x03]),
        ("mov %al,(%rbx)", &[0x88, 0x03]),
    ];
    for (nom, code) in acces {
        for adresse in [
            0x8000_0000_0000_6000u64,
            0x0000_8000_0000_6000,
            0xFFFF_7FFF_FFFF_6000,
        ] {
            let mut machine = nouvelle(code);
            porte(&mut machine, 13, GESTIONNAIRE, 0x8E);
            porte(&mut machine, 14, GESTIONNAIRE + 0x10, 0x8E);
            ecrire(&mut machine, 0x6000, 0x1111_1111_1111_1111);
            machine.cpu.regs[0] = 0x22;
            machine.cpu.regs[3] = adresse;
            machine.tourner(1).expect("livrée");
            assert_eq!(machine.cpu.rip, GESTIONNAIRE, "{nom} à {adresse:#x} : #GP");
            assert_eq!(lire(&machine, machine.cpu.regs[4]), 0, "{nom}");
            assert_eq!(lire(&machine, machine.cpu.regs[4] + 8), 0x1000, "{nom}");
            assert_eq!(machine.cpu.regs[0], 0x22, "{nom} : rien de lu");
            assert_eq!(
                lire(&machine, 0x6000),
                0x1111_1111_1111_1111,
                "{nom} : rien d'écrit"
            );
            assert_eq!(machine.cpu.control[2], 0, "{nom} : CR2 n'est pas touché");
        }
    }
    // La moitié haute canonique se marche comme le reste : sa page manque.
    let mut haute = nouvelle(&[0x8A, 0x03]);
    porte(&mut haute, 13, GESTIONNAIRE, 0x8E);
    porte(&mut haute, 14, GESTIONNAIRE + 0x10, 0x8E);
    haute.cpu.regs[3] = 0xFFFF_8000_0000_6000;
    haute.tourner(1).expect("livrée");
    assert_eq!(haute.cpu.rip, GESTIONNAIRE + 0x10, "une faute de page");
    assert_eq!(haute.cpu.control[2], 0xFFFF_8000_0000_6000);
    // Et un saut vers une adresse qui ne l'est pas : la faute tombe sur le
    // saut lui-même (SDM, JMP : `#GP(0)` si la cible n'est pas canonique).
    let mut saut = nouvelle(&[0xFF, 0xE3]); // jmp *%rbx
    porte(&mut saut, 13, GESTIONNAIRE, 0x8E);
    saut.cpu.regs[3] = 0x8000_0000_0000_1000;
    saut.tourner(1).expect("la faute livrée");
    assert_eq!(saut.cpu.rip, GESTIONNAIRE);
    assert_eq!(lire(&saut, saut.cpu.regs[4]), 0);
    assert_eq!(lire(&saut, saut.cpu.regs[4] + 8), 0x1000, "sur le jmp");
    assert_eq!(saut.retirees, 0, "rien de retiré");
}

/// Le dernier octet de la moitié basse canonique, et l'adresse où poser du
/// code pour qu'un saut relatif en sorte.
const BORD: u64 = 0x7FFF_FFFF_FFF0;

/// **Une machine dont le code est au bord de la moitié basse** : la page
/// virtuelle 0x7FFF_FFFF_F000 (dernière entrée de chaque niveau) va à la page
/// physique 0x1000, et le code est posé à 0x1FF0, soit RIP = `BORD`. Un saut
/// relatif d'à peine 0x80 octets en sort.
fn au_bord(code: &[u8]) -> Machine {
    let mut machine = nouvelle(&[]);
    let ouverte = 0x7;
    ecrire(&mut machine, 0x2000 + 255 * 8, 0x3000 | ouverte);
    ecrire(&mut machine, 0x3000 + 511 * 8, 0x4000 | ouverte);
    ecrire(&mut machine, 0x4000 + 511 * 8, 0x5000 | ouverte);
    ecrire(&mut machine, 0x5000 + 511 * 8, 0x1000 | ouverte);
    poser(&mut machine, 0x1FF0, code);
    machine.cpu.rip = BORD;
    porte(&mut machine, 13, GESTIONNAIRE, 0x8E);
    machine
}

/// La `#GP(0)` d'un saut refusé : livrée, sur le saut lui-même, rien de
/// retiré.
fn refuse_sur(machine: &mut Machine, ici: u64, nom: &str) {
    machine.tourner(1).expect("livrée");
    assert_eq!(machine.cpu.rip, GESTIONNAIRE, "{nom} : #GP");
    let cadre = machine.cpu.regs[4];
    assert_eq!(lire(machine, cadre), 0, "{nom} : code 0");
    assert_eq!(lire(machine, cadre + 8), ici, "{nom} : sur le saut");
    assert_eq!(machine.retirees, 0, "{nom} : rien de retiré");
    assert_eq!(machine.cpu.control[2], 0, "{nom} : pas une faute de page");
}

/// **Chaque instruction qui charge RIP juge sa cible**, et une cible qui
/// n'est pas canonique fait fauter l'instruction elle-même, sans rien
/// changer : ni RSP, ni la pile sous RSP, ni RCX. Pris ou non, un saut
/// conditionnel ne faute que s'il est pris. Les sauts tournent en anneau
/// trois : la livraison prend alors la pile du TSS, et la pile du programme,
/// sous RSP, reste lisible telle que le saut l'a laissée.
#[test]
fn every_jump_to_a_non_canonical_target_faults_on_itself() {
    // Les sauts relatifs, depuis le bord : la cible est 0x8000_0000_00xx.
    let relatifs: [(&str, &[u8]); 5] = [
        ("jmp rel32", &[0xE9, 0x00, 0x01, 0x00, 0x00]),
        ("je rel32, pris", &[0x0F, 0x84, 0x00, 0x01, 0x00, 0x00]),
        ("call rel32", &[0xE8, 0x00, 0x01, 0x00, 0x00]),
        ("loop rel8, pris", &[0xE2, 0x7F]),
        ("jrcxz rel8, pris", &[0xE3, 0x7F]),
    ];
    let pile = 0x6800;
    for (nom, code) in relatifs {
        let mut machine = au_bord(code);
        machine.cpu.segments[1] = 0x33;
        charger_la_tache(&mut machine, SOMMET);
        machine.cpu.flags.write(machine.cpu.flags.read() | (1 << 6)); // ZF
        machine.cpu.regs[1] = if nom.starts_with("jrcxz") { 0 } else { 5 };
        let rcx = machine.cpu.regs[1];
        machine.cpu.regs[4] = pile;
        ecrire(&mut machine, pile - 8, 0x5A5A);
        refuse_sur(&mut machine, BORD, nom);
        assert_eq!(machine.cpu.regs[1], rcx, "{nom} : RCX intact");
        assert_eq!(lire(&machine, pile - 8), 0x5A5A, "{nom} : rien empilé");
        assert_eq!(
            lire(&machine, machine.cpu.regs[4] + 32),
            pile,
            "{nom} : RSP intact"
        );
    }
    // Non pris, les mêmes avancent : la cible ne se juge que si elle est
    // prise.
    let non_pris: [(&str, &[u8], u64); 3] = [
        (
            "je rel32, non pris",
            &[0x0F, 0x84, 0x00, 0x01, 0x00, 0x00],
            6,
        ),
        ("loop rel8, non pris", &[0xE2, 0x7F], 2),
        ("jrcxz rel8, non pris", &[0xE3, 0x7F], 2),
    ];
    for (nom, code, longueur) in non_pris {
        let mut machine = au_bord(code);
        machine.cpu.regs[1] = 1;
        machine.tourner(1).expect("sans faute");
        assert_eq!(machine.cpu.rip, BORD + longueur, "{nom}");
        assert_eq!(machine.retirees, 1, "{nom}");
    }

    // Une suite non prise qui sort de la moitié basse : le manuel ne dit pas
    // où tombe la faute ; ce cœur retire le saut, et c'est la lecture de
    // l'instruction d'après, à 0x8000_0000_0000, qui faute.
    let mut suite = au_bord(&[]);
    poser(&mut suite, 0x1FFA, &[0x0F, 0x84, 0x00, 0x01, 0x00, 0x00]); // je, non pris
    suite.cpu.rip = BORD + 0xA;
    suite.tourner(2).expect("le saut, puis la faute livrée");
    assert_eq!(suite.cpu.rip, GESTIONNAIRE);
    assert_eq!(suite.retirees, 1, "le je est retiré");
    assert_eq!(lire(&suite, suite.cpu.regs[4] + 8), 0x8000_0000_0000);

    // Les sauts indirects, depuis 0x1000.
    let indirects: [(&str, &[u8]); 5] = [
        ("jmp *%rbx", &[0xFF, 0xE3]),
        ("call *%rbx", &[0xFF, 0xD3]),
        ("call *(%rax)", &[0xFF, 0x10]),
        ("ret", &[0xC3]),
        ("ret $8", &[0xC2, 0x08, 0x00]),
    ];
    for (nom, code) in indirects {
        let mut machine = nouvelle(code);
        porte(&mut machine, 13, GESTIONNAIRE, 0x8E);
        machine.cpu.segments[1] = 0x33;
        charger_la_tache(&mut machine, SOMMET);
        let cible = 0x8000_0000_0000_1000u64;
        machine.cpu.regs[3] = cible;
        machine.cpu.regs[0] = 0x6900;
        ecrire(&mut machine, 0x6900, cible);
        machine.cpu.regs[4] = pile;
        ecrire(&mut machine, pile, cible);
        ecrire(&mut machine, pile - 8, 0x5A5A);
        refuse_sur(&mut machine, 0x1000, nom);
        assert_eq!(lire(&machine, pile - 8), 0x5A5A, "{nom} : rien empilé");
        assert_eq!(
            lire(&machine, machine.cpu.regs[4] + 32),
            pile,
            "{nom} : RSP intact"
        );
    }

    // `iretq` et `lretq` vers une cible qui n'est pas canonique.
    for (nom, code) in [("iretq", [0x48, 0xCF]), ("lretq", [0x48, 0xCB])] {
        let mut machine = nouvelle(&code);
        porte(&mut machine, 13, GESTIONNAIRE, 0x8E);
        machine.cpu.segments[1] = 0x10;
        let pile = 0x6800;
        for (rang, valeur) in [0x8000_0000_0000_1000u64, 0x10, 2, 0x6900, 0x18]
            .into_iter()
            .enumerate()
        {
            ecrire(&mut machine, pile + 8 * rang as u64, valeur);
        }
        machine.cpu.regs[4] = pile;
        refuse_sur(&mut machine, 0x1000, nom);
        assert_eq!(lire(&machine, machine.cpu.regs[4] + 32), pile, "{nom}");
    }
}

/// Un cas de `a_non_canonical_stack_reference_is_a_stack_fault` : le nom,
/// le code, RSP, RBP, RAX, et le vecteur attendu.
type Reference = (&'static str, &'static [u8], u64, u64, u64, u64);

/// **Une référence par la pile à une adresse qui n'est pas canonique est
/// `#SS(0)`, vecteur douze** ; une autre est `#GP(0)`. Linux en fait SIGBUS
/// dans un cas, SIGSEGV dans l'autre. Implicite (`push`, `pop`, `call` relatif
/// ou indirect, `ret`, `leave`, `pushf`, `popf`, `iretq`) ou par un opérande
/// bâti sur RSP ou RBP — sauf derrière un préfixe FS ou GS, qui change de
/// segment —, y compris pour les instructions de système qui lisent ou
/// écrivent un opérande (`sgdt`, `mov` vers un segment). Et la cible d'un
/// `ret`, qui n'est pas un accès, reste `#GP(0)`.
#[test]
fn a_non_canonical_stack_reference_is_a_stack_fault() {
    const DEHORS: u64 = 0x8000_0000_0000_6000;
    // (nom, code, RSP, RBP, RAX, vecteur attendu)
    let cas: [Reference; 21] = [
        ("push %rax", &[0x50], DEHORS, 0, 0, 12),
        // La cible, 0x1015, est canonique : c'est l'empilement qui faute.
        (
            "call rel32",
            &[0xE8, 0x10, 0x00, 0x00, 0x00],
            DEHORS,
            0,
            0,
            12,
        ),
        ("sgdt (%rsp)", &[0x0F, 0x01, 0x04, 0x24], DEHORS, 0, 0, 12),
        ("mov (%rsp),%ds", &[0x8E, 0x1C, 0x24], DEHORS, 0, 0, 12),
        ("pop %rax", &[0x58], DEHORS, 0, 0, 12),
        ("pushfq", &[0x9C], DEHORS, 0, 0, 12),
        ("popfq", &[0x9D], DEHORS, 0, 0, 12),
        ("ret", &[0xC3], DEHORS, 0, 0, 12),
        ("call *%rax", &[0xFF, 0xD0], DEHORS, 0, 0x1000, 12),
        ("leave", &[0xC9], 0xA800, DEHORS, 0, 12),
        ("iretq", &[0x48, 0xCF], DEHORS, 0, 0, 12),
        (
            "mov (%rsp),%rax",
            &[0x48, 0x8B, 0x04, 0x24],
            DEHORS,
            0,
            0,
            12,
        ),
        (
            "mov 8(%rbp),%rax",
            &[0x48, 0x8B, 0x45, 0x08],
            0xA800,
            DEHORS,
            0,
            12,
        ),
        ("fxsave (%rsp)", &[0x0F, 0xAE, 0x04, 0x24], DEHORS, 0, 0, 12),
        ("fildl (%rsp)", &[0xDB, 0x04, 0x24], DEHORS, 0, 0, 12),
        (
            "movaps (%rsp),%xmm0",
            &[0x0F, 0x28, 0x04, 0x24],
            DEHORS,
            0,
            0,
            12,
        ),
        (
            "mov %fs:(%rbp),%rax",
            &[0x64, 0x48, 0x8B, 0x45, 0x00],
            0xA800,
            DEHORS,
            0,
            13,
        ),
        (
            "mov %gs:(%rbp),%rax",
            &[0x65, 0x48, 0x8B, 0x45, 0x00],
            0xA800,
            DEHORS,
            0,
            13,
        ),
        (
            "mov (%rax),%rcx",
            &[0x48, 0x8B, 0x08],
            0xA800,
            0,
            DEHORS,
            13,
        ),
        ("push (%rax)", &[0xFF, 0x30], 0xA800, 0, DEHORS, 13),
        ("ret vers dehors", &[0xC3], 0xA800, 0, 0, 13),
    ];
    for (nom, code, rsp, rbp, rax, vecteur) in cas {
        let mut machine = nouvelle(code);
        porte(&mut machine, 12, GESTIONNAIRE + 0x20, 0x8E);
        porte(&mut machine, 13, GESTIONNAIRE, 0x8E);
        machine.cpu.segments[1] = 0x33;
        charger_la_tache(&mut machine, SOMMET);
        ecrire(&mut machine, 0xA800, DEHORS);
        machine.cpu.regs[4] = rsp;
        machine.cpu.regs[5] = rbp;
        machine.cpu.regs[0] = rax;
        machine.tourner(1).expect("livrée");
        let attendu = if vecteur == 12 {
            GESTIONNAIRE + 0x20
        } else {
            GESTIONNAIRE
        };
        assert_eq!(machine.cpu.rip, attendu, "{nom} : vecteur {vecteur}");
        let cadre = machine.cpu.regs[4];
        assert_eq!(lire(&machine, cadre), 0, "{nom} : code 0");
        assert_eq!(lire(&machine, cadre + 8), 0x1000, "{nom} : sur lui-même");
        assert_eq!(lire(&machine, cadre + 32), rsp, "{nom} : RSP intact");
        assert_eq!(machine.cpu.regs[5], rbp, "{nom} : RBP intact");
        assert_eq!(machine.retirees, 0, "{nom}");
    }
}

/// Un cas de `the_stack_fault_is_told_from_the_operand_at_the_edge` : le
/// nom, le code, RSP, RBP, RAX, et le vecteur attendu.
type AuBord = (&'static str, &'static [u8], u64, u64, u64, u64);

/// **Au bord de la moitié basse, l'adresse refusée n'est pas celle de
/// l'opérande, et la faute reste la sienne.** Un accès à cheval sur le bord
/// faute sur sa moitié haute, quatre octets plus loin ; `fxsave` sort par sa
/// fin, 0x100 octets plus loin : sans référence implicite, c'est l'opérande,
/// et une base RBP ou RSP en fait `#SS(0)`. Une instruction qui a les deux
/// (`push (%rax)`) : l'opérande si l'adresse refusée tombe dans ses huit
/// octets (`#GP(0)`, base RAX), la pile sinon — même quand l'empilement faute
/// juste derrière l'opérande, à 0x100 de lui.
#[test]
fn the_stack_fault_is_told_from_the_operand_at_the_edge() {
    const BAS: u64 = 0x7FFF_FFFF_FFFC;
    let cas: [AuBord; 4] = [
        (
            "mov (%rbp),%rax",
            &[0x48, 0x8B, 0x45, 0x00],
            0xA800,
            BAS,
            0,
            12,
        ),
        (
            "fxsave (%rsp)",
            &[0x0F, 0xAE, 0x04, 0x24],
            0x7FFF_FFFF_FF00,
            0,
            0,
            12,
        ),
        (
            "push (%rax), la pile juste derrière",
            &[0xFF, 0x30],
            0x8000_0000_0008,
            0,
            0x7FFF_FFFF_FF00,
            12,
        ),
        (
            "push (%rax), à cheval sur le bord",
            &[0xFF, 0x30],
            0xA800,
            0,
            BAS,
            13,
        ),
    ];
    for (nom, code, rsp, rbp, rax, vecteur) in cas {
        let mut machine = au_bord(code);
        porte(&mut machine, 12, GESTIONNAIRE + 0x20, 0x8E);
        machine.cpu.segments[1] = 0x33;
        charger_la_tache(&mut machine, SOMMET);
        machine.cpu.regs[4] = rsp;
        machine.cpu.regs[5] = rbp;
        machine.cpu.regs[0] = rax;
        machine.tourner(1).expect("livrée");
        let attendu = if vecteur == 12 {
            GESTIONNAIRE + 0x20
        } else {
            GESTIONNAIRE
        };
        assert_eq!(machine.cpu.rip, attendu, "{nom} : vecteur {vecteur}");
        let cadre = machine.cpu.regs[4];
        assert_eq!(lire(&machine, cadre), 0, "{nom} : code 0");
        assert_eq!(lire(&machine, cadre + 8), BORD, "{nom} : sur lui-même");
        assert_eq!(lire(&machine, cadre + 32), rsp, "{nom} : RSP intact");
        assert_eq!(machine.retirees, 0, "{nom}");
        assert_eq!(machine.cpu.control[2], 0, "{nom} : pas une faute de page");
    }
}

/// **Les témoins d'une faute s'effacent en la livrant.** `faute_d_execution`
/// regarde `unmapped` avant tout le reste : un témoin resté là après une
/// faute de page faisait d'une division par zéro, plus tard, une seconde
/// faute de page.
#[test]
fn a_division_after_a_page_fault_is_still_a_division() {
    let mut machine = preparee(&[0x8A, 0x03, 0xF6, 0xF1]); // mov (%rbx),%al ; div %cl
    porte(&mut machine, 0, GESTIONNAIRE + 0x30, 0x8E);
    machine.cpu.regs[3] = ABSENTE;
    machine.tourner(1).expect("livrée");
    assert_eq!(machine.cpu.rip, GESTIONNAIRE, "la faute de page");
    assert_eq!(machine.cpu.unmapped, None, "le témoin effacé");
    assert!(!machine.cpu.faulted);
    machine.cpu.rip = 0x1002;
    machine.cpu.regs[1] = 0;
    machine.tourner(1).expect("livrée");
    assert_eq!(machine.cpu.rip, GESTIONNAIRE + 0x30, "#DE, porte zéro");
}

/// **`iretq` et `lretq` lisent leur cadre avec les droits de l'anneau
/// courant.** Un programme qui pointe RSP sur une page du noyau reçoit une
/// faute de page — présente, en lecture, depuis l'anneau trois : code 5 —, et
/// ne lit pas un cadre qu'il n'a pas le droit de lire.
#[test]
fn a_return_from_a_program_reads_its_frame_with_the_programs_rights() {
    for (nom, code) in [("iretq", [0x48, 0xCF]), ("lretq", [0x48, 0xCB])] {
        let mut machine = preparee(&code);
        machine.cpu.segments[1] = 0x33;
        charger_la_tache(&mut machine, SOMMET);
        // La page 0xA000, réservée au noyau.
        ecrire(&mut machine, 0x5000 + 0xA * 8, 0xA003);
        for (rang, valeur) in [0x1234u64, 0x33, 2, 0xA900, 0x2B].into_iter().enumerate() {
            ecrire(&mut machine, 0xA800 + 8 * rang as u64, valeur);
        }
        machine.cpu.regs[4] = 0xA800;
        machine.tourner(1).expect("livrée");
        assert_eq!(machine.cpu.rip, GESTIONNAIRE, "{nom} : #PF");
        assert_eq!(machine.cpu.control[2], 0xA800, "{nom} : CR2");
        assert_eq!(lire(&machine, machine.cpu.regs[4]), 5, "{nom} : code 5");
        assert_eq!(lire(&machine, machine.cpu.regs[4] + 8), 0x1000, "{nom}");
    }
}

/// **Le code d'erreur d'un retour refusé est le sélecteur sans son RPL** :
/// `lretq` depuis l'anneau trois vers CS = 0x11 rend `#GP(0x10)`.
#[test]
fn a_refused_far_return_names_the_selector_without_its_rpl() {
    for (nom, code) in [("lretq", [0x48, 0xCB]), ("iretq", [0x48, 0xCF])] {
        let mut machine = nouvelle(&code);
        porte(&mut machine, 13, GESTIONNAIRE, 0x8E);
        machine.cpu.segments[1] = 0x33;
        charger_la_tache(&mut machine, SOMMET);
        for (rang, valeur) in [0xA000u64, 0x11, 2, 0xA900, 0x2B].into_iter().enumerate() {
            ecrire(&mut machine, 0xA800 + 8 * rang as u64, valeur);
        }
        machine.cpu.regs[4] = 0xA800;
        machine.tourner(1).expect("livrée");
        assert_eq!(machine.cpu.rip, GESTIONNAIRE, "{nom} : #GP");
        assert_eq!(lire(&machine, machine.cpu.regs[4]), 0x10, "{nom}");
    }
}

// ---- Le contrat avec les autres périphériques ----

/// Ce qu'une carte branchée derrière la machine a vu passer.
#[derive(Default)]
struct Vu {
    lus: Vec<(u16, u8)>,
    ecrits: Vec<(u16, u8, u32)>,
    tics: u64,
    battements: u64,
}

/// Une carte de test : elle répond aux ports 0x64 et 0xcfc, lève la ligne
/// cinq quand le temps atteint `leve_a` battements, et dit par `reveil` si
/// quelque chose peut encore arriver.
struct Carte {
    vu: Rc<RefCell<Vu>>,
    reveil: bool,
    leve_a: u64,
}

impl Peripheriques for Carte {
    fn port_lire(&mut self, port: u16, largeur: u8, _: &mut [u8]) -> Option<u32> {
        self.vu.borrow_mut().lus.push((port, largeur));
        match port {
            0x64 => Some(0x1234_561C),
            0xCFC => Some(0xDEAD_BEEF),
            _ => None,
        }
    }

    fn port_ecrire(&mut self, port: u16, largeur: u8, valeur: u32, ram: &mut [u8]) -> bool {
        self.vu.borrow_mut().ecrits.push((port, largeur, valeur));
        if port == 0x64 {
            // Un périphérique écrit dans la RAM de l'invité : c'est bien elle
            // qu'on lui passe.
            ram[0xA100] = valeur as u8;
        }
        matches!(port, 0x64 | 0xCFC)
    }

    fn lignes(&self) -> u16 {
        u16::from(self.vu.borrow().tics >= self.leve_a) << 5
    }

    fn reveil(&self) -> bool {
        self.reveil
    }

    fn battre(&mut self, tics: u64) {
        let mut vu = self.vu.borrow_mut();
        vu.tics = tics;
        vu.battements += 1;
    }
}

/// **Les ports que la carte héritée ne sert pas vont aux autres
/// périphériques**, avec la largeur de l'accès, et leur réponse revient dans
/// le registre à cette largeur. Ceux que la carte héritée sert ne leur sont
/// pas proposés ; ceux où personne ne répond rendent des uns.
#[test]
fn the_other_devices_answer_the_ports_the_legacy_board_does_not() {
    // in $0x64,%al ; in (%dx),%eax ; out %al,$0x64 ; out %eax,(%dx) ;
    // in $0x21,%al ; in $0x99,%al ; out %al,$0x99
    let mut machine = nouvelle(&[
        0xE4, 0x64, 0xED, 0xE6, 0x64, 0xEF, 0xE4, 0x21, 0xE4, 0x99, 0xE6, 0x99,
    ]);
    let vu = Rc::new(RefCell::new(Vu::default()));
    machine.peripheriques = Some(Box::new(Carte {
        vu: Rc::clone(&vu),
        reveil: false,
        leve_a: u64::MAX,
    }));
    machine.herites.maitre.masque = 0x5A;
    machine.cpu.regs[0] = 0x1122_3344_5566_7788;
    machine.cpu.regs[2] = 0xCFC;
    machine.tourner(1).expect("in");
    assert_eq!(
        machine.cpu.regs[0], 0x1122_3344_5566_771C,
        "un octet de la réponse, et le reste du registre intact"
    );
    machine.tourner(1).expect("in");
    assert_eq!(machine.cpu.regs[0], 0xDEAD_BEEF, "trente-deux bits");
    machine.tourner(2).expect("les deux out");
    assert_eq!(
        vu.borrow().ecrits,
        [(0x64, 1, 0xEF), (0xCFC, 4, 0xDEAD_BEEF)]
    );
    assert_eq!(machine.cpu.memory.bytes[0xA100], 0xEF, "la RAM de l'invité");
    machine.tourner(1).expect("in");
    assert_eq!(machine.cpu.regs[0] & 0xFF, 0x5A, "le masque du 8259");
    machine.tourner(2).expect("le port muet");
    assert_eq!(machine.cpu.regs[0] & 0xFF, 0xFF);
    assert_eq!(
        vu.borrow().lus,
        [(0x64, 1), (0xCFC, 4), (0x99, 1)],
        "le port 0x21 n'a pas été proposé"
    );
    assert_eq!(machine.ports_muets.get(&0x99), Some(&2));
    assert_eq!(machine.ports_muets.len(), 1);
}

/// **`reveil` tient éveillée une machine arrêtée, et `battre` lui donne
/// l'heure** : sans horloge ni port série armés, un `hlt` attend la ligne
/// qu'un autre périphérique lèvera plus tard — un disque qui finit, un
/// clavier. Sans `reveil`, plus rien ne peut arriver, et la machine le dit.
#[test]
fn the_other_devices_keep_a_halted_machine_waiting_and_are_told_the_time() {
    let prete = |reveil: bool| {
        // sti ; hlt
        let mut machine = nouvelle(&[0xFB, 0xF4]);
        machine.systeme.idt.limite = 0xFFF;
        porte(&mut machine, 0x35, GESTIONNAIRE, 0x8E);
        machine.herites.maitre.masque = 0xDF;
        machine.herites.maitre.base_des_vecteurs = 0x30;
        machine.instructions_par_battement = 10;
        let vu = Rc::new(RefCell::new(Vu::default()));
        machine.peripheriques = Some(Box::new(Carte {
            vu: Rc::clone(&vu),
            reveil,
            leve_a: 3,
        }));
        (machine, vu)
    };
    let (mut machine, vu) = prete(true);
    machine.tourner(1000).expect("sans faute");
    assert_eq!(
        machine.cpu.rip,
        GESTIONNAIRE + 1,
        "la ligne cinq a réveillé le hlt"
    );
    assert_eq!(machine.herites.maitre.service, 1 << 5);
    assert_eq!(vu.borrow().tics, 3, "l'heure du troisième battement");
    assert_eq!(machine.retirees + machine.attente, 30 + 1);
    assert!(vu.borrow().battements > 3);

    // La même carte, qui ne promet rien : la machine s'éteint sur son hlt.
    let (mut eteinte, vu) = prete(false);
    assert_eq!(eteinte.tourner(1000), Ok(2));
    assert_eq!(eteinte.tourner(1000), Ok(0), "plus rien ne peut arriver");
    assert_eq!(eteinte.cpu.rip, 0x1002);
    assert_eq!(
        vu.borrow().battements,
        0,
        "personne n'a regardé le matériel"
    );
}
