//! **La carte des périphériques, branchée derrière les ports de la machine**
//! (`pc::carte`) : un `out` que les puces de la machine ne prennent pas va à
//! la carte, une notification de disque est servie avec la RAM de la machine
//! avant l'instruction suivante, la ligne du disque est levée, et
//! l'impulsion de remise à zéro de l'i8042 arrête la course, et une frappe de
//! l'hôte arrive au clavier PS/2 au rythme du temps de la machine, son
//! relâchement une tenue plus tard. Chaque
//! test passe par `pc::carte::brancher` (la carte partagée, celle que
//! `wisq-pc` branche) ; la remise à zéro et la frappe sont aussi jouées sur la
//! carte nue.

use wisq_carte::i8042::TENUE_TICS;
use wisq_carte::pc::{ArriereMemoire, CartePc, Disque};
use wisq_vm::pc::carte::brancher;
use wisq_vm::pc::herites::INSTRUCTIONS_PAR_BATTEMENT;
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

/// Une machine sans pagination, le code à 0x1000, et une carte avec un
/// disque de huit secteurs dont l'octet `i` vaut `i * 7`, pas encore
/// branchée.
fn machine_et_carte(code: &[u8]) -> (Machine, CartePc) {
    let mut machine = Machine::nouvelle(0);
    machine.cpu.control[0] = 1;
    machine.cpu.rip = 0x1000;
    machine.cpu.memory.bytes[0x1000..0x1000 + code.len()].copy_from_slice(code);
    let mut carte = CartePc::nouvelle();
    let image: Vec<u8> = (0..8 * 512).map(|i| (i * 7) as u8).collect();
    carte.brancher(Disque::Premier, ArriereMemoire(image));
    (machine, carte)
}

/// La carte branchée comme `wisq-pc` la branche : partagée entre les ports
/// et la mémoire (`pc::carte::brancher`).
fn avec_carte(code: &[u8]) -> Machine {
    let (mut machine, carte) = machine_et_carte(code);
    brancher(&mut machine, carte);
    machine
}

/// La carte nue derrière les ports, sans partage.
fn avec_carte_nue(code: &[u8]) -> Machine {
    let (mut machine, carte) = machine_et_carte(code);
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
/// secteur 1 posée dans la file, vers `tampon` : la BAR0 placée à `FENETRE`,
/// les ports activés, la poignée de main de `virtio_pci_legacy`, la file à sa
/// page.
fn ouvrir_et_poser_une_lecture(machine: &mut Machine, tampon: u64) {
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
    decrire(1, tampon, 512, 2 | 1, 2);
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
    ouvrir_et_poser_une_lecture(&mut machine, TAMPON);
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

/// **Un transfert qui finit au dernier octet de la RAM est servi** ; un
/// octet plus loin, il ne l'est pas : le secteur n'est pas rangé, et le
/// statut le dit.
#[test]
fn a_transfer_ending_at_the_last_byte_of_ram_is_served() {
    // mov $0xc010,%dx ; xor %eax,%eax ; out %ax,(%dx) ; hlt.
    let code = [0x66, 0xBA, 0x10, 0xC0, 0x31, 0xC0, 0x66, 0xEF, 0xF4];
    let attendu: Vec<u8> = (512..1024).map(|i| (i * 7) as u8).collect();
    for (decalage, servi) in [(512, true), (511, false)] {
        let mut machine = avec_carte(&code);
        let taille = machine.cpu.memory.bytes.len();
        let tampon = taille - decalage;
        machine.cpu.memory.bytes[tampon..].fill(0x5A);
        ouvrir_et_poser_une_lecture(&mut machine, tampon as u64);
        machine.tourner(10).expect("sans faute");
        assert!(machine.arretee);
        let statut = machine.cpu.memory.bytes[STATUT as usize];
        if servi {
            assert_eq!(&machine.cpu.memory.bytes[tampon..], &attendu[..]);
            assert_eq!(statut, 0, "le statut : réussi");
        } else {
            assert!(
                machine.cpu.memory.bytes[tampon..]
                    .iter()
                    .all(|octet| *octet == 0x5A),
                "rien de rangé au-delà de la RAM"
            );
            assert_ne!(statut, 0, "le statut : en échec");
        }
    }
}

/// **L'impulsion de remise à zéro** (`0xFE` sur le port 0x64 de l'i8042)
/// arrête la course sur l'`out` qui l'a tirée, en le disant — par la carte
/// partagée (le `reboot` d'un invité sous `wisq-pc`) comme par la carte nue.
#[test]
fn the_reset_pulse_stops_the_run() {
    // mov $0xfe,%al ; out %al,$0x64 ; jmp . (une boucle).
    let code = [0xB0, 0xFE, 0xE6, 0x64, 0xEB, 0xFE];
    for (comment, construire) in [
        ("partagée", avec_carte as fn(&[u8]) -> Machine),
        ("nue", avec_carte_nue),
    ] {
        let mut machine = construire(&code);
        let issue = machine.tourner(10_000);
        assert!(
            issue
                .as_ref()
                .is_err_and(|pourquoi| pourquoi.contains("8042")),
            "{comment} : {issue:?}"
        );
        assert_eq!(machine.cpu.rip, 0x1002, "{comment} : RIP sur l'out");
        // Sans l'impulsion, la même boucle tourne jusqu'au bout du budget.
        let mut boucle = construire(&[0xEB, 0xFE]);
        assert_eq!(boucle.tourner(10_000), Ok(10_000), "{comment}");
    }
}

/// **Une frappe de l'hôte arrive au clavier PS/2 au rythme de la machine** :
/// posée dans la file de la carte (`taper_texte`, ce que fait `--keys`), elle
/// n'entre dans le tampon de sortie de l'i8042 que lorsque la machine donne
/// son temps à la carte (`Peripheriques::battre`, au service du matériel).
/// L'invité attend le bit « sortie pleine » du port 0x64, lit le code du jeu
/// 1 de « a » enfoncée (0x1E) au port 0x60, puis attend de même son
/// relâchement (0x9E). Le premier vient au premier battement ; le second,
/// que l'i8042 tient `TENUE_TICS` tics du 8254 après le premier, ne vient
/// qu'une fois ce temps passé dans la machine — compté en instructions
/// retirées, `INSTRUCTIONS_PAR_BATTEMENT` par tic. La machine s'arrête donc
/// entre `TENUE_TICS` et `TENUE_TICS + 1` tics : un temps faux donné à la
/// carte (trop tôt, trop tard, figé) la fait sortir de cette fenêtre, ou
/// attendre jusqu'au bout du budget. Par la carte partagée comme par la carte
/// nue.
#[test]
fn a_host_keystroke_reaches_the_ps2_keyboard_in_time() {
    // 1000: in $0x64,%al ; test $1,%al ; jz 1000 ; in $0x60,%al ;
    // mov %al,%bl ; 100a: in $0x64,%al ; test $1,%al ; jz 100a ;
    // in $0x60,%al ; hlt.
    let code = [
        0xE4, 0x64, 0xA8, 0x01, 0x74, 0xFA, 0xE4, 0x60, 0x88, 0xC3, 0xE4, 0x64, 0xA8, 0x01, 0x74,
        0xFA, 0xE4, 0x60, 0xF4,
    ];
    // Assez pour la tenue et bien au-delà : un relâchement en retard se voit
    // à la fenêtre, pas au budget.
    let budget = 2 * TENUE_TICS * INSTRUCTIONS_PAR_BATTEMENT;
    let juger = |machine: &Machine, comment: &str| {
        assert!(machine.arretee, "{comment} : les deux codes sont arrivés");
        assert_eq!(
            machine.cpu.regs[3] & 0xFF,
            0x1E,
            "{comment} : « a » enfoncée"
        );
        assert_eq!(
            machine.cpu.regs[0] & 0xFF,
            0x9E,
            "{comment} : « a » relâchée"
        );
        let tics = machine.tics();
        assert!(
            (TENUE_TICS..=TENUE_TICS + 1).contains(&tics),
            "{comment} : relâchée à {tics} tics, la tenue en vaut {TENUE_TICS}"
        );
    };
    // Branchée, la carte se tient par ce qu'en rend `brancher`.
    let (mut machine, carte) = machine_et_carte(&code);
    let partagee = brancher(&mut machine, carte);
    assert_eq!(partagee.tenir().taper_texte("a"), 2, "enfoncée, relâchée");
    machine.tourner(budget).expect("sans faute");
    juger(&machine, "partagée");
    // Nue, elle se tient avant d'être donnée à la machine.
    let (mut machine, mut carte) = machine_et_carte(&code);
    assert_eq!(carte.taper_texte("a"), 2);
    machine.peripheriques = Some(Box::new(carte));
    machine.tourner(budget).expect("sans faute");
    juger(&machine, "nue");
    // Sans frappe, l'invité attend jusqu'au bout du budget.
    let mut sans = avec_carte(&code);
    assert_eq!(sans.tourner(10_000), Ok(10_000));
    assert!(!sans.arretee);
}
