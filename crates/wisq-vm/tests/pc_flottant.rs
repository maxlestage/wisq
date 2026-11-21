//! **Le flottant dans la machine PC** : ce que les corpus, qui jugent une
//! instruction seule sur un processeur nu, ne peuvent pas dire — la faute
//! d'une exception de SSE démasquée (`#XM`, ou `#UD` sans CR4.OSXMMEXCPT),
//! un rangement du x87 (`fstpt`, `fnsave`, `fnstenv`) qui faute à cheval sur
//! deux pages sans rien laisser derrière lui, le préfixe `67` devant une
//! instruction qui n'adresse rien, et `lock` devant ce qui ne peut pas le
//! porter.

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

/// **Chaque préfixe que l'hôte admet devant `fwait`** : les six préfixes de
/// segment, `66`, `67`, `f2`, `f3` et les seize REX, seuls, puis mêlés
/// (`f3 f2`, `48 66`, `66 48`, `67 66 48 f2`, quatorze `66`). Sous une
/// exception en attente, chacun livre `#MF`, le cadre sur son premier
/// préfixe ; sans elle, chacun est un `nop` de sa longueur, compté pour une
/// instruction. Toutes ces suites livrent `SIGFPE` sur le silicium de l'hôte
/// (sonde `r6/c/mf4` du bloc-notes) ; `decode`, que l'émetteur partage, ne lit
/// ni `67 9b`, ni `f2 9b`, ni `48 66 9b`. Un `f0` n'importe où devant reste
/// refusé, comme SIGILL sur l'hôte.
#[test]
fn every_prefix_the_host_accepts_before_fwait_waits() {
    let mut suites: Vec<Vec<u8>> = [0x26, 0x2E, 0x36, 0x3E, 0x64, 0x65, 0x66, 0x67, 0xF2, 0xF3]
        .iter()
        .chain(&[0x40u8, 0x41, 0x42, 0x43, 0x44, 0x45, 0x46, 0x47])
        .chain(&[0x48u8, 0x49, 0x4A, 0x4B, 0x4C, 0x4D, 0x4E, 0x4F])
        .map(|prefixe| vec![*prefixe])
        .collect();
    suites.extend([
        vec![0xF3, 0xF2],
        vec![0x48, 0x66],
        vec![0x66, 0x48],
        vec![0x67, 0x66, 0x48, 0xF2],
        vec![0x66; 14],
    ]);
    // fld1 ; fldz ; fdivr %st(1),%st ; fnstsw %ax ; le fwait préfixé, à
    // 0x1008 ; hlt.
    let debut = [0xD9, 0xE8, 0xD9, 0xEE, 0xD8, 0xF9, 0xDF, 0xE0];
    for prefixes in &suites {
        let mut code = debut.to_vec();
        code.extend_from_slice(prefixes);
        code.extend_from_slice(&[0x9B, 0xF4]);
        let mut machine = nouvelle(&code);
        machine.cpu.fpu_control = 0x037B;
        machine.tourner(20).expect("livrée");
        assert_eq!(vecteur_recu(&machine), 16, "{prefixes:02x?} 9b : #MF");
        let cadre = machine.cpu.memory.read(SOMMET - 40, Width::Qword);
        assert_eq!(cadre, Some(0x1008), "{prefixes:02x?} 9b : le cadre");
        // Masquée : un nop de sa longueur, une instruction.
        let mut machine = nouvelle(&code);
        machine.tourner(20).expect("sans faute");
        assert!(machine.arretee, "{prefixes:02x?} 9b : jusqu'au hlt");
        assert_eq!(
            machine.cpu.rip,
            0x1008 + prefixes.len() as u64 + 2,
            "{prefixes:02x?} 9b : sa longueur"
        );
        assert_eq!(machine.retirees, 6, "{prefixes:02x?} 9b : une instruction");
    }
    for refuse in [
        &[0xF0, 0x66, 0x9B][..],
        &[0x66, 0xF0, 0x9B],
        &[0x48, 0xF0, 0x9B],
    ] {
        let mut code = refuse.to_vec();
        code.push(0xF4);
        let mut machine = nouvelle(&code);
        let issue = machine.tourner(10);
        assert!(
            issue
                .as_ref()
                .is_err_and(|pourquoi| pourquoi.contains("ne lit pas")),
            "{refuse:02x?} : {issue:?}"
        );
    }
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
    // lea -1(%ecx),%edx et lea -1(%ecx),%dx (67-préfixés) : l'adresse coupée
    // à la taille du registre, comme sur l'hôte — EDX à 0x4, RDX sans ses
    // bits hauts ; DX à 0x0004, le reste de RDX gardé (sonde `r6/c/lea67`).
    for (code, attendu) in [
        (&[0x67, 0x8D, 0x51, 0xFF, 0xF4][..], 0x4),
        (&[0x66, 0x67, 0x8D, 0x51, 0xFF, 0xF4], 0x5555_5555_5555_0004),
    ] {
        let mut machine = nouvelle(code);
        machine.cpu.regs[1] = 0x1_0000_0005;
        machine.cpu.regs[2] = 0x5555_5555_5555_5555;
        machine.tourner(10).expect("sans faute");
        assert!(machine.arretee);
        assert_eq!(machine.cpu.regs[2], attendu, "{code:02x?}");
    }
    // Deux `67` devant `movdqa %xmm1,%xmm2`, un devant `paddd` et devant
    // `addps` (le second décodeur) : ignorés, comme sur l'hôte (sondes
    // `r6/c/nt` pour les deux premiers, `r7/c/sonde` pour `addps`).
    let mut machine = nouvelle(&[
        0x67, 0x67, 0x66, 0x0F, 0x6F, 0xD1, // movdqa %xmm1,%xmm2
        0x67, 0x66, 0x0F, 0xFE, 0xD1, // paddd %xmm1,%xmm2
        0x67, 0x0F, 0x58, 0xD9, // addps %xmm1,%xmm3
        0xF4,
    ]);
    machine.cpu.xmm[1] = [0x0000_0002_0000_0001, 0x3F80_0000_3F80_0000];
    machine.tourner(10).expect("sans faute");
    assert!(machine.arretee);
    assert_eq!(machine.cpu.rip, 0x1010, "quinze octets, puis hlt");
    assert_eq!(
        machine.cpu.xmm[2],
        [0x0000_0004_0000_0002, 0x7F00_0000_7F00_0000]
    );
    assert_eq!(
        machine.cpu.xmm[3],
        [0x0000_0002_0000_0001, 0x3F80_0000_3F80_0000]
    );
    // **`67` après `f3` ou `f2`** : `addss` et `addsd` entre registres, le
    // préfixe de taille d'adresse pris entre le préfixe de répétition et
    // l'opcode. Ignoré sur l'hôte, qui rend la même somme qu'en son absence
    // (sonde `r7/c/sonde`) : 1 + 2 = 3 dans le flottant bas, le reste de XMM3
    // gardé ; en double, 2,000 000 47… + 2,000 000 47… (2,000 000 473 111 868
    // dans XMM1, 2,000 000 476 837 158 dans XMM3 ; la somme vaut
    // 4,000 000 949 949 026).
    for (code, attendu) in [
        (
            &[0xF3, 0x67, 0x0F, 0x58, 0xD9, 0xF4][..],
            [0x4000_0000_4040_0000, 0x3FF0_0000_0000_0000],
        ),
        (
            &[0xF2, 0x67, 0x0F, 0x58, 0xD9, 0xF4],
            [0x4010_0000_3FC0_0000, 0x3FF0_0000_0000_0000],
        ),
    ] {
        let mut machine = nouvelle(code);
        machine.cpu.xmm[1] = [0x4000_0000_3F80_0000, 0x4010_0000_0000_0000];
        machine.cpu.xmm[3] = [0x4000_0000_4000_0000, 0x3FF0_0000_0000_0000];
        machine.tourner(10).expect("sans faute");
        assert!(machine.arretee, "{code:02x?}");
        assert_eq!(
            machine.cpu.rip, 0x1006,
            "{code:02x?} : cinq octets, puis hlt"
        );
        assert_eq!(machine.cpu.xmm[3], attendu, "{code:02x?}");
    }
    // **Un préfixe de segment devant `67`** : les six, pris dans la liste des
    // préfixes que `sans_taille_d_adresse` ôte puis remet. Sur l'hôte, chacun
    // devant `67 49 f7 e6` s'exécute comme `mul %r14`, en cinq octets (sonde
    // `ctrl-r7/c/p` du bloc-notes).
    for segment in [0x2E, 0x36, 0x3E, 0x26, 0x64, 0x65] {
        let mut machine = nouvelle(&[segment, 0x67, 0x49, 0xF7, 0xE6, 0xF4]);
        machine.cpu.regs[0] = 0x1_0000_0001;
        machine.cpu.regs[14] = 0x1_0000_0000;
        machine.tourner(10).expect("sans faute");
        assert!(machine.arretee, "{segment:02x} 67 : jusqu'au hlt");
        assert_eq!(machine.cpu.rip, 0x1006, "{segment:02x} 67 : cinq octets");
        assert_eq!(machine.cpu.regs[0], 0x1_0000_0000, "{segment:02x} 67 : RAX");
        assert_eq!(machine.cpu.regs[2], 0x1, "{segment:02x} 67 : RDX");
    }
    for (nom, code) in [
        // `lock` devant `67 mul %r14`, d'un côté ou de l'autre : SIGILL sur
        // l'hôte (sondes `ctrl-r7/c/p` et `r8/c/verrou`).
        ("lock addr32 mul %r14", &[0xF0, 0x67, 0x49, 0xF7, 0xE6][..]),
        ("addr32 lock mul %r14", &[0x67, 0xF0, 0x49, 0xF7, 0xE6]),
        ("lea -1(%ecx),%rdx", &[0x67, 0x48, 0x8D, 0x51, 0xFF][..]),
        ("movdqa (%ebx),%xmm0", &[0x67, 0x67, 0x66, 0x0F, 0x6F, 0x03]),
        ("addps (%ebx),%xmm0", &[0x67, 0x0F, 0x58, 0x03]),
        ("maskmovq", &[0x67, 0x0F, 0xF7, 0xC1]),
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

/// **`lock` n'est admis que devant ce qui peut le porter** : une
/// lecture-modification-écriture dont la destination est en mémoire. Chaque
/// forme admise ici s'exécute sur l'hôte, chaque forme refusée y lève SIGILL
/// (`#UD`) : la sonde `r8/c/verrou` du bloc-notes les a jouées une à une.
/// Une forme admise va jusqu'au `hlt`, sa longueur juste ; `lock incl` et
/// `lock cmpxchg` écrivent ce qu'ils doivent. Une forme refusée n'est pas lue.
/// **Un préfixe devant `lock` ne le cache pas.** Sur l'hôte (sonde
/// `ctrl-r8/c/p.c` du bloc-notes), un préfixe de segment, `66` ou `f3` posé
/// avant le `f0` laisse la forme `#UD` (SIGILL) comme sans lui ; `f2` aussi,
/// devant le vectoriel. Chaque forme est jouée deux fois : sans `lock`, elle
/// s'exécute jusqu'au `hlt` (le préfixe est donc lu par un décodeur de la
/// machine) ; avec, elle est refusée. Ôter un préfixe de la liste de
/// `verrou_admis` ferait admettre les formes qui le portent.
#[test]
fn a_prefix_before_lock_does_not_hide_it() {
    let formes: [(&str, u8, &[u8]); 14] = [
        ("cs lock add %rax,%rbx", 0x2E, &[0x48, 0x01, 0xC3]),
        ("ds lock add (%rbx),%rax", 0x3E, &[0x48, 0x03, 0x03]),
        ("es lock nop", 0x26, &[0x90]),
        ("ss lock inc %eax", 0x36, &[0xFF, 0xC0]),
        ("fs lock add %rax,%rbx", 0x64, &[0x48, 0x01, 0xC3]),
        ("gs lock cmp %rax,(%rbx)", 0x65, &[0x48, 0x39, 0x03]),
        ("66 lock add %ax,%bx", 0x66, &[0x01, 0xC3]),
        ("66 lock cmp %ax,(%rbx)", 0x66, &[0x39, 0x03]),
        ("f3 lock add %rax,%rbx", 0xF3, &[0x48, 0x01, 0xC3]),
        ("f3 lock mov %rax,(%rbx)", 0xF3, &[0x48, 0x89, 0x03]),
        ("f2 lock addsd %xmm1,%xmm0", 0xF2, &[0x0F, 0x58, 0xC1]),
        ("f2 lock movsd (%rbx),%xmm0", 0xF2, &[0x0F, 0x10, 0x03]),
        ("f3 lock addss %xmm1,%xmm0", 0xF3, &[0x0F, 0x58, 0xC1]),
        ("66 lock paddd %xmm1,%xmm0", 0x66, &[0x0F, 0xFE, 0xC1]),
    ];
    for (nom, prefixe, corps) in formes {
        let mut sans = vec![prefixe];
        sans.extend_from_slice(corps);
        sans.push(0xF4);
        let mut machine = nouvelle(&sans);
        machine.cpu.regs[3] = 0x6000;
        machine.tourner(10).expect("sans faute");
        assert!(machine.arretee, "{nom}, sans lock : jusqu'au hlt");
        assert_eq!(
            machine.cpu.rip,
            0x1000 + sans.len() as u64,
            "{nom}, sans lock"
        );

        for devant in [&[][..], &[0x90, 0x90]] {
            let mut code = devant.to_vec();
            code.extend_from_slice(&[prefixe, 0xF0]);
            code.extend_from_slice(corps);
            code.push(0xF4);
            let mut machine = nouvelle(&code);
            machine.cpu.regs[3] = 0x6000;
            let issue = machine.tourner(10);
            assert!(
                issue
                    .as_ref()
                    .is_err_and(|pourquoi| pourquoi.contains("ne lit pas")),
                "{devant:02x?} {nom} : {issue:?}"
            );
            assert_eq!(
                machine.cpu.rip,
                0x1000 + devant.len() as u64,
                "{devant:02x?} {nom} : arrêtée sur elle"
            );
        }
    }
}

#[test]
fn lock_is_taken_only_before_what_can_carry_it() {
    let admises: [(&str, &[u8]); 30] = [
        ("lock cmpxchg %rcx,(%rbx)", &[0xF0, 0x48, 0x0F, 0xB1, 0x0B]),
        ("lock cmpxchgb %cl,(%rbx)", &[0xF0, 0x0F, 0xB0, 0x0B]),
        ("lock xadd %eax,(%rbx)", &[0xF0, 0x0F, 0xC1, 0x03]),
        ("lock xaddb %al,(%rbx)", &[0xF0, 0x0F, 0xC0, 0x03]),
        ("lock incl (%rbx)", &[0xF0, 0xFF, 0x03]),
        ("lock decl (%rbx)", &[0xF0, 0xFF, 0x0B]),
        ("lock incw (%rbx)", &[0xF0, 0x66, 0xFF, 0x03]),
        ("lock incw (%rbx), 66 d'abord", &[0x66, 0xF0, 0xFF, 0x03]),
        ("lock incb (%rbx)", &[0xF0, 0xFE, 0x03]),
        ("lock orl $0,(%rbx)", &[0xF0, 0x83, 0x0B, 0x00]),
        ("lock add %rax,(%rbx)", &[0xF0, 0x48, 0x01, 0x03]),
        (
            "lock addl $1,(%rbx)",
            &[0xF0, 0x81, 0x03, 0x01, 0x00, 0x00, 0x00],
        ),
        ("lock andb $0xf,(%rbx)", &[0xF0, 0x80, 0x23, 0x0F]),
        ("lock sub %rax,(%rbx)", &[0xF0, 0x48, 0x29, 0x03]),
        ("lock xor %rax,(%rbx)", &[0xF0, 0x48, 0x31, 0x03]),
        ("lock adc %rax,(%rbx)", &[0xF0, 0x48, 0x11, 0x03]),
        ("lock sbb %rax,(%rbx)", &[0xF0, 0x48, 0x19, 0x03]),
        ("lock or %eax,(%rbx)", &[0xF0, 0x09, 0x03]),
        ("lock and %eax,(%rbx)", &[0xF0, 0x21, 0x03]),
        ("lock negl (%rbx)", &[0xF0, 0xF7, 0x1B]),
        ("lock notl (%rbx)", &[0xF0, 0xF7, 0x13]),
        ("lock bts %eax,(%rbx)", &[0xF0, 0x0F, 0xAB, 0x03]),
        ("lock btr %eax,(%rbx)", &[0xF0, 0x0F, 0xB3, 0x03]),
        ("lock btc %eax,(%rbx)", &[0xF0, 0x0F, 0xBB, 0x03]),
        ("lock btsl $1,(%rbx)", &[0xF0, 0x0F, 0xBA, 0x2B, 0x01]),
        ("lock btrl $1,(%rbx)", &[0xF0, 0x0F, 0xBA, 0x33, 0x01]),
        ("lock btcl $1,(%rbx)", &[0xF0, 0x0F, 0xBA, 0x3B, 0x01]),
        ("lock xchg %rax,(%rbx)", &[0xF0, 0x48, 0x87, 0x03]),
        ("lock xchgb %al,(%rbx)", &[0xF0, 0x86, 0x03]),
        ("lock cmpxchg16b (%rbx)", &[0xF0, 0x48, 0x0F, 0xC7, 0x0B]),
    ];
    for (nom, forme) in admises {
        for prefixe in [&[][..], &[0x2E], &[0xF0]] {
            let mut code = prefixe.to_vec();
            code.extend_from_slice(forme);
            code.push(0xF4);
            let mut machine = nouvelle(&code);
            machine.cpu.regs[0] = 1;
            machine.cpu.regs[1] = 2;
            machine.cpu.regs[3] = 0x6000;
            machine.tourner(10).expect("sans faute");
            assert!(machine.arretee, "{prefixe:02x?} {nom} : jusqu'au hlt");
            assert_eq!(
                machine.cpu.rip,
                0x1000 + code.len() as u64,
                "{prefixe:02x?} {nom} : sa longueur"
            );
        }
    }
    // Ce qu'elles écrivent : `lock incl` compte, `lock cmpxchg` (RAX à 0,
    // comme la mémoire) range RCX.
    let mut machine = nouvelle(&[0xF0, 0xFF, 0x03, 0xF0, 0xFF, 0x03, 0xF4]);
    machine.cpu.regs[3] = 0x6000;
    machine.tourner(10).expect("sans faute");
    assert_eq!(machine.cpu.memory.read(0x6000, Width::Dword), Some(2));
    let mut machine = nouvelle(&[0xF0, 0x48, 0x0F, 0xB1, 0x0B, 0xF4]);
    machine.cpu.regs[1] = 0x1234_5678_9ABC;
    machine.cpu.regs[3] = 0x6000;
    machine.tourner(10).expect("sans faute");
    assert_eq!(
        machine.cpu.memory.read(0x6000, Width::Qword),
        Some(0x1234_5678_9ABC)
    );
    let refusees: [(&str, &[u8]); 26] = [
        ("lock mul %r14", &[0xF0, 0x49, 0xF7, 0xE6]),
        ("lock add %rax,%rbx", &[0xF0, 0x48, 0x01, 0xC3]),
        ("lock add (%rbx),%rax", &[0xF0, 0x48, 0x03, 0x03]),
        ("lock cmp %rax,(%rbx)", &[0xF0, 0x48, 0x39, 0x03]),
        ("lock cmpl $0,(%rbx)", &[0xF0, 0x83, 0x3B, 0x00]),
        ("lock test %rax,(%rbx)", &[0xF0, 0x48, 0x85, 0x03]),
        (
            "lock testl $1,(%rbx)",
            &[0xF0, 0xF7, 0x03, 0x01, 0x00, 0x00, 0x00],
        ),
        ("lock mov %rax,(%rbx)", &[0xF0, 0x48, 0x89, 0x03]),
        ("lock bt %eax,(%rbx)", &[0xF0, 0x0F, 0xA3, 0x03]),
        ("lock btl $1,(%rbx)", &[0xF0, 0x0F, 0xBA, 0x23, 0x01]),
        ("lock nop", &[0xF0, 0x90]),
        ("lock lea (%rbx),%rax", &[0xF0, 0x48, 0x8D, 0x03]),
        ("lock cmpxchg %rcx,%rbx", &[0xF0, 0x48, 0x0F, 0xB1, 0xCB]),
        ("lock xchg %rax,%rbx", &[0xF0, 0x48, 0x87, 0xC3]),
        ("lock incl %eax", &[0xF0, 0xFF, 0xC0]),
        ("lock shll (%rbx)", &[0xF0, 0xD1, 0x23]),
        ("lock addps %xmm1,%xmm3", &[0xF0, 0x0F, 0x58, 0xD9]),
        ("lock movdqa %xmm0,(%rbx)", &[0xF0, 0x66, 0x0F, 0x7F, 0x03]),
        ("lock xadd %eax,%ebx", &[0xF0, 0x0F, 0xC1, 0xC3]),
        ("lock bts %eax,%ebx", &[0xF0, 0x0F, 0xAB, 0xC3]),
        ("lock negl %eax", &[0xF0, 0xF7, 0xD8]),
        ("lock pushq (%rbx)", &[0xF0, 0xFF, 0x33]),
        ("lock movzbl (%rbx),%eax", &[0xF0, 0x0F, 0xB6, 0x03]),
        ("lock imul (%rbx),%eax", &[0xF0, 0x0F, 0xAF, 0x03]),
        ("lock setz (%rbx)", &[0xF0, 0x0F, 0x94, 0x03]),
        ("lock rcll (%rbx)", &[0xF0, 0xD1, 0x13]),
    ];
    for (nom, forme) in refusees {
        // Seule, puis derrière une instruction ordinaire (`nop`), pour que
        // le bloc qui commence avant elle la lise aussi.
        for devant in [&[][..], &[0x90, 0x90]] {
            let mut code = devant.to_vec();
            code.extend_from_slice(forme);
            code.push(0xF4);
            let mut machine = nouvelle(&code);
            machine.cpu.regs[3] = 0x6000;
            let issue = machine.tourner(10);
            assert!(
                issue
                    .as_ref()
                    .is_err_and(|pourquoi| pourquoi.contains("ne lit pas")),
                "{devant:02x?} {nom} : {issue:?}"
            );
            assert_eq!(
                machine.cpu.rip,
                0x1000 + devant.len() as u64,
                "{devant:02x?} {nom} : arrêtée sur elle"
            );
        }
    }
}

/// **Les rangements non temporels rangent comme les autres** : `movntdq`,
/// `movntps`, `movntpd`, `movnti` sur trente-deux et soixante-quatre bits,
/// chacun à sa place, la longueur juste (le `hlt` est atteint). Leur forme
/// registre reste refusée, et leurs formes sous `f3`, `f2` ou (pour `movnti`)
/// `66` : SIGILL sur l'hôte (sonde `r6/c/nt`).
#[test]
fn non_temporal_stores_store_like_the_others() {
    let code = [
        0x66, 0x0F, 0xE7, 0x13, // movntdq %xmm2,(%rbx)
        0x0F, 0x2B, 0x4B, 0x10, // movntps %xmm1,0x10(%rbx)
        0x66, 0x0F, 0x2B, 0x53, 0x20, // movntpd %xmm2,0x20(%rbx)
        0x0F, 0xC3, 0x43, 0x30, // movnti %eax,0x30(%rbx)
        0x48, 0x0F, 0xC3, 0x43, 0x38, // movnti %rax,0x38(%rbx)
        0xF4,
    ];
    let mut machine = nouvelle(&code);
    machine.cpu.regs[3] = 0x6000;
    machine.cpu.regs[0] = 0x1122_3344_5566_7788;
    machine.cpu.xmm[1] = [0x0101_0101_0101_0101, 0x0202_0202_0202_0202];
    machine.cpu.xmm[2] = [0x0303_0303_0303_0303, 0x0404_0404_0404_0404];
    machine.tourner(20).expect("sans faute");
    assert!(machine.arretee);
    assert_eq!(machine.cpu.rip, 0x1000 + code.len() as u64, "jusqu'au hlt");
    let lire = |adresse: u64| machine.cpu.memory.read(adresse, Width::Qword).unwrap();
    assert_eq!([lire(0x6000), lire(0x6008)], machine.cpu.xmm[2], "movntdq");
    assert_eq!([lire(0x6010), lire(0x6018)], machine.cpu.xmm[1], "movntps");
    assert_eq!([lire(0x6020), lire(0x6028)], machine.cpu.xmm[2], "movntpd");
    assert_eq!(lire(0x6030), 0x5566_7788, "movnti, trente-deux bits");
    assert_eq!(
        lire(0x6038),
        0x1122_3344_5566_7788,
        "movnti, soixante-quatre"
    );
    // **Sous chaque préfixe de segment**, `movnti` range aussi : `es`, `cs`,
    // `ss` et `ds` n'ont pas de base en mode long, `fs` et `gs` ajoutent la
    // leur. Sur l'hôte, `26`, `2e`, `36`, `3e`, `64` et `65` devant
    // `0f c3 03` rangent tous (sonde `r7/c/sonde`).
    for (prefixe, base) in [
        (0x26, 0),
        (0x2E, 0),
        (0x36, 0),
        (0x3E, 0),
        (0x64, 0x100),
        (0x65, 0x200),
    ] {
        let code = [prefixe, 0x0F, 0xC3, 0x03, 0xF4]; // movnti %eax,%seg:(%rbx)
        let mut machine = nouvelle(&code);
        machine.cpu.regs[3] = 0x6000;
        machine.cpu.regs[0] = 0x1122_3344;
        machine.cpu.fs_base = 0x100;
        machine.cpu.gs_base = 0x200;
        machine.tourner(10).expect("sans faute");
        assert!(machine.arretee, "{prefixe:02x}");
        assert_eq!(
            machine.cpu.rip, 0x1005,
            "{prefixe:02x} : quatre octets, puis hlt"
        );
        assert_eq!(
            machine.cpu.memory.read(0x6000 + base, Width::Dword),
            Some(0x1122_3344),
            "{prefixe:02x}"
        );
    }
    for refuse in [
        &[0x66, 0x0F, 0xE7, 0xD2][..], // movntdq %xmm2,%xmm2
        &[0x0F, 0x2B, 0xCA],           // movntps, registre
        &[0x0F, 0xC3, 0xC0],           // movnti, registre
        &[0xF3, 0x0F, 0xE7, 0x13],     // f3 : rien
        &[0xF3, 0x0F, 0x2B, 0x13],
        &[0xF3, 0x0F, 0xC3, 0x03],
        &[0xF2, 0x0F, 0xC3, 0x03],
        &[0x66, 0x0F, 0xC3, 0x03], // movnti n'a pas de forme 66
    ] {
        let mut code = refuse.to_vec();
        code.push(0xF4);
        let mut machine = nouvelle(&code);
        machine.cpu.regs[3] = 0x6000;
        let issue = machine.tourner(10);
        assert!(
            issue
                .as_ref()
                .is_err_and(|pourquoi| pourquoi.contains("ne lit pas")),
            "{refuse:02x?} : {issue:?}"
        );
    }
}
