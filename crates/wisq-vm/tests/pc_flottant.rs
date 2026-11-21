//! **Le flottant dans la machine PC** : ce que les corpus, qui jugent une
//! instruction seule sur un processeur nu, ne peuvent pas dire — la faute
//! d'une exception de SSE démasquée (`#XM`, ou `#UD` sans CR4.OSXMMEXCPT),
//! un rangement du x87 (`fstpt`, `fnsave`, `fnstenv`) qui faute à cheval sur
//! deux pages sans rien laisser derrière lui, et le préfixe `67` devant une
//! instruction qui n'adresse rien.

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

/// **`fstpt` à cheval sur une page absente** : dix octets à 0xAFF8, dont les
/// deux derniers tombent dans 0xB000, qui n'est pas cartographiée. Les huit
/// premiers tiennent dans la première page : un rangement qui ne sonderait
/// pas la seconde avant d'écrire les y laisserait. La faute de page nomme
/// 0xB000, et rien n'a bougé : ni les huit octets de la première page, ni la
/// pile du x87.
#[test]
fn an_x87_store_across_a_missing_page_leaves_nothing_behind() {
    // fld1 ; fstpt (%rbx) ; hlt.
    let mut machine = nouvelle(&[0xD9, 0xE8, 0xDB, 0x3B, 0xF4]);
    machine.cpu.regs[3] = 0xAFF8;
    machine.cpu.fpu_control = 0x037F;
    machine.cpu.memory.bytes[0xAFF8..0xB000].fill(0xAB);
    machine.tourner(10).expect("livrée");
    assert_eq!(vecteur_recu(&machine), 14);
    assert_eq!(machine.cpu.control[2], 0xB000, "CR2");
    assert!(
        machine.cpu.memory.bytes[0xAFF8..0xB000]
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

/// **Une exception du x87 démasquée attend la prochaine instruction qui
/// attend** : `fdivr` de 1 par 0, la division par zéro démasquée, ne range
/// rien (ST(0) reste 0, la pile ne bouge pas) et lève ZE, ES et B ;
/// `fnstsw %ax`, qui n'attend pas, passe et le lit ; puis `fwait` (préfixé
/// ou non), `fld1`, `emms`, une instruction du MMX ou une conversion de SSE
/// qui touche un registre MMX livrent `#MF` (vecteur 16), le cadre sur
/// elles-mêmes — chacune livre `SIGFPE` sur le silicium de l'hôte.
#[test]
fn an_unmasked_x87_exception_is_delivered_by_the_next_waiting_instruction() {
    // fld1 ; fldz ; fdivr %st(1),%st ; fnstsw %ax ; puis l'instruction qui
    // attend, à 0x1008 ; hlt.
    let debut = [0xD9, 0xE8, 0xD9, 0xEE, 0xD8, 0xF9, 0xDF, 0xE0];
    for (nom, suite) in [
        ("fwait", &[0x9B][..]),
        ("rex.w fwait", &[0x48, 0x9B]),
        ("66 fwait", &[0x66, 0x9B]),
        ("f3 fwait", &[0xF3, 0x9B]),
        ("fld1", &[0xD9, 0xE8]),
        ("emms", &[0x0F, 0x77]),
        ("movq %mm0,%mm1", &[0x0F, 0x6F, 0xC8]),
        ("movq2dq", &[0xF3, 0x0F, 0xD6, 0xC0]),
        ("cvtpi2ps %mm0,%xmm0", &[0x0F, 0x2A, 0xC0]),
        ("cvtpi2pd %mm0,%xmm0", &[0x66, 0x0F, 0x2A, 0xC0]),
        ("cvtps2pi %xmm0,%mm0", &[0x0F, 0x2D, 0xC0]),
        ("cvttps2pi %xmm0,%mm0", &[0x0F, 0x2C, 0xC0]),
        ("cvtpd2pi %xmm0,%mm0", &[0x66, 0x0F, 0x2D, 0xC0]),
        ("cvtps2pi (%rbx),%mm0", &[0x0F, 0x2D, 0x03]),
    ] {
        let mut code = debut.to_vec();
        code.extend_from_slice(suite);
        code.push(0xF4);
        let mut machine = nouvelle(&code);
        machine.cpu.fpu_control = 0x037B;
        machine.cpu.regs[3] = 0x6000;
        machine.tourner(20).expect("livrée");
        assert_eq!(vecteur_recu(&machine), 16, "{nom} : #MF");
        let cadre = machine.cpu.memory.read(SOMMET - 40, Width::Qword);
        assert_eq!(
            cadre,
            Some(0x1008),
            "{nom} : le cadre sur l'instruction qui attend"
        );
        assert_eq!(
            machine.cpu.regs[0] & 0x80BF,
            0x8084,
            "{nom} : fnstsw a lu ZE, ES et B"
        );
        assert_eq!(machine.cpu.x87_top(), 6, "{nom} : la pile n'a pas bougé");
        assert_eq!(machine.cpu.x87[6], (0, 0), "{nom} : ST(0) est resté zéro");
    }
    // fnclex, fninit ou fnsave avant fwait : rien n'attend plus.
    for (nom, efface) in [
        ("fnclex", &[0xDB, 0xE2][..]),
        ("fninit", &[0xDB, 0xE3]),
        ("fnsave (%rbx)", &[0xDD, 0x33]),
    ] {
        let mut code = debut.to_vec();
        code.extend_from_slice(efface);
        code.extend_from_slice(&[0x9B, 0xF4]);
        let mut machine = nouvelle(&code);
        machine.cpu.fpu_control = 0x037B;
        machine.cpu.regs[3] = 0x6000;
        machine.tourner(20).expect("sans faute");
        assert!(machine.arretee, "{nom}");
        assert_eq!(
            machine.cpu.rip,
            0x1008 + efface.len() as u64 + 2,
            "{nom} : jusqu'au hlt"
        );
    }
    // Masquée, la même division rend l'infini et continue.
    let mut code = debut.to_vec();
    code.extend_from_slice(&[0x9B, 0xF4]);
    let mut machine = nouvelle(&code);
    machine.tourner(20).expect("sans faute");
    assert_eq!(machine.cpu.rip, 0x100A);
    assert_eq!(machine.cpu.x87[6], (1 << 63, 0x7FFF), "+∞");
}

/// **Ce qui n'attend pas passe sous une exception en attente** : les formes
/// `fn…` qui rangent un mot ou l'environnement en mémoire, `fneni`, `fndisi`
/// et `fnsetpm` (des restes du 8087 et du 80287), et `cvtpi2ps` ou
/// `cvtpi2pd` depuis la mémoire, que le manuel dit sans passage au MMX. Sur le
/// silicium de l'hôte, aucune ne livre `SIGFPE`. ES reste levé — sauf après
/// `fnstenv`, qui masque tout une fois l'environnement rangé : le `fwait` qui
/// suit livre `#MF`, le cadre sur lui, ou passe après `fnstenv` (l'hôte fait
/// de même). `fnstsw` et `fnstcw` ont rangé leur mot ; `fnstenv`,
/// l'environnement, ES compris.
#[test]
fn what_does_not_wait_runs_under_a_pending_exception() {
    // fld1 ; fldz ; fdivr %st(1),%st ; fnstsw %ax ; l'instruction à 0x1008 ;
    // fwait ; hlt.
    let debut = [0xD9, 0xE8, 0xD9, 0xEE, 0xD8, 0xF9, 0xDF, 0xE0];
    for (nom, suite, ecrit) in [
        ("fnstsw (%rbx)", &[0xDD, 0x3B][..], Some(0xB084u16)),
        ("fnstcw (%rbx)", &[0xD9, 0x3B], Some(0x037B)),
        ("fnstenv (%rbx)", &[0xD9, 0x33], Some(0x037B)),
        ("fneni", &[0xDB, 0xE0], None),
        ("fndisi", &[0xDB, 0xE1], None),
        ("fnsetpm", &[0xDB, 0xE4], None),
        ("cvtpi2ps (%rbx),%xmm0", &[0x0F, 0x2A, 0x03], None),
        ("cvtpi2pd (%rbx),%xmm0", &[0x66, 0x0F, 0x2A, 0x03], None),
    ] {
        let mut code = debut.to_vec();
        code.extend_from_slice(suite);
        code.extend_from_slice(&[0x9B, 0xF4]);
        let mut machine = nouvelle(&code);
        machine.cpu.fpu_control = 0x037B;
        machine.cpu.regs[3] = 0x6000;
        machine.tourner(20).expect("sans arrêt nommé");
        let fwait = 0x1008 + suite.len() as u64;
        if nom.starts_with("fnstenv") {
            assert!(machine.arretee);
            assert_eq!(machine.cpu.rip, fwait + 2, "fnstenv : jusqu'au hlt");
        } else {
            assert_eq!(vecteur_recu(&machine), 16, "{nom} : #MF au fwait");
            let cadre = machine.cpu.memory.read(SOMMET - 40, Width::Qword);
            assert_eq!(cadre, Some(fwait), "{nom} : le cadre sur fwait");
        }
        if let Some(mot) = ecrit {
            let lu = machine.cpu.memory.read(0x6000, Width::Word);
            assert_eq!(lu, Some(u64::from(mot)), "{nom} : le mot rangé");
        }
        if nom.starts_with("fnstenv") {
            let etat = machine.cpu.memory.read(0x6004, Width::Word);
            assert_eq!(etat, Some(0xB084), "fnstenv : le mot d'état, ES compris");
        }
    }
}

/// **`fldcw` qui démasque une exception déjà levée la met en attente** :
/// `fdivr` de 1 par 0, masquée, lève ZE sans ES ; `fldcw` d'un mot qui
/// démasque ZE lève ES et B, et le `fwait` suivant livre `#MF`.
#[test]
fn fldcw_unmasking_a_raised_exception_makes_it_pending() {
    // fld1 ; fldz ; fdivr %st(1),%st ; fnstsw %ax ; fldcw (%rbx) ; fwait ;
    // hlt.
    let code = [
        0xD9, 0xE8, 0xD9, 0xEE, 0xD8, 0xF9, 0xDF, 0xE0, 0xD9, 0x2B, 0x9B, 0xF4,
    ];
    let mut machine = nouvelle(&code);
    machine.cpu.regs[3] = 0x6000;
    ecrire(&mut machine, 0x6000, 0x037B);
    machine.tourner(20).expect("livrée");
    assert_eq!(machine.cpu.regs[0] & 0x80BF, 0x0004, "ZE seul, sans ES");
    assert_eq!(vecteur_recu(&machine), 16, "#MF au fwait");
    let cadre = machine.cpu.memory.read(SOMMET - 40, Width::Qword);
    assert_eq!(cadre, Some(0x100A), "le cadre sur fwait");
    assert_eq!(machine.cpu.fpu_status & 0x8080, 0x8080, "ES et B");
}

/// **`fwait` compte pour une instruction**, préfixé ou non, comme le `nop`
/// qu'il est sans exception en attente : le 8253 avance sur le compte des
/// instructions retirées.
#[test]
fn fwait_is_counted_as_one_instruction() {
    let compte = |code: &[u8]| {
        let mut machine = nouvelle(code);
        machine.tourner(20).expect("sans faute");
        assert!(machine.arretee);
        (machine.retirees, machine.cpu.rip)
    };
    // fwait ; rex.w fwait ; 66 fwait ; hlt — puis la même suite en nop.
    let attentes = compte(&[0x9B, 0x48, 0x9B, 0x66, 0x9B, 0xF4]);
    let nops = compte(&[0x90, 0x48, 0x90, 0x66, 0x90, 0xF4]);
    assert_eq!(attentes, nops);
    assert_eq!(attentes.1, 0x1006, "jusqu'au hlt");
    // `lock fwait` n'est pas une attente : `#UD` sur l'hôte (SIGILL), un
    // arrêt nommé ici.
    let mut machine = nouvelle(&[0xF0, 0x9B, 0xF4]);
    let issue = machine.tourner(10);
    assert!(
        issue
            .as_ref()
            .is_err_and(|pourquoi| pourquoi.contains("ne lit pas")),
        "lock fwait : {issue:?}"
    );
}

/// **`fnsave` et `fnstenv` à cheval sur une page absente** : `fnsave` range
/// 108 octets à 0xAFC0, dont l'environnement et les trois premiers
/// registres tiennent dans la première page ; `fnstenv` en range 28 à
/// 0xAFF0, dont les seize premiers y tiennent. L'aire entière est sondée
/// avant le premier octet : la faute de page nomme 0xB000, rien n'est écrit,
/// et le x87 n'a pas bougé — ni remis à zéro par `fnsave`, ni masqué par
/// `fnstenv`.
#[test]
fn fnsave_and_fnstenv_across_a_missing_page_leave_nothing_behind() {
    // fld1 ; fnsave (%rbx) ; hlt — puis fld1 ; fnstenv (%rbx) ; hlt.
    for (nom, code, adresse) in [
        ("fnsave", [0xD9, 0xE8, 0xDD, 0x33, 0xF4], 0xAFC0usize),
        ("fnstenv", [0xD9, 0xE8, 0xD9, 0x33, 0xF4], 0xAFF0),
    ] {
        let mut machine = nouvelle(&code);
        machine.cpu.regs[3] = adresse as u64;
        machine.cpu.fpu_control = 0x027F;
        machine.cpu.memory.bytes[adresse..0xB000].fill(0xAB);
        machine.tourner(10).expect("livrée");
        assert_eq!(vecteur_recu(&machine), 14, "{nom}");
        assert_eq!(machine.cpu.control[2], 0xB000, "{nom} : CR2");
        assert!(
            machine.cpu.memory.bytes[adresse..0xB000]
                .iter()
                .all(|octet| *octet == 0xAB),
            "{nom} : rien d'écrit dans la première page"
        );
        assert_eq!(
            machine.cpu.fpu_control, 0x027F,
            "{nom} : le mot de contrôle"
        );
        assert_eq!(machine.cpu.x87_top(), 7, "{nom} : le sommet");
        assert_eq!(machine.cpu.fpu_tags, 1 << 7, "{nom} : les étiquettes");
    }
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
        ("lodsb", &[0x67, 0xAC]),
        ("cmpsb", &[0x67, 0xA6]),
        ("scasb", &[0x67, 0xAE]),
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
