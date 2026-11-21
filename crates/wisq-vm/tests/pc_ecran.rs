//! **L'écran et la tablette de la carte, derrière la mémoire de la machine**
//! (`pc::carte::brancher`, `x86_paging::Devices`) : la mémoire vidéo de la
//! carte de Bochs et ses registres DISPI répondent aux adresses physiques que
//! la RAM ne couvre pas, par toutes les largeurs d'accès — à cheval sur deux
//! pages, seize octets de SSE compris ; la sonnette de la tablette est servie
//! au tour suivant du matériel, et un toucher arrive dans les tampons de
//! l'invité avec sa ligne ; l'horloge CMOS de la carte prend les ports 0x70 et
//! 0x71. Ailleurs hors de la RAM, personne ne répond, comme avant.

use wisq_carte::ecran::{BASE_DES_REGISTRES, BASE_DE_LA_MEMOIRE_VIDEO};
use wisq_carte::pc::CartePc;
use wisq_carte::tablette::BASE_DE_LA_TABLETTE;
use wisq_vm::pc::carte::{brancher, CartePartagee};
use wisq_vm::pc::Machine;
use wisq_vm::x86::Width;

/// Une machine sans pagination, le code à 0x1000, la carte branchée avec un
/// écran de 1280 × 800 et sa tablette.
fn avec_ecran(code: &[u8]) -> (Machine, CartePartagee) {
    let mut machine = Machine::nouvelle(0);
    machine.cpu.control[0] = 1;
    machine.cpu.rip = 0x1000;
    machine.cpu.memory.bytes[0x1000..0x1000 + code.len()].copy_from_slice(code);
    let mut carte = CartePc::nouvelle();
    assert!(carte.brancher_ecran(1280, 800));
    let carte = brancher(&mut machine, carte);
    (machine, carte)
}

/// **L'invité peint l'écran par sa mémoire vidéo** : quatre octets écrits
/// puis relus au premier pixel, huit à cheval sur la fin de la première page
/// (les deux moitiés dans la carte), seize d'un `movdqu` — que la sonde
/// d'avant écriture doit admettre. Tout atterrit dans le cadre de la carte,
/// et sa révision avance.
#[test]
fn the_guest_paints_the_screen_through_its_video_memory() {
    let code = [
        0xBB, 0x00, 0x00, 0x00, 0xE0, // mov $0xe0000000,%ebx
        0xB8, 0x44, 0x33, 0x22, 0x11, // mov $0x11223344,%eax
        0x89, 0x03, // mov %eax,(%rbx)
        0x8B, 0x0B, // mov (%rbx),%ecx
        0x48, 0xB8, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, // movabs $…,%rax
        0x48, 0x89, 0x83, 0xFC, 0x0F, 0x00, 0x00, // mov %rax,0xffc(%rbx)
        0x48, 0x8B, 0x93, 0xFC, 0x0F, 0x00, 0x00, // mov 0xffc(%rbx),%rdx
        0xF3, 0x0F, 0x7F, 0x83, 0x00, 0x01, 0x00, 0x00, // movdqu %xmm0,0x100(%rbx)
        0xF3, 0x0F, 0x6F, 0x8B, 0x00, 0x01, 0x00, 0x00, // movdqu 0x100(%rbx),%xmm1
        0xF4,
    ];
    let (mut machine, carte) = avec_ecran(&code);
    machine.cpu.xmm[0] = [0x0706_0504_0302_0100, 0x0F0E_0D0C_0B0A_0908];
    let avant = carte.tenir().ecran().expect("l'écran").cadre.revision();
    machine.tourner(20).expect("sans faute");
    assert!(machine.arretee, "jusqu'au hlt");
    assert_eq!(machine.cpu.regs[1], 0x1122_3344, "relu au premier pixel");
    assert_eq!(machine.cpu.regs[2], 0x8877_6655_4433_2211, "relu à cheval");
    assert_eq!(machine.cpu.xmm[1], machine.cpu.xmm[0], "relu par movdqu");
    let carte = carte.tenir();
    let cadre = &carte.ecran().expect("l'écran").cadre;
    let octets = cadre.octets();
    assert_eq!(&octets[..4], &[0x44, 0x33, 0x22, 0x11]);
    assert_eq!(
        &octets[0xFFC..0x1004],
        &[0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88]
    );
    let seize: Vec<u8> = (0..16).collect();
    assert_eq!(&octets[0x100..0x110], &seize[..]);
    assert!(cadre.revision() > avant, "la révision a avancé");
    // Rien n'est allé dans la RAM aux adresses basses de même décalage.
    assert!(machine.cpu.memory.bytes[0x100..0x110]
        .iter()
        .all(|o| *o == 0));
}

/// **Les registres DISPI répondent par la BAR2** (`BASE_DES_REGISTRES`, à
/// 0x500) comme par les ports `0x1CE` et `0x1CF` : l'identifiant 0xB0C5 lu
/// sur seize bits ; la largeur écrite par la mémoire se relit par les ports.
#[test]
fn the_dispi_registers_answer_through_the_bar2() {
    let code = [
        0xBB, 0x00, 0x05, 0x00, 0xE1, // mov $0xe1000500,%ebx
        0x0F, 0xB7, 0x03, // movzwl (%rbx),%eax — ID
        0x66, 0xC7, 0x43, 0x02, 0x00, 0x04, // movw $0x400,2(%rbx) — XRES
        0x66, 0xBA, 0xCE, 0x01, // mov $0x1ce,%dx
        0x66, 0xB8, 0x01, 0x00, // mov $1,%ax
        0x66, 0xEF, // out %ax,(%dx)
        0x66, 0xBA, 0xCF, 0x01, // mov $0x1cf,%dx
        0x66, 0xED, // in (%dx),%ax — XRES
        0x89, 0xC1, // mov %eax,%ecx
        0xF4,
    ];
    assert_eq!(BASE_DES_REGISTRES, 0xE100_0000);
    let (mut machine, _carte) = avec_ecran(&code);
    machine.cpu.regs[0] = 0;
    machine.tourner(20).expect("sans faute");
    assert!(machine.arretee);
    assert_eq!(
        machine.cpu.regs[1] & 0xFFFF,
        0x400,
        "XRES relu par les ports"
    );
    // L'identifiant, lu avant : refaire la seule lecture.
    let (mut machine, _carte) = avec_ecran(&code[..8]);
    machine.cpu.memory.bytes[0x1008] = 0xF4;
    machine.tourner(5).expect("sans faute");
    assert_eq!(machine.cpu.regs[0], 0xB0C5);
}

/// **Ailleurs hors de la RAM, personne ne répond** : une lecture à
/// `0xD000_0000`, que ni la mémoire vidéo ni les registres ni la tablette ne
/// couvrent, arrête la machine en nommant l'adresse, carte branchée ou non.
#[test]
fn nobody_else_answers_beyond_the_ram() {
    // mov $0xd0000000,%ebx ; mov (%rbx),%eax ; hlt.
    let code = [0xBB, 0x00, 0x00, 0x00, 0xD0, 0x8B, 0x03, 0xF4];
    let (mut machine, _carte) = avec_ecran(&code);
    let issue = machine.tourner(5);
    assert!(
        issue
            .as_ref()
            .is_err_and(|pourquoi| pourquoi.contains("hors de la mémoire")),
        "{issue:?}"
    );
    // La même lecture dans la mémoire vidéo répond.
    let code = [0xBB, 0x00, 0x00, 0x00, 0xE0, 0x8B, 0x03, 0xF4]; // mov $0xe0000000,%ebx ; …
    let (mut machine, _carte) = avec_ecran(&code);
    assert_eq!(BASE_DE_LA_MEMOIRE_VIDEO, 0xE000_0000);
    machine.tourner(5).expect("sans faute");
    assert!(machine.arretee);
}

/// **Branchée, la carte ne prend pas ce qu'elle ne sert pas** : un rangement
/// à cheval sur la fin de la RAM (sa moitié haute hors de la RAM, là où la
/// carte n'a rien) faute sans poser un octet de sa moitié basse — huit octets
/// d'un `mov`, seize d'un `movdqu`, que la sonde d'avant écriture juge. C'est
/// `DeviceMemory::claims` de la carte qui le dit : un « oui » à tout
/// laisserait passer la sonde, et la moitié basse serait posée avant le refus.
#[test]
fn a_store_past_the_end_of_ram_leaves_nothing_with_the_card_branched() {
    let code = [
        0x48, 0x89, 0x03, // mov %rax,(%rbx)
        0xF4,
    ];
    let sse = [
        0xF3, 0x0F, 0x7F, 0x03, // movdqu %xmm0,(%rbx)
        0xF4,
    ];
    for (nom, code, recul) in [("mov", &code[..], 4usize), ("movdqu", &sse[..], 8)] {
        let (mut machine, _carte) = avec_ecran(code);
        let fin = machine.cpu.memory.bytes.len();
        machine.cpu.regs[3] = (fin - recul) as u64;
        machine.cpu.regs[0] = 0x1111_1111_1111_1111;
        machine.cpu.xmm[0] = [0x2222_2222_2222_2222, 0x3333_3333_3333_3333];
        machine.cpu.memory.bytes[fin - recul..].fill(0x5A);
        let issue = machine.tourner(5);
        assert!(
            issue
                .as_ref()
                .is_err_and(|pourquoi| pourquoi.contains("hors de la mémoire")),
            "{nom} : {issue:?}"
        );
        assert!(
            machine.cpu.memory.bytes[fin - recul..]
                .iter()
                .all(|octet| *octet == 0x5A),
            "{nom} : rien de posé dans la RAM"
        );
    }
}

/// **Au-delà de trois gibioctets, la mémoire vidéo est dans le trou**, et la
/// RAM de l'hôte qui couvre le trou ne la remplace pas : une écriture et une
/// lecture de huit octets à cheval sur une page de la mémoire vidéo
/// (`0xE000_0FFC`) vont à la carte, moitié par moitié, et la RAM sous le trou,
/// qui porte un motif, reste intacte.
#[test]
fn above_three_gibibytes_the_video_memory_is_the_cards_not_the_holes() {
    let code = [
        0xBB, 0xFC, 0x0F, 0x00, 0xE0, // mov $0xe0000ffc,%ebx
        0x48, 0xB8, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, // movabs $…,%rax
        0x48, 0x89, 0x03, // mov %rax,(%rbx)
        0x48, 0x8B, 0x13, // mov (%rbx),%rdx
        0xF4,
    ];
    let mut machine = Machine::nouvelle(4 << 30);
    assert_eq!(machine.cpu.memory_hole, (0xC000_0000, 1 << 30));
    machine.cpu.control[0] = 1;
    machine.cpu.rip = 0x1000;
    machine.cpu.memory.bytes[0x1000..0x1000 + code.len()].copy_from_slice(&code);
    let mut carte = CartePc::nouvelle();
    assert!(carte.brancher_ecran(1280, 800));
    let carte = brancher(&mut machine, carte);
    let ici = 0xE000_0FFCusize;
    machine.cpu.memory.bytes[ici..ici + 8].fill(0xA5);
    machine.tourner(10).expect("sans faute");
    assert!(machine.arretee, "jusqu'au hlt");
    assert_eq!(
        machine.cpu.regs[2], 0x8877_6655_4433_2211,
        "relu de la carte, pas du motif"
    );
    assert_eq!(
        &carte.tenir().ecran().expect("l'écran").cadre.octets()[0xFFC..0x1004],
        &[0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88],
        "les deux moitiés dans le cadre"
    );
    assert!(
        machine.cpu.memory.bytes[ici..ici + 8]
            .iter()
            .all(|octet| *octet == 0xA5),
        "la RAM sous le trou, intacte"
    );
}

// ------------------------------------------------------------- la tablette

const DESCRIPTEURS: u64 = 0x20_000;
const DISPONIBLES: u64 = 0x21_000;
const SERVIES: u64 = 0x22_000;
const TAMPONS: u64 = 0x23_000;

/// **Ce que fait `virtio_pci_modern` pour ouvrir la tablette**, par la BAR0
/// de la carte : la mémoire allumée dans la commande PCI (00:07.0), la
/// poignée de main, la file des événements posée dans la RAM de la machine,
/// huit tampons de huit octets offerts.
fn ouvrir_la_tablette(machine: &mut Machine, carte: &CartePartagee) {
    let base = BASE_DE_LA_TABLETTE;
    let mut carte = carte.tenir();
    let configuration = |registre: u32| 0x8000_3800 | registre;
    assert!(carte.port_ecrire(0xCF8, 4, configuration(0x10)));
    assert!(carte.port_ecrire(0xCFC, 4, base as u32));
    assert!(carte.port_ecrire(0xCF8, 4, configuration(0x04)));
    assert!(carte.port_ecrire(0xCFC, 2, 0x0006));
    let mut ecrire = |decalage: u64, largeur: u8, valeur: u64| {
        assert!(
            carte.mem_ecrire(base + decalage, largeur, valeur),
            "{decalage:#x}"
        );
    };
    ecrire(0x14, 1, 0);
    ecrire(0x14, 1, 1 | 2);
    ecrire(0x00, 4, 1);
    ecrire(0x08, 4, 1);
    ecrire(0x0C, 4, 1);
    ecrire(0x14, 1, 1 | 2 | 8);
    ecrire(0x16, 2, 0);
    ecrire(0x18, 2, 8);
    ecrire(0x20, 8, DESCRIPTEURS);
    ecrire(0x28, 8, DISPONIBLES);
    ecrire(0x30, 8, SERVIES);
    ecrire(0x1C, 2, 1);
    ecrire(0x14, 1, 1 | 2 | 8 | 4);
    let memoire = &mut machine.cpu.memory;
    for rang in 0..8u64 {
        let ici = DESCRIPTEURS + rang * 16;
        memoire
            .write(ici, Width::Qword, TAMPONS + rang * 8)
            .unwrap();
        memoire.write(ici + 8, Width::Dword, 8).unwrap();
        memoire.write(ici + 12, Width::Word, 2).unwrap(); // VRING_DESC_F_WRITE
        memoire
            .write(DISPONIBLES + 4 + rang * 2, Width::Word, rang)
            .unwrap();
    }
    memoire.write(DISPONIBLES + 2, Width::Word, 8).unwrap();
}

/// Les six événements d'un toucher au milieu, au quart de la hauteur, le
/// bouton gauche enfoncé, relus dans les tampons de l'invité ; la ligne 10
/// levée.
fn le_toucher_est_arrive(machine: &Machine) {
    let lire = |adresse: u64, largeur: Width| machine.cpu.memory.read(adresse, largeur).unwrap();
    assert_eq!(lire(SERVIES + 2, Width::Word), 6, "six événements rendus");
    let attendus = [
        (3, 0, 16_384),
        (3, 1, 8_192),
        (1, 0x110, 1),
        (1, 0x111, 0),
        (1, 0x112, 0),
        (0, 0, 0),
    ];
    for (rang, (genre, code, valeur)) in attendus.into_iter().enumerate() {
        let tete = lire(SERVIES + 4 + rang as u64 * 8, Width::Dword);
        let tampon = TAMPONS + tete * 8;
        assert_eq!(
            (
                lire(tampon, Width::Word),
                lire(tampon + 2, Width::Word),
                lire(tampon + 4, Width::Dword)
            ),
            (genre, code, valeur),
            "l'événement {rang}"
        );
    }
    let lignes = machine.peripheriques.as_ref().expect("la carte").lignes();
    assert_ne!(lignes & (1 << 10), 0, "la ligne de la tablette");
}

/// `mov $600,%ecx ; loop . ; hlt` : plus de deux cent cinquante-six
/// instructions, donc au moins un tour du matériel.
const BOUCLE: [u8; 8] = [0xB9, 0x58, 0x02, 0x00, 0x00, 0xE2, 0xFE, 0xF4];

/// **La sonnette de la tablette, sonnée par l'invité dans la BAR0, est
/// servie au tour suivant du matériel** : notée par l'écriture (la carte a
/// quelque chose à servir quand la machine s'arrête juste après), consommée
/// par la boucle qui suit, et le toucher posé entre les deux arrive.
#[test]
fn the_tablet_doorbell_is_served_at_the_next_turn() {
    let sonnette = (BASE_DE_LA_TABLETTE + 0x3000) as u32;
    let mut code = vec![0xBB];
    code.extend_from_slice(&sonnette.to_le_bytes()); // mov $sonnette,%ebx
    code.extend_from_slice(&[0x66, 0xC7, 0x03, 0x00, 0x00]); // movw $0,(%rbx)
    code.push(0xF4); // hlt
    code.extend_from_slice(&BOUCLE);
    let (mut machine, carte) = avec_ecran(&code);
    ouvrir_la_tablette(&mut machine, &carte);
    assert!(!carte.tenir().a_servir(), "rien de noté avant la sonnette");
    machine.tourner(10).expect("sans faute");
    assert!(machine.arretee, "arrêtée juste après la sonnette");
    assert!(
        carte.tenir().a_servir(),
        "la sonnette, notée par l'écriture"
    );
    assert!(carte.tenir().toucher(0.5, 0.25, 1), "la tablette est prête");
    machine.arretee = false;
    machine.tourner(2_000).expect("sans faute");
    assert!(machine.arretee, "jusqu'au second hlt");
    assert!(!carte.tenir().a_servir(), "la sonnette, servie en route");
    le_toucher_est_arrive(&machine);
}

/// **Un toucher arrive sans que l'invité sonne** : la tablette est servie à
/// chaque tour du matériel, pas seulement après une sonnette — c'est le
/// doigt qui arrive, pas le pilote qui demande. X, Y, les trois boutons et
/// `SYN_REPORT`, la file servie avancée de six, la ligne 10 levée.
#[test]
fn a_touch_reaches_the_guest_without_a_doorbell() {
    let (mut machine, carte) = avec_ecran(&BOUCLE);
    ouvrir_la_tablette(&mut machine, &carte);
    assert!(carte.tenir().toucher(0.5, 0.25, 1), "la tablette est prête");
    assert!(!carte.tenir().a_servir(), "aucune sonnette");
    machine.tourner(2_000).expect("sans faute");
    assert!(machine.arretee, "jusqu'au hlt");
    le_toucher_est_arrive(&machine);
}

/// **L'horloge CMOS de la carte répond aux ports 0x70 et 0x71** une fois
/// branchée, et non plus celle des puces de la machine : celle-ci dit 2026,
/// la carte 2033 ; `in` après `out 0x09` (l'année) lit 0x33.
#[test]
fn the_cards_cmos_clock_takes_the_ports() {
    // mov $9,%al ; out %al,$0x70 ; in $0x71,%al ; hlt.
    let code = [0xB0, 0x09, 0xE6, 0x70, 0xE4, 0x71, 0xF4];
    let (mut machine, carte) = avec_ecran(&code);
    machine.herites.cmos.regler(1_795_230_600); // novembre 2026
    carte.tenir().regler_heure(2_000_000_000_000); // mai 2033
    machine.tourner(10).expect("sans faute");
    assert_eq!(machine.cpu.regs[0] & 0xFF, 0x33, "l'année de la carte");
    // Sans la carte, les puces de la machine répondent.
    let mut seule = Machine::nouvelle(0);
    seule.cpu.control[0] = 1;
    seule.cpu.rip = 0x1000;
    seule.cpu.memory.bytes[0x1000..0x1000 + code.len()].copy_from_slice(&code);
    seule.herites.cmos.regler(1_795_230_600);
    seule.tourner(10).expect("sans faute");
    assert_eq!(seule.cpu.regs[0] & 0xFF, 0x26, "l'année des puces");
}
