//! **Le flottant dans la machine PC** : ce que les corpus, qui jugent une
//! instruction seule sur un processeur nu, ne peuvent pas dire — la faute
//! d'une exception de SSE démasquée (`#XM`, ou `#UD` sans CR4.OSXMMEXCPT),
//! un rangement du x87 qui faute à cheval sur deux pages sans rien laisser
//! derrière lui, et le préfixe `67` devant une instruction qui n'adresse rien.

use wisq_vm::pc::systeme::Table;
use wisq_vm::pc::Machine;
use wisq_vm::x86::Width;

const IDT: u64 = 0x9000;
const GESTIONNAIRE: u64 = 0x8000;
const SOMMET: u64 = 0x7000;
/// Les pages cartographiées, en identité ; 0x7000 et 0xB000 ne le sont pas.
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

fn porte(machine: &mut Machine, vecteur: u64, cible: u64) {
    let bas = (cible & 0xFFFF) | (0x10 << 16) | (0x8E << 40) | ((cible & 0xFFFF_0000) << 32);
    ecrire(machine, IDT + vecteur * 16, bas);
    ecrire(machine, IDT + vecteur * 16 + 8, cible >> 32);
}

/// Une machine en mode long, les pages de `PAGES` en identité, le code à
/// 0x1000, une porte par vecteur de 0 à 31 vers un gestionnaire propre à
/// chacun (`GESTIONNAIRE + 16 · vecteur`, un `hlt`).
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
    machine.cpu.memory.bytes[0x1000..0x1000 + code.len()].copy_from_slice(code);
    for vecteur in 0..32 {
        let cible = GESTIONNAIRE + 16 * vecteur;
        machine.cpu.memory.bytes[cible as usize] = 0xF4;
        porte(&mut machine, vecteur, cible);
    }
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

/// Le vecteur qu'une machine arrêtée dans un gestionnaire a reçu.
fn vecteur_recu(machine: &Machine) -> u64 {
    assert!(machine.arretee, "arrêtée dans un gestionnaire");
    (machine.cpu.rip - 1 - GESTIONNAIRE) / 16
}

/// **Une exception de SSE que MXCSR ne masque pas** : `divsd` par zéro, ZM
/// levé à zéro. Sous CR4.OSXMMEXCPT, `#XM` (vecteur 19) ; sans lui, `#UD`
/// (vecteur 6). Dans les deux cas, XMM0 n'a pas changé, le drapeau ZE est
/// posé dans MXCSR, et le cadre pointe sur `divsd`.
#[test]
fn an_unmasked_sse_exception_is_delivered_and_writes_nothing() {
    for (osxmmexcpt, attendu) in [(true, 19), (false, 6)] {
        // divsd %xmm1,%xmm0 ; hlt.
        let mut machine = nouvelle(&[0xF2, 0x0F, 0x5E, 0xC1, 0xF4]);
        if osxmmexcpt {
            machine.cpu.control[4] |= 1 << 10;
        }
        machine.cpu.mxcsr = 0x1F80 & !(1 << 9);
        machine.cpu.xmm[0] = [1.0f64.to_bits(), 7];
        machine.cpu.xmm[1] = [0, 0];
        machine.tourner(10).expect("livrée");
        assert_eq!(vecteur_recu(&machine), attendu, "OSXMMEXCPT {osxmmexcpt}");
        assert_eq!(machine.cpu.xmm[0], [1.0f64.to_bits(), 7], "rien d'écrit");
        assert_eq!(machine.cpu.mxcsr & 0x3F, 1 << 2, "ZE posé");
        let cadre = machine.cpu.memory.read(SOMMET - 40, Width::Qword);
        assert_eq!(cadre, Some(0x1000), "le RIP du cadre : divsd");
    }
    // Masquée, la même division rend l'infini et continue.
    let mut machine = nouvelle(&[0xF2, 0x0F, 0x5E, 0xC1, 0xF4]);
    machine.cpu.mxcsr = 0x1F80;
    machine.cpu.xmm[0] = [1.0f64.to_bits(), 7];
    machine.tourner(10).expect("sans faute");
    assert_eq!(machine.cpu.rip, 0x1005);
    assert_eq!(machine.cpu.xmm[0], [f64::INFINITY.to_bits(), 7]);
}

/// **`fstpt` à cheval sur une page absente** : dix octets à 0xAFFA, dont les
/// quatre derniers tombent dans 0xB000, qui n'est pas cartographiée. La
/// faute de page nomme 0xB000, et rien n'a bougé : ni les six octets de la
/// première page, ni la pile du x87.
#[test]
fn an_x87_store_across_a_missing_page_leaves_nothing_behind() {
    // fld1 ; fstpt (%rbx) ; hlt.
    let mut machine = nouvelle(&[0xD9, 0xE8, 0xDB, 0x3B, 0xF4]);
    machine.cpu.regs[3] = 0xAFFA;
    machine.cpu.fpu_control = 0x037F;
    machine.cpu.memory.bytes[0xAFFA..0xB000].fill(0xAB);
    machine.tourner(10).expect("livrée");
    assert_eq!(vecteur_recu(&machine), 14);
    assert_eq!(machine.cpu.control[2], 0xB000, "CR2");
    assert!(
        machine.cpu.memory.bytes[0xAFFA..0xB000]
            .iter()
            .all(|octet| *octet == 0xAB),
        "rien d'écrit dans la première page"
    );
    assert_eq!(
        machine.cpu.x87_top(),
        7,
        "un seul empilement, pas de dépilement"
    );
    assert_eq!(machine.cpu.fpu_tags, 1 << 7);
}

/// **`67` devant une instruction qui n'adresse rien** : `67 49 f7 e6`, le
/// `mul %r14` qu'OpenSSL aligne ainsi, s'exécute comme `mul %r14`, en quatre
/// octets. Devant une instruction qui adresse — un opérande mémoire, ou les
/// registres d'une chaîne —, `67` change le sens et reste refusé.
#[test]
fn an_address_size_prefix_without_address_is_ignored() {
    // mul %r14 (67-préfixé) ; hlt.
    let mut machine = nouvelle(&[0x67, 0x49, 0xF7, 0xE6, 0xF4]);
    machine.cpu.regs[0] = 0x1_0000_0001;
    machine.cpu.regs[14] = 0x1_0000_0000;
    machine.tourner(10).expect("sans faute");
    assert!(machine.arretee);
    assert_eq!(machine.cpu.rip, 0x1005, "quatre octets, puis hlt");
    assert_eq!(machine.cpu.regs[0], 0x1_0000_0000);
    assert_eq!(machine.cpu.regs[2], 0x1);
    for (nom, code) in [
        ("mov (%ebx),%rax", &[0x67, 0x48, 0x8B, 0x03][..]),
        ("movsb", &[0x67, 0xA4]),
        ("rep stosb", &[0xF3, 0x67, 0xAA]),
        ("loop", &[0x67, 0xE2, 0xFE]),
        ("jecxz", &[0x67, 0xE3, 0x00]),
    ] {
        let mut machine = nouvelle(code);
        machine.cpu.regs[1] = 1;
        let issue = machine.tourner(10);
        assert!(
            issue
                .as_ref()
                .is_err_and(|pourquoi| pourquoi.contains("ne lit pas")),
            "{nom} : {issue:?}"
        );
    }
}
