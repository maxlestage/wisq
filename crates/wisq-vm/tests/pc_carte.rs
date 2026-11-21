//! **La carte des périphériques, branchée derrière les ports de la machine**
//! (`pc::carte`) : un `out` que les puces de la machine ne prennent pas va à
//! la carte, une notification de disque est servie avec la RAM de la machine
//! avant l'instruction suivante, la ligne du disque est levée, et
//! l'impulsion de remise à zéro de l'i8042 arrête la course.

use wisq_carte::pc::{ArriereMemoire, CartePc, Disque};
use wisq_vm::pc::Machine;
use wisq_vm::x86::Width;

/// La fenêtre de ports que le test donne au disque, et la page de sa file.
const FENETRE: u16 = 0xC000;
const PAGE: u64 = 0x40;
const DESCRIPTEURS: u64 = PAGE * 4096;
const DISPONIBLES: u64 = DESCRIPTEURS + 0x800;
const SERVIES: u64 = DESCRIPTEURS + 0x1000;
const ENTETE: u64 = DESCRIPTEURS + 0x3000;
const STATUT: u64 = ENTETE + 0x10;
const TAMPON: u64 = DESCRIPTEURS + 0x4000;

/// Une machine sans pagination, le code à 0x1000, la carte branchée avec un
/// disque de huit secteurs dont l'octet `i` vaut `i * 7`.
fn avec_carte(code: &[u8]) -> Machine {
    let mut machine = Machine::nouvelle(0);
    machine.cpu.control[0] = 1;
    machine.cpu.rip = 0x1000;
    machine.cpu.memory.bytes[0x1000..0x1000 + code.len()].copy_from_slice(code);
    let mut carte = CartePc::nouvelle();
    let image: Vec<u8> = (0..8 * 512).map(|i| (i * 7) as u8).collect();
    carte.brancher(Disque::Premier, ArriereMemoire(image));
    machine.peripheriques = Some(Box::new(carte));
    machine
}

fn ecrire(machine: &mut Machine, adresse: u64, largeur: Width, valeur: u64) {
    machine
        .cpu
        .memory
        .write(adresse, largeur, valeur)
        .expect("dans la RAM");
}

/// Un `out` de la carte, la RAM de la machine en main.
fn sortir(machine: &mut Machine, port: u16, largeur: u8, valeur: u32) -> bool {
    let carte = machine.peripheriques.as_mut().expect("la carte");
    carte.port_ecrire(port, largeur, valeur, &mut machine.cpu.memory.bytes)
}

fn entrer(machine: &mut Machine, port: u16, largeur: u8) -> Option<u32> {
    let carte = machine.peripheriques.as_mut().expect("la carte");
    carte.port_lire(port, largeur, &mut machine.cpu.memory.bytes)
}

/// **Ce que fait le noyau pour ouvrir le disque**, puis une lecture du
/// secteur 1 posée dans la file : la BAR0 placée à `FENETRE`, les ports
/// activés, la poignée de main de `virtio_pci_legacy`, la file à sa page.
fn ouvrir_et_poser_une_lecture(machine: &mut Machine) {
    let configuration = |registre: u32| 0x8000_1800 | registre;
    sortir(machine, 0xCF8, 4, configuration(0x10));
    sortir(machine, 0xCFC, 4, u32::from(FENETRE));
    sortir(machine, 0xCF8, 4, configuration(0x04));
    sortir(machine, 0xCFC, 2, 0x0005);
    for statut in [0, 1, 3] {
        assert!(sortir(machine, FENETRE + 0x12, 1, statut));
    }
    let offertes = entrer(machine, FENETRE, 4).expect("la fenêtre répond");
    sortir(machine, FENETRE + 0x04, 4, offertes);
    sortir(machine, FENETRE + 0x0E, 2, 0);
    sortir(machine, FENETRE + 0x08, 4, PAGE as u32);
    sortir(machine, FENETRE + 0x12, 1, 7);
    // L'en-tête : une lecture (genre 0) du secteur 1 ; le statut à 0xFF.
    ecrire(machine, ENTETE, Width::Dword, 0);
    ecrire(machine, ENTETE + 4, Width::Dword, 0);
    ecrire(machine, ENTETE + 8, Width::Qword, 1);
    ecrire(machine, STATUT, Width::Byte, 0xFF);
    let mut decrire = |i: u64, adresse: u64, longueur: u64, drapeaux: u64, suivant: u64| {
        let ici = DESCRIPTEURS + i * 16;
        ecrire(machine, ici, Width::Qword, adresse);
        ecrire(machine, ici + 8, Width::Dword, longueur);
        ecrire(machine, ici + 12, Width::Word, drapeaux);
        ecrire(machine, ici + 14, Width::Word, suivant);
    };
    decrire(0, ENTETE, 16, 1, 1);
    decrire(1, TAMPON, 512, 2 | 1, 2);
    decrire(2, STATUT, 1, 2, 0);
    ecrire(machine, DISPONIBLES + 4, Width::Word, 0);
    ecrire(machine, DISPONIBLES + 2, Width::Word, 1);
}

/// **Le pont PCI répond derrière les ports de la machine** : l'identifiant de
/// 00:03.0, lu par `out` à 0xCF8 et `in` à 0xCFC, est celui d'un disque
/// virtio (0x1AF4, 0x1001) — et pas les uns d'un bus qui flotte.
#[test]
fn the_pci_bridge_answers_behind_the_machine_ports() {
    // mov $0x80001800,%eax ; mov $0xcf8,%dx ; out %eax,(%dx) ;
    // mov $0xcfc,%dx ; in (%dx),%eax ; hlt.
    let code = [
        0xB8, 0x00, 0x18, 0x00, 0x80, 0x66, 0xBA, 0xF8, 0x0C, 0xEF, 0x66, 0xBA, 0xFC, 0x0C, 0xED,
        0xF4,
    ];
    let mut machine = avec_carte(&code);
    machine.tourner(10).expect("sans faute");
    assert!(machine.arretee);
    assert_eq!(machine.cpu.regs[0], 0x1001_1AF4);
    // Sans la carte, le même code lit le bus qui flotte.
    let mut seule = Machine::nouvelle(0);
    seule.cpu.control[0] = 1;
    seule.cpu.rip = 0x1000;
    seule.cpu.memory.bytes[0x1000..0x1000 + code.len()].copy_from_slice(&code);
    seule.tourner(10).expect("sans faute");
    assert_eq!(seule.cpu.regs[0], 0xFFFF_FFFF);
}

/// **Une notification est servie pendant l'`out`, avec la RAM de la
/// machine** : la lecture du secteur 1 est rangée dans le tampon, son statut
/// à zéro, la file servie avance d'un cran, et la ligne 5 du disque est
/// levée — tout cela avant l'instruction d'après, qui relit le tampon.
#[test]
fn a_disk_notification_is_served_with_the_machine_ram() {
    // mov $0xc010,%dx ; xor %eax,%eax ; out %ax,(%dx) ;
    // mov 0x44000,%ecx ; hlt — le premier mot du tampon, lu juste après.
    let code = [
        0x66, 0xBA, 0x10, 0xC0, 0x31, 0xC0, 0x66, 0xEF, 0x8B, 0x0C, 0x25, 0x00, 0x40, 0x04, 0x00,
        0xF4,
    ];
    let mut machine = avec_carte(&code);
    ouvrir_et_poser_une_lecture(&mut machine);
    machine.tourner(10).expect("sans faute");
    assert!(machine.arretee);
    let attendu: Vec<u8> = (512..1024).map(|i| (i * 7) as u8).collect();
    let tampon = TAMPON as usize;
    assert_eq!(
        &machine.cpu.memory.bytes[tampon..tampon + 512],
        &attendu[..]
    );
    assert_eq!(
        machine.cpu.memory.bytes[STATUT as usize], 0,
        "le statut : réussi"
    );
    assert_eq!(
        machine.cpu.memory.read(SERVIES + 2, Width::Word),
        Some(1),
        "la file servie a avancé"
    );
    assert_eq!(
        machine.cpu.regs[1] & 0xFFFF_FFFF,
        u64::from(u32::from_le_bytes(attendu[..4].try_into().unwrap())),
        "l'instruction d'après lit ce que le disque a rangé"
    );
    let lignes = machine.peripheriques.as_ref().expect("la carte").lignes();
    assert_ne!(lignes & (1 << 5), 0, "la ligne du disque");
}

/// **L'impulsion de remise à zéro** (`0xFE` sur le port 0x64 de l'i8042)
/// arrête la course au service suivant, en le disant.
#[test]
fn the_reset_pulse_stops_the_run() {
    // mov $0xfe,%al ; out %al,$0x64 ; jmp . (une boucle).
    let code = [0xB0, 0xFE, 0xE6, 0x64, 0xEB, 0xFE];
    let mut machine = avec_carte(&code);
    let issue = machine.tourner(10_000);
    assert!(
        issue
            .as_ref()
            .is_err_and(|pourquoi| pourquoi.contains("8042")),
        "{issue:?}"
    );
    // Sans l'impulsion, la même boucle tourne jusqu'au bout du budget.
    let mut boucle = avec_carte(&[0xEB, 0xFE]);
    assert_eq!(boucle.tourner(10_000), Ok(10_000));
}
