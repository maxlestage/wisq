//! **x86-64-v2 contre le silicium de l'hôte** : SSE3, SSSE3, SSE4.1, SSE4.2,
//! `crc32`, `lahf` et `sahf`.
//!
//! La glibc de RHEL 9 (AlmaLinux, Rocky) refuse de démarrer sur un processeur
//! qui n'annonce pas x86-64-v2 (« Fatal glibc error: CPU does not support
//! x86-64-v2 »), et ses programmes emploient ces instructions partout. Aucun
//! corpus ne les porte : chaque forme est jugée ici en la faisant exécuter
//! **par le processeur qui fait tourner le test**, sur des états tirés au
//! hasard, et l'interpréteur doit rendre les mêmes registres, les mêmes
//! drapeaux et la même mémoire, au bit près.
//!
//! **Le banc.** Une page exécutable, un prologue qui charge XMM0 à XMM2,
//! RAX, RCX, RDX et RFLAGS d'un état, et pose RSI sur seize octets de
//! mémoire ; l'instruction ; un épilogue qui range tout. Les encodages jugés
//! n'emploient que ces registres et `[rsi]`.
//!
//! Ailleurs qu'en x86-64 avec SSE4.2, ce fichier ne juge rien.

#![cfg(target_arch = "x86_64")]

use std::arch::asm;

use wisq_vm::x86::{decode, decode_extended, Cpu, GuestMemory, Op};

/// L'état échangé avec le banc, à des décalages fixes.
#[repr(C, align(16))]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct Etat {
    xmm: [[u64; 2]; 3], // 0, 16, 32
    rax: u64,           // 48
    rcx: u64,           // 56
    rdx: u64,           // 64
    entree: u64,        // 72 : RFLAGS avant
    sortie: u64,        // 80 : RFLAGS après
    _bourrage: u64,     // 88
    memoire: [u8; 16],  // 96
}

const MEMOIRE: u64 = 0x5000;
/// Les drapeaux comparés : CF, PF, AF, ZF, SF, OF.
const DRAPEAUX: u64 = 0x8D5;

/// Une page lisible, inscriptible et exécutable, par `mmap`.
fn page() -> *mut u8 {
    let rendu: isize;
    // SAFETY : `mmap` anonyme, sans fichier ; les registres que l'appel
    // système écrase sont déclarés.
    unsafe {
        asm!(
            "syscall",
            inlateout("rax") 9isize => rendu,
            in("rdi") 0usize,
            in("rsi") 4096usize,
            in("rdx") 7usize,
            in("r10") 0x22usize,
            in("r8") -1isize,
            in("r9") 0usize,
            lateout("rcx") _,
            lateout("r11") _,
        );
    }
    assert!(rendu > 0, "mmap a refusé une page exécutable : {rendu}");
    rendu as *mut u8
}

/// **Le silicium** : l'instruction, exécutée par l'hôte sur `etat`.
fn silicium(instruction: &[u8], etat: &mut Etat) {
    const PROLOGUE: &[u8] = &[
        0xF3, 0x0F, 0x6F, 0x07, // movdqu (%rdi),%xmm0
        0xF3, 0x0F, 0x6F, 0x4F, 0x10, // movdqu 16(%rdi),%xmm1
        0xF3, 0x0F, 0x6F, 0x57, 0x20, // movdqu 32(%rdi),%xmm2
        0x48, 0x8B, 0x47, 0x30, // mov 48(%rdi),%rax
        0x48, 0x8B, 0x4F, 0x38, // mov 56(%rdi),%rcx
        0x48, 0x8B, 0x57, 0x40, // mov 64(%rdi),%rdx
        0xFF, 0x77, 0x48, // pushq 72(%rdi)
        0x9D, // popfq
        0x48, 0x8D, 0x77, 0x60, // lea 96(%rdi),%rsi
    ];
    const EPILOGUE: &[u8] = &[
        0x9C, // pushfq
        0x8F, 0x47, 0x50, // popq 80(%rdi)
        0xF3, 0x0F, 0x7F, 0x07, // movdqu %xmm0,(%rdi)
        0xF3, 0x0F, 0x7F, 0x4F, 0x10, // movdqu %xmm1,16(%rdi)
        0xF3, 0x0F, 0x7F, 0x57, 0x20, // movdqu %xmm2,32(%rdi)
        0x48, 0x89, 0x47, 0x30, // mov %rax,48(%rdi)
        0x48, 0x89, 0x4F, 0x38, // mov %rcx,56(%rdi)
        0x48, 0x89, 0x57, 0x40, // mov %rdx,64(%rdi)
        0xC3, // ret
    ];
    thread_local! {
        static PAGE: *mut u8 = page();
    }
    PAGE.with(|&page| {
        let code: Vec<u8> = [PROLOGUE, instruction, EPILOGUE].concat();
        // SAFETY : la page fait 4096 octets, le code bien moins ; elle n'est
        // à personne d'autre que ce fil.
        unsafe {
            std::ptr::copy_nonoverlapping(code.as_ptr(), page, code.len());
            let appel: extern "C" fn(*mut Etat) = std::mem::transmute(page);
            appel(etat);
        }
    });
}

/// **L'interpréteur**, sur le même état : `decode`, puis `decode_extended`.
fn interprete(instruction: &[u8], etat: &mut Etat) -> Result<(), String> {
    let mut cpu = Cpu {
        memory: GuestMemory {
            base: MEMOIRE,
            bytes: etat.memoire.to_vec(),
        },
        ..Default::default()
    };
    cpu.xmm[..3].copy_from_slice(&etat.xmm);
    cpu.regs[0] = etat.rax;
    cpu.regs[1] = etat.rcx;
    cpu.regs[2] = etat.rdx;
    cpu.regs[6] = MEMOIRE;
    cpu.flags.write(etat.entree);
    cpu.mxcsr = 0x1F80;
    // Le mot de contrôle d'après `fninit`, celui de l'hôte.
    cpu.fpu_control = 0x037F;
    // Une suite d'instructions, une à une : de quoi charger la pile du x87
    // avant l'instruction jugée.
    let mut ici = 0;
    while ici < instruction.len() {
        executer_une(&mut cpu, &instruction[ici..], &mut ici)?;
    }
    etat.xmm.copy_from_slice(&cpu.xmm[..3]);
    etat.rax = cpu.regs[0];
    etat.rcx = cpu.regs[1];
    etat.rdx = cpu.regs[2];
    etat.sortie = cpu.flags.read();
    etat.memoire.copy_from_slice(&cpu.memory.bytes);
    Ok(())
}

fn executer_une(cpu: &mut Cpu, instruction: &[u8], ici: &mut usize) -> Result<(), String> {
    if let Some(lue) = decode(instruction) {
        *ici += lue.length;
        // Comme la machine PC : le vectoriel passe par `execute_vector`.
        if matches!(lue.op, Op::Vector(_)) {
            cpu.execute_vector(&lue)
                .map_err(|faute| format!("{faute:?}"))?;
        } else {
            cpu.execute(&lue);
            if cpu.faulted {
                return Err("l'interpréteur a fauté".into());
            }
        }
    } else {
        let lue = decode_extended(instruction).ok_or("illisible pour les deux décodeurs")?;
        *ici += lue.length;
        cpu.execute_extended(&lue)
            .map_err(|faute| format!("{faute:?}"))?;
    }
    Ok(())
}

/// SplitMix64.
struct Hasard(u64);

impl Hasard {
    fn next(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^ (z >> 31)
    }

    /// Un mot aux bords une fois sur quatre : zéro, tout à un, les signes.
    fn mot(&mut self) -> u64 {
        match self.next() % 8 {
            0 => 0,
            1 => u64::MAX,
            2 => 0x8000_8000_8000_8000,
            3 => 0x7F7F_8080_00FF_FF00,
            _ => self.next(),
        }
    }

    fn etat(&mut self) -> Etat {
        let mut memoire = [0u8; 16];
        memoire[..8].copy_from_slice(&self.mot().to_le_bytes());
        memoire[8..].copy_from_slice(&self.mot().to_le_bytes());
        Etat {
            xmm: [
                [self.mot(), self.mot()],
                [self.mot(), self.mot()],
                [self.mot(), self.mot()],
            ],
            rax: self.mot(),
            rcx: self.mot(),
            rdx: self.mot(),
            entree: 0x2 | (self.next() & DRAPEAUX),
            sortie: 0,
            _bourrage: 0,
            memoire,
        }
    }
}

/// **Juger une forme** : `tirages` états, le silicium contre l'interpréteur.
fn juger(nom: &str, instruction: &[u8], tirages: usize) {
    juger_avec(nom, instruction, tirages, |etat| etat);
}

/// **Un NaN de simple précision vaut n'importe quel autre**, dans XMM0 : pour
/// `dpps`, dont le NaN rendu dépend du modèle de processeur quand il y en a
/// des deux côtés de la somme (un Xeon et le processeur de la CI ne
/// s'accordent pas). Qu'il y ait un NaN, et où, se juge toujours.
fn nan_quelconque(mut etat: Etat) -> Etat {
    for moitie in &mut etat.xmm[0] {
        let mut mot = *moitie;
        for voie in 0..2 {
            let bits = (mot >> (32 * voie)) as u32;
            if bits & 0x7F80_0000 == 0x7F80_0000 && bits & 0x007F_FFFF != 0 {
                mot = (mot & !(0xFFFF_FFFFu64 << (32 * voie))) | (0x7FC0_0000u64 << (32 * voie));
            }
        }
        *moitie = mot;
    }
    etat
}

fn juger_avec(nom: &str, instruction: &[u8], tirages: usize, normaliser: fn(Etat) -> Etat) {
    let mut hasard = Hasard(
        instruction
            .iter()
            .fold(0x5EED, |h, &o| h * 31 + u64::from(o)),
    );
    for tirage in 0..tirages {
        let depart = hasard.etat();
        let mut attendu = depart;
        silicium(instruction, &mut attendu);
        let mut obtenu = depart;
        if let Err(pourquoi) = interprete(instruction, &mut obtenu) {
            panic!("{nom} ({instruction:02x?}) : {pourquoi}");
        }
        attendu.sortie &= DRAPEAUX;
        obtenu.sortie &= DRAPEAUX;
        assert_eq!(
            normaliser(obtenu),
            normaliser(attendu),
            "{nom} ({instruction:02x?}), tirage {tirage}, depuis {depart:x?}"
        );
    }
}

fn hote_v2() -> bool {
    std::is_x86_feature_detected!("sse4.2") && std::is_x86_feature_detected!("popcnt")
}

/// **Les formes entières**, registre et mémoire : SSSE3 et SSE4.1.
#[test]
fn integer_forms_match_the_silicon() {
    if !hote_v2() {
        return;
    }
    // (nom, opcode de 0F 38) : xmm1 → xmm0, puis (%rsi) → xmm0.
    for (nom, opcode) in [
        ("pshufb", 0x00u8),
        ("phaddw", 0x01),
        ("phaddd", 0x02),
        ("phaddsw", 0x03),
        ("pmaddubsw", 0x04),
        ("phsubw", 0x05),
        ("phsubd", 0x06),
        ("phsubsw", 0x07),
        ("psignb", 0x08),
        ("psignw", 0x09),
        ("psignd", 0x0A),
        ("pmulhrsw", 0x0B),
        ("pblendvb", 0x10),
        ("blendvps", 0x14),
        ("blendvpd", 0x15),
        ("ptest", 0x17),
        ("pabsb", 0x1C),
        ("pabsw", 0x1D),
        ("pabsd", 0x1E),
        ("pmovsxbw", 0x20),
        ("pmovsxbd", 0x21),
        ("pmovsxbq", 0x22),
        ("pmovsxwd", 0x23),
        ("pmovsxwq", 0x24),
        ("pmovsxdq", 0x25),
        ("pmuldq", 0x28),
        ("pcmpeqq", 0x29),
        ("packusdw", 0x2B),
        ("pmovzxbw", 0x30),
        ("pmovzxbd", 0x31),
        ("pmovzxbq", 0x32),
        ("pmovzxwd", 0x33),
        ("pmovzxwq", 0x34),
        ("pmovzxdq", 0x35),
        ("pcmpgtq", 0x37),
        ("pminsb", 0x38),
        ("pminsd", 0x39),
        ("pminuw", 0x3A),
        ("pminud", 0x3B),
        ("pmaxsb", 0x3C),
        ("pmaxsd", 0x3D),
        ("pmaxuw", 0x3E),
        ("pmaxud", 0x3F),
        ("pmulld", 0x40),
        ("phminposuw", 0x41),
    ] {
        juger(nom, &[0x66, 0x0F, 0x38, opcode, 0xC1], 400);
        juger(
            &format!("{nom} (mémoire)"),
            &[0x66, 0x0F, 0x38, opcode, 0x06],
            400,
        );
    }
    juger("movntdqa", &[0x66, 0x0F, 0x38, 0x2A, 0x06], 50);
}

/// **Les formes à immédiat** de 0F 3A, sur quelques immédiats chacune.
#[test]
fn immediate_forms_match_the_silicon() {
    if !hote_v2() {
        return;
    }
    for imm in [0x00u8, 0x01, 0x05, 0x0A, 0x55, 0xA3, 0xFF, 0x0F, 0x10, 0x1F] {
        for (nom, opcode) in [
            ("blendps", 0x0Cu8),
            ("blendpd", 0x0D),
            ("pblendw", 0x0E),
            ("palignr", 0x0F),
            ("insertps", 0x21),
            ("mpsadbw", 0x42),
        ] {
            juger(nom, &[0x66, 0x0F, 0x3A, opcode, 0xC1, imm], 60);
            juger(nom, &[0x66, 0x0F, 0x3A, opcode, 0x06, imm], 60);
        }
        // Les extractions vers RAX et les insertions depuis RCX.
        let lane = imm & 0x0F;
        juger("pextrb", &[0x66, 0x0F, 0x3A, 0x14, 0xC0, lane], 30);
        juger(
            "pextrb (mémoire)",
            &[0x66, 0x0F, 0x3A, 0x14, 0x06, lane],
            30,
        );
        juger(
            "pextrw (mémoire)",
            &[0x66, 0x0F, 0x3A, 0x15, 0x06, lane],
            30,
        );
        juger("pextrd", &[0x66, 0x0F, 0x3A, 0x16, 0xC0, lane], 30);
        juger("pextrq", &[0x66, 0x48, 0x0F, 0x3A, 0x16, 0xC0, lane], 30);
        juger("extractps", &[0x66, 0x0F, 0x3A, 0x17, 0xC0, lane], 30);
        juger(
            "extractps (mémoire)",
            &[0x66, 0x0F, 0x3A, 0x17, 0x06, lane],
            30,
        );
        juger("pinsrb", &[0x66, 0x0F, 0x3A, 0x20, 0xC1, lane], 30);
        juger(
            "pinsrb (mémoire)",
            &[0x66, 0x0F, 0x3A, 0x20, 0x06, lane],
            30,
        );
        juger("pinsrd", &[0x66, 0x0F, 0x3A, 0x22, 0xC1, lane], 30);
        juger("pinsrq", &[0x66, 0x48, 0x0F, 0x3A, 0x22, 0xC1, lane], 30);
        juger(
            "pinsrq (mémoire)",
            &[0x66, 0x48, 0x0F, 0x3A, 0x22, 0x06, lane],
            30,
        );
    }
}

/// **`crc32`**, `lahf` et `sahf`, et les copies de SSE3.
#[test]
fn crc_flags_and_sse3_moves_match_the_silicon() {
    if !hote_v2() {
        return;
    }
    juger("crc32b", &[0xF2, 0x0F, 0x38, 0xF0, 0xC1], 300);
    juger("crc32b (mémoire)", &[0xF2, 0x0F, 0x38, 0xF0, 0x06], 300);
    juger("crc32w", &[0x66, 0xF2, 0x0F, 0x38, 0xF1, 0xC1], 300);
    juger("crc32l", &[0xF2, 0x0F, 0x38, 0xF1, 0xC1], 300);
    juger("crc32l (mémoire)", &[0xF2, 0x0F, 0x38, 0xF1, 0x06], 300);
    juger("crc32q", &[0xF2, 0x48, 0x0F, 0x38, 0xF1, 0xC1], 300);
    juger(
        "crc32q (mémoire)",
        &[0xF2, 0x48, 0x0F, 0x38, 0xF1, 0x06],
        300,
    );
    juger("lahf", &[0x9F], 100);
    juger("sahf", &[0x9E], 100);
    juger("movddup", &[0xF2, 0x0F, 0x12, 0xC1], 50);
    juger("movddup (mémoire)", &[0xF2, 0x0F, 0x12, 0x06], 50);
    juger("movsldup", &[0xF3, 0x0F, 0x12, 0xC1], 50);
    juger("movshdup", &[0xF3, 0x0F, 0x16, 0x06], 50);
    juger("lddqu", &[0xF2, 0x0F, 0xF0, 0x06], 50);
}

/// **Les comparaisons de chaînes** de SSE4.2, sur tous les modes.
#[test]
fn string_comparisons_match_the_silicon() {
    if !hote_v2() {
        return;
    }
    for imm in 0..=0x7Fu8 {
        for (nom, opcode) in [
            ("pcmpestrm", 0x60u8),
            ("pcmpestri", 0x61),
            ("pcmpistrm", 0x62),
            ("pcmpistri", 0x63),
        ] {
            juger(nom, &[0x66, 0x0F, 0x3A, opcode, 0xC1, imm], 12);
            juger(nom, &[0x66, 0x0F, 0x3A, opcode, 0x06, imm], 12);
        }
    }
}

/// **Le banc lui-même** : sur des formes de SSE2 que l'interpréteur exécute
/// déjà et que les corpus jugent, le silicium et lui s'accordent. Sans ce
/// test, un banc qui ne compare rien passerait pour un accord.
#[test]
fn the_bench_agrees_on_what_was_already_there() {
    juger("paddd", &[0x66, 0x0F, 0xFE, 0xC1], 100);
    juger("pxor (mémoire)", &[0x66, 0x0F, 0xEF, 0x06], 100);
    juger("add %rcx,%rax", &[0x48, 0x01, 0xC8], 100);
    juger("movdqa %xmm0,(%rsi)", &[0x66, 0x0F, 0x7F, 0x06], 20);
}

/// **Les formes flottantes** : SSE3 (`addsub`, `hadd`, `hsub`), l'arrondi à
/// l'entier et le produit scalaire de SSE4.1, MXCSR à 0x1F80 des deux côtés.
#[test]
fn float_forms_match_the_silicon() {
    if !hote_v2() {
        return;
    }
    for (nom, octets) in [
        ("addsubps", [0xF2u8, 0x0F, 0xD0]),
        ("addsubpd", [0x66, 0x0F, 0xD0]),
        ("haddps", [0xF2, 0x0F, 0x7C]),
        ("haddpd", [0x66, 0x0F, 0x7C]),
        ("hsubps", [0xF2, 0x0F, 0x7D]),
        ("hsubpd", [0x66, 0x0F, 0x7D]),
    ] {
        juger(nom, &[&octets[..], &[0xC1]].concat(), 400);
        juger(nom, &[&octets[..], &[0x06]].concat(), 400);
    }
    for imm in 0..16u8 {
        for (nom, opcode) in [
            ("roundps", 0x08u8),
            ("roundpd", 0x09),
            ("roundss", 0x0A),
            ("roundsd", 0x0B),
        ] {
            juger(nom, &[0x66, 0x0F, 0x3A, opcode, 0xC1, imm], 100);
            juger(nom, &[0x66, 0x0F, 0x3A, opcode, 0x06, imm], 100);
        }
    }
    for imm in [0xFFu8, 0xF1, 0x31, 0x5A, 0xA5, 0x0F, 0xF0, 0x33, 0xCC, 0x7E] {
        juger_avec(
            "dpps",
            &[0x66, 0x0F, 0x3A, 0x40, 0xC1, imm],
            100,
            nan_quelconque,
        );
        juger_avec(
            "dpps (mémoire)",
            &[0x66, 0x0F, 0x3A, 0x40, 0x06, imm],
            100,
            nan_quelconque,
        );
        juger("dppd", &[0x66, 0x0F, 0x3A, 0x41, 0xC1, imm], 100);
    }
}

/// **`fisttp`** (SSE3) : `fldl (%rsi)` puis la troncature vers 16, 32 et
/// 64 bits, rangée huit octets plus loin. Le mode d'arrondi du mot de
/// contrôle (au plus proche) ne doit rien y changer.
#[test]
fn fisttp_matches_the_silicon() {
    if !hote_v2() {
        return;
    }
    juger("fisttps", &[0xDD, 0x06, 0xDF, 0x4E, 0x08], 400);
    juger("fisttpl", &[0xDD, 0x06, 0xDB, 0x4E, 0x08], 400);
    juger("fisttpll", &[0xDD, 0x06, 0xDD, 0x4E, 0x08], 400);
}

/// **`bnd`** (`f2` devant un branchement proche) : le préfixe de MPX, qu'un
/// processeur sans MPX ignore. La glibc de RHEL 9 en met devant les sauts de
/// sa PLT. Les sauts de déplacement nul vont à l'instruction d'après, ce que
/// le banc sait exécuter ; `bnd jmp *` se juge par sa longueur.
#[test]
fn bnd_prefixed_branches_are_branches() {
    if !hote_v2() {
        return;
    }
    juger("bnd jmp", &[0xF2, 0xEB, 0x00], 20);
    juger("bnd jz", &[0xF2, 0x74, 0x00], 50);
    juger(
        "bnd jnz rel32",
        &[0xF2, 0x0F, 0x85, 0x00, 0x00, 0x00, 0x00],
        50,
    );
    let indirect = decode(&[0xF2, 0xFF, 0x25, 0xD5, 0x2A, 0x1D, 0x00]).expect("bnd jmp *");
    assert_eq!((indirect.op, indirect.length), (Op::JumpIndirect, 7));
    assert!(
        decode(&[0xF2, 0xFF, 0xC0]).is_none(),
        "`f2` devant `inc` reste refusé"
    );
}

/// **Les rangements non temporels** rangent comme les autres, au bit près du
/// silicium — et l'émetteur les traduit : il les rendait au secours un par
/// un, et le banc RAID du noyau de Void, qui les enchaîne pendant seize tics
/// d'horloge, ne finissait jamais.
#[test]
fn non_temporal_stores_store_and_the_emitter_translates_them() {
    for (nom, octets) in [
        ("movntdq", &[0x66, 0x0F, 0xE7, 0x06][..]),
        ("movntps", &[0x0F, 0x2B, 0x0E]),
        ("movntpd", &[0x66, 0x0F, 0x2B, 0x16]),
        ("movnti", &[0x0F, 0xC3, 0x06]),
        ("movnti 64", &[0x48, 0x0F, 0xC3, 0x0E]),
    ] {
        let lue = decode(octets).unwrap_or_else(|| panic!("{nom} se décode"));
        assert_eq!(lue.length, octets.len(), "{nom} : la longueur");
        let mut region = octets.to_vec();
        region.push(0xC3);
        assert!(
            wisq_vm::x86_wasm::Module::region_or_why(&region, 0x40_0000, 0).is_ok(),
            "{nom} : l'émetteur le traduit"
        );
        if hote_v2() {
            juger(nom, octets, 50);
        }
    }
    assert!(
        decode(&[0x66, 0x0F, 0xE7, 0xC1]).is_none(),
        "la forme registre reste refusée"
    );
}
