//! **Le second décodeur — celui de la machine PC native — jugé par le
//! silicium.**
//!
//! `x86_extended.rs` lit ce que `decode` refuse et que la machine exécute
//! quand même. Ces formes sont portées par `x86-x87-oracle.tsv` (les
//! chargements d'entiers et les mots du x87) et par `x86-fxsave-oracle.tsv`
//! (ce que `fxrstor` puis `fxsave` font d'une aire), relevés sur le silicium.
//! Seules les formes que le décodeur lit sont jugées, et leur compte est
//! tenu : une forme qui cesserait d'être lue ferait tomber le test.

use std::collections::HashMap;
use std::path::PathBuf;

use wisq_vm::x86::{
    decode, decode_extended, Cpu, ExtendedFault, Extra, GuestMemory, Width, FXSAVE_WRITTEN,
};

const DATA: u64 = 0x3000_1000;
const CODE: u64 = 0x3000_0000;

fn fixture(name: &str) -> String {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../Tests/Fixtures")
        .join(name);
    std::fs::read_to_string(path).expect("l'oracle matériel doit être lisible")
}

fn hex(text: &str) -> u64 {
    u64::from_str_radix(text, 16).expect("un nombre hexadécimal du corpus")
}

fn bytes(text: &str) -> Vec<u8> {
    (0..text.len() / 2)
        .map(|at| u8::from_str_radix(&text[2 * at..2 * at + 2], 16).expect("un octet du corpus"))
        .collect()
}

/// Un registre du x87 : la mantisse, puis le signe et l'exposant.
type Register = (u64, u16);

/// Un registre du x87, des vingt chiffres du corpus : dix octets
/// petit-boutistes, la mantisse puis le signe et l'exposant.
fn register(text: &str) -> Register {
    let raw = bytes(text);
    (
        u64::from_le_bytes(raw[..8].try_into().unwrap()),
        u16::from_le_bytes([raw[8], raw[9]]),
    )
}

/// Un processeur dans l'état de départ du corpus x87 : le sommet à six, le mot
/// de contrôle à 0x37f, ST(0) et ST(1) posés, RSI sur la fenêtre.
fn x87_start(st0: (u64, u16), st1: (u64, u16)) -> Cpu {
    let mut ram = vec![0u8; 0x2000];
    for (index, byte) in ram[0x1000..0x1040].iter_mut().enumerate() {
        *byte = 0x10 + index as u8;
    }
    let mut cpu = Cpu {
        rip: CODE,
        memory: GuestMemory {
            base: CODE,
            bytes: ram,
        },
        fpu_control: 0x037f,
        fpu_status: 6 << 11,
        fpu_tags: 0b1100_0000,
        mxcsr: 0x1f80,
        ..Default::default()
    };
    cpu.x87[6] = st0;
    cpu.x87[7] = st1;
    for (index, register) in cpu.regs.iter_mut().enumerate() {
        *register = 0xAAAA_AAAA_AAAA_AAAA + index as u64;
    }
    cpu.regs[6] = DATA;
    cpu.flags.write(2);
    cpu
}

#[test]
fn the_x87_forms_the_machine_reads_match_the_silicon() {
    let text = fixture("x86-x87-oracle.tsv");
    let mut states: HashMap<&str, [Register; 2]> = HashMap::new();
    let mut instructions: HashMap<&str, (Vec<u8>, &str)> = HashMap::new();
    let mut judged: HashMap<&str, usize> = HashMap::new();
    let mut wrong = Vec::new();
    let pristine: String = (0x10u8..0x50).map(|byte| format!("{byte:02x}")).collect();
    for line in text.lines() {
        let f: Vec<&str> = line.split('\t').collect();
        match f[0] {
            "état" => {
                states.insert(f[1], [register(f[4]), register(f[5])]);
            }
            "instr" => {
                instructions.insert(f[1], (bytes(f[2]), f[3]));
            }
            "cas" => {
                let (code, mnemonic) = &instructions[f[1]];
                // Une forme que `decode` lit n'est pas à ce décodeur ; une
                // forme qu'aucun ne lit n'est pas jugée ici.
                if decode(code).is_some() {
                    continue;
                }
                let Some(decoded) = decode_extended(code) else {
                    continue;
                };
                assert_eq!(decoded.length, code.len(), "{mnemonic} : la longueur");
                let [st0, st1] = states[f[2]];
                let mut cpu = x87_start(st0, st1);
                let outcome = cpu.execute_extended(&decoded);
                *judged.entry(mnemonic).or_default() += 1;
                let mut differences = Vec::new();
                if outcome.is_err() || cpu.faulted {
                    differences.push(format!("n'est pas allée au bout : {outcome:?}"));
                }
                let top = cpu.x87_top();
                for (label, value, wanted) in [
                    ("sommet", top as u64, hex(f[3])),
                    ("mot d'état", u64::from(cpu.fpu_status), hex(f[4])),
                    ("étiquettes", u64::from(cpu.x87_tag_word()), hex(f[5])),
                    ("rax", cpu.regs[0], hex(f[14])),
                    ("drapeaux", cpu.flags.read() & 0x8d5, hex(f[15])),
                    ("rsi", cpu.regs[6], DATA),
                ] {
                    if value != wanted {
                        differences.push(format!("{label} {value:x} au lieu de {wanted:x}"));
                    }
                }
                // Les huit registres, dans l'ordre de la pile.
                for index in 0..8 {
                    let got = cpu.x87[(top + index) & 7];
                    let wanted = register(f[6 + index]);
                    if got != wanted {
                        differences.push(format!("ST({index}) {got:x?} au lieu de {wanted:x?}"));
                    }
                }
                let after: String = cpu.memory.bytes[0x1000..0x1040]
                    .iter()
                    .map(|byte| format!("{byte:02x}"))
                    .collect();
                let wanted = if f[16] == "-" {
                    pristine.as_str()
                } else {
                    f[16]
                };
                if after != wanted {
                    differences.push(format!("mémoire {after} au lieu de {wanted}"));
                }
                if !differences.is_empty() {
                    wrong.push(format!(
                        "{mnemonic}, état {} : {}",
                        f[2],
                        differences.join(" ; ")
                    ));
                }
            }
            _ => {}
        }
    }
    assert!(
        wrong.is_empty(),
        "{} écarts :\n{}",
        wrong.len(),
        wrong
            .iter()
            .take(30)
            .cloned()
            .collect::<Vec<_>>()
            .join("\n")
    );
    // **Les 121 formes du corpus, et ses 7 260 cas** : depuis que le x87
    // calcule, aucune n'est laissée de côté. Il n'en jugeait que neuf (`fild`
    // aux trois largeurs et à deux adresses, `fnstsw %ax`, `fnstcw`, `fldcw`).
    assert_eq!(judged.len(), 121, "toutes les formes du corpus");
    assert_eq!(judged.values().sum::<usize>(), 7260);
}

/// **`fxrstor` puis `fxsave`, contre ce que le silicium a rendu** : 280 aires.
/// Les 416 premiers octets sont comparés ; les quatre-vingt-seize derniers
/// doivent rester ce qu'ils étaient.
#[test]
fn fxrstor_then_fxsave_gives_back_what_the_silicon_gives_back() {
    let fxrstor = decode(&[0x0f, 0xae, 0x0e]).expect("fxrstor (%rsi)");
    let fxsave = decode(&[0x0f, 0xae, 0x06]).expect("fxsave (%rsi)");
    assert_eq!((fxrstor.length, fxsave.length), (3, 3));
    let mut cases = 0;
    for line in fixture("x86-fxsave-oracle.tsv").lines() {
        let f: Vec<&str> = line.split('\t').collect();
        if f[0] != "cas" {
            continue;
        }
        let (input, wanted) = (bytes(f[2]), bytes(f[3]));
        assert_eq!((input.len(), wanted.len()), (512, FXSAVE_WRITTEN));
        let mut ram = vec![0u8; 0x1000];
        ram[..512].copy_from_slice(&input);
        let mut cpu = Cpu {
            memory: GuestMemory {
                base: DATA,
                bytes: ram,
            },
            ..Default::default()
        };
        assert_eq!(
            cpu.restore_floating_point_state(DATA),
            Ok(()),
            "cas {}",
            f[1]
        );
        cpu.memory.bytes[..512].fill(0xCC);
        assert_eq!(cpu.save_floating_point_state(DATA), Ok(()), "cas {}", f[1]);
        assert_eq!(
            &cpu.memory.bytes[..FXSAVE_WRITTEN],
            &wanted[..],
            "cas {} : les 416 octets écrits",
            f[1]
        );
        assert!(
            cpu.memory.bytes[FXSAVE_WRITTEN..512]
                .iter()
                .all(|byte| *byte == 0xCC),
            "cas {} : les quatre-vingt-seize derniers octets ne sont pas écrits",
            f[1]
        );
        cases += 1;
    }
    assert_eq!(cases, 280, "tous les cas du corpus doivent être jugés");
}

/// Une aire de `fxsave` porte tout l'état : les XMM, MXCSR, les registres du
/// x87 dans l'ordre de la pile et leurs étiquettes.
#[test]
fn the_fxsave_area_carries_the_whole_state_at_its_offsets() {
    let mut cpu = Cpu {
        memory: GuestMemory {
            base: DATA,
            bytes: vec![0xEE; 0x1000],
        },
        fpu_control: 0x037f,
        mxcsr: 0x1fa0,
        ..Default::default()
    };
    cpu.x87_push(Cpu::x87_from_integer(-3));
    cpu.x87_push(Cpu::x87_from_integer(1));
    for (index, register) in cpu.xmm.iter_mut().enumerate() {
        *register = [0x1000 + index as u64, 0x2000 + index as u64];
    }
    assert_eq!(cpu.save_floating_point_state(DATA + 16), Ok(()));
    let area = &cpu.memory.bytes[16..16 + 512];
    assert_eq!(&area[0..2], &[0x7f, 0x03], "le mot de contrôle");
    assert_eq!(
        &area[2..4],
        &(6u16 << 11).to_le_bytes(),
        "le sommet, à six après deux empilements"
    );
    assert_eq!(
        area[4], 0b1100_0000,
        "les étiquettes abrégées : les registres 6 et 7"
    );
    assert_eq!(
        &area[0x18..0x20],
        &[0xa0, 0x1f, 0, 0, 0xff, 0xff, 0, 0],
        "MXCSR et son masque"
    );
    // ST(0) = 1.0, ST(1) = -3.0 : l'ordre de la pile, pas celui des registres.
    assert_eq!(&area[0x20..0x2a], &[0, 0, 0, 0, 0, 0, 0, 0x80, 0xff, 0x3f]);
    assert_eq!(&area[0x30..0x3a], &[0, 0, 0, 0, 0, 0, 0, 0xc0, 0x00, 0xc0]);
    assert_eq!(&area[0xa0..0xa8], &0x1000u64.to_le_bytes(), "XMM0 bas");
    assert_eq!(&area[0x198..0x1a0], &0x200fu64.to_le_bytes(), "XMM15 haut");
    assert!(area[416..].iter().all(|byte| *byte == 0xEE));
    assert_eq!(cpu.memory.bytes[15], 0xEE, "rien avant l'aire");
}

/// Un MXCSR aux bits réservés levés : `#GP(0)`, et rien n'est restauré. Une
/// aire qui sort de la mémoire : une faute, et rien n'est écrit.
#[test]
fn a_bad_area_changes_nothing() {
    let mut cpu = Cpu {
        memory: GuestMemory {
            base: DATA,
            bytes: vec![0u8; 0x1000],
        },
        fpu_control: 0x037f,
        mxcsr: 0x1f80,
        ..Default::default()
    };
    cpu.xmm[3] = [7, 9];
    cpu.memory.bytes[0x18..0x1c].copy_from_slice(&0x0002_0000u32.to_le_bytes());
    cpu.memory.bytes[0] = 0x55;
    assert_eq!(
        cpu.restore_floating_point_state(DATA),
        Err(ExtendedFault::ReservedControl)
    );
    assert_eq!(
        (cpu.fpu_control, cpu.mxcsr, cpu.xmm[3]),
        (0x037f, 0x1f80, [7, 9])
    );
    // L'aire entière doit être accessible : 512 octets, même si 416 seulement
    // sont écrits. Posée à 448 octets de la fin, elle faute et n'écrit rien.
    cpu.memory.bytes.fill(0x11);
    assert_eq!(
        cpu.save_floating_point_state(DATA + 0x1000 - 448),
        Err(ExtendedFault::Memory)
    );
    assert!(cpu.faulted);
    assert!(cpu.memory.bytes.iter().all(|byte| *byte == 0x11));
    cpu.faulted = false;
    assert_eq!(
        cpu.restore_floating_point_state(DATA + 0x1000 - 448),
        Err(ExtendedFault::Memory)
    );
}

/// **Le second décodeur ne lit que ce qu'il nomme.** Chaque instruction du
/// x87 a sa longueur et sa forme ; les octets que le manuel ne nomme pas —
/// les alias non documentés, les champs mémoire réservés — restent
/// illisibles, comme `f2`/`f3` devant le x87 et les formes de SSE3 (`fisttp`
/// compris) et de SSSE3.
#[test]
fn the_extended_decoder_reads_exactly_its_forms() {
    let read =
        |code: &[u8]| decode_extended(code).map(|instruction| (instruction.op, instruction.length));
    let x87 = |opcode: u8, modrm: u8| Extra::X87 { opcode, modrm };
    assert_eq!(
        read(&[0xd9, 0x7c, 0x24, 0x0c]),
        Some((x87(0xd9, 0x7c), 4)),
        "fnstcw 0xc(%rsp), le premier mur du décompresseur"
    );
    assert_eq!(read(&[0xdd, 0x7c, 0x24, 0x0e]), Some((x87(0xdd, 0x7c), 4)));
    assert_eq!(read(&[0xd9, 0x2e]), Some((x87(0xd9, 0x2e), 2)));
    assert_eq!(read(&[0xdf, 0xe0]), Some((x87(0xdf, 0xe0), 2)));
    assert_eq!(read(&[0xdb, 0xe2]), Some((x87(0xdb, 0xe2), 2)));
    assert_eq!(read(&[0x0f, 0x77]), Some((Extra::Emms, 2)));
    assert_eq!(
        read(&[0xdb, 0x07]),
        Some((x87(0xdb, 0x07), 2)),
        "fildl (%rdi)"
    );
    // Les calculs que ce décodeur refusait jusqu'ici.
    for (name, code) in [
        ("fld m32", &[0xd9, 0x06][..]),
        ("fstp m32", &[0xd9, 0x1e]),
        ("fldl m64", &[0xdd, 0x06]),
        ("fistpl", &[0xdb, 0x1e]),
        ("fld m80", &[0xdb, 0x2e]),
        ("fbld", &[0xdf, 0x26]),
        ("fistpll", &[0xdf, 0x3e]),
        ("fld1", &[0xd9, 0xe8]),
        ("fsin", &[0xd9, 0xfe]),
        ("fnsave", &[0xdd, 0x36]),
        ("fnstsw %ax précédé de 66", &[0x66, 0xdf, 0xe0]),
        ("fld avec REX.B", &[0x41, 0xd9, 0x00]),
    ] {
        let decoded = decode_extended(code).unwrap_or_else(|| panic!("{name} se lit"));
        assert_eq!(decoded.length, code.len(), "{name} : la longueur");
    }
    // `66` devant le x87 : les environnements de quatorze octets.
    assert_eq!(
        decode_extended(&[0x66, 0xd9, 0x36]).map(|instruction| instruction.width),
        Some(Width::Word)
    );
    for (name, code) in [
        ("d9 /1 en mémoire", &[0xd9, 0x0e][..]),
        ("db /4 en mémoire", &[0xdb, 0x26]),
        ("db /6 en mémoire", &[0xdb, 0x36]),
        ("dd /5 en mémoire", &[0xdd, 0x2e]),
        ("d9 d1, un alias", &[0xd9, 0xd1]),
        ("d9 e2", &[0xd9, 0xe2]),
        ("dc d0, l'alias de fcom", &[0xdc, 0xd0]),
        ("de d1, l'alias de fcomp", &[0xde, 0xd1]),
        ("df c8, l'alias de fxch", &[0xdf, 0xc8]),
        ("dd c8, l'alias de fxch", &[0xdd, 0xc8]),
        ("da c0 n'est pas da e8", &[0xda, 0xe8]),
        ("f3 devant le x87", &[0xf3, 0xd9, 0xe8]),
        ("emms précédé de f3", &[0xf3, 0x0f, 0x77]),
        ("femms", &[0x0f, 0x0e]),
        ("fnstcw à adresse de 32 bits", &[0x67, 0xd9, 0x38]),
        ("fisttpl, du SSE3", &[0xdb, 0x0e]),
        ("fisttpll, du SSE3", &[0xdd, 0x0e]),
        ("fisttps, du SSE3", &[0xdf, 0x0e]),
        ("fnstcw coupé", &[0xd9, 0x7c, 0x24]),
        ("haddps, du SSE3", &[0xf2, 0x0f, 0x7c, 0xc1]),
        ("pshufb, du SSSE3", &[0x0f, 0x38, 0x00, 0xc1]),
        (
            "deux préfixes obligatoires",
            &[0x66, 0xf3, 0x0f, 0x58, 0xc1],
        ),
        ("movntq vers un registre", &[0x0f, 0xe7, 0xc1]),
    ] {
        assert_eq!(decode_extended(code), None, "{name} doit rester illisible");
    }
    // Et ce que `decode` lit déjà n'est pas à lui : `fninit` reste au premier,
    // même si le second sait aussi le faire.
    assert!(decode(&[0xdb, 0xe3]).is_some());
}

/// `fnclex` efface les exceptions en attente et garde le sommet ; `emms` vide
/// les étiquettes et rien d'autre ; un empilement sur une pile pleine le dit
/// dans le mot d'état.
#[test]
fn the_x87_words_follow_the_manual_where_the_corpus_is_silent() {
    let mut cpu = x87_start((0, 0), (0, 0));
    cpu.fpu_status |= 0x80ff;
    cpu.execute_extended(&decode_extended(&[0xdb, 0xe2]).unwrap())
        .unwrap();
    assert_eq!(
        cpu.fpu_status,
        6 << 11,
        "les exceptions et « occupé » effacés, le sommet gardé"
    );
    cpu.execute_extended(&decode_extended(&[0x0f, 0x77]).unwrap())
        .unwrap();
    assert_eq!(cpu.fpu_tags, 0);
    assert_eq!(cpu.x87_tag_word(), 0xffff, "tout est vide");
    assert_eq!(cpu.x87_top(), 6, "emms ne touche pas au sommet");
    // Huit empilements remplissent la pile ; le neuvième déborde.
    for value in 1..=8 {
        cpu.x87_push(Cpu::x87_from_integer(value));
    }
    assert_eq!(cpu.fpu_tags, 0xff);
    assert_eq!(cpu.fpu_status & 0x0241, 0, "pas encore de débordement");
    cpu.x87_push(Cpu::x87_from_integer(9));
    assert_eq!(
        cpu.fpu_status & 0x0241,
        0x0241,
        "invalide, faute de pile, C1"
    );
    assert_eq!(
        cpu.x87[cpu.x87_top()],
        (0xC000_0000_0000_0000, 0xFFFF),
        "le NaN indéfini"
    );
    // Les conversions d'entiers sont exactes.
    assert_eq!(Cpu::x87_from_integer(0), (0, 0));
    assert_eq!(Cpu::x87_from_integer(1), (1 << 63, 0x3fff));
    assert_eq!(Cpu::x87_from_integer(-1), (1 << 63, 0xbfff));
    assert_eq!(Cpu::x87_from_integer(i64::MIN), (1 << 63, 0xc03e));
    assert_eq!(Cpu::x87_from_integer(i64::MAX), (u64::MAX << 1, 0x403d));
}

/// **`fild` étend le signe de ce qu'il lit.** Le corpus ne charge que des
/// octets de 0x10 à 0x4f : aucun entier de seize ou de trente-deux bits n'y a
/// son bit de tête levé, et un `fild` qui prendrait 0xffff pour 65 535 passait.
///
/// Les valeurs attendues sont celles de l'arithmétique — un registre du x87
/// est une mantisse de soixante-quatre bits au bit de tête explicite, et un
/// exposant biaisé de 16 383 sous le signe — et, sur un hôte x86-64, le
/// silicium est interrogé pour chacune.
#[test]
fn fild_extends_the_sign_of_what_it_reads() {
    // (octets de ModRM derrière l'opcode, largeur, octets lus, ST(0) attendu)
    let cases: [(&[u8], Width, u64, Register); 9] = [
        // -1, aux trois largeurs : 1 × 2^0, négatif.
        (&[0xdf, 0x06], Width::Word, 0xFFFF, (1 << 63, 0xBFFF)),
        (&[0xdb, 0x06], Width::Dword, 0xFFFF_FFFF, (1 << 63, 0xBFFF)),
        (&[0xdf, 0x2e], Width::Qword, u64::MAX, (1 << 63, 0xBFFF)),
        // Le plus petit de chaque largeur : 2^15, 2^31, 2^63, négatifs.
        (&[0xdf, 0x06], Width::Word, 0x8000, (1 << 63, 0xC00E)),
        (&[0xdb, 0x06], Width::Dword, 0x8000_0000, (1 << 63, 0xC01E)),
        (&[0xdf, 0x2e], Width::Qword, 1 << 63, (1 << 63, 0xC03E)),
        // -3 sur seize bits : 1,1 en binaire × 2^1.
        (&[0xdf, 0x06], Width::Word, 0xFFFD, (0xC << 60, 0xC000)),
        // Et le plus grand positif reste positif : 2^15 - 1, 2^31 - 1.
        (&[0xdf, 0x06], Width::Word, 0x7FFF, (0xFFFE << 48, 0x400D)),
        (
            &[0xdb, 0x06],
            Width::Dword,
            0x7FFF_FFFF,
            (0xFFFF_FFFE << 32, 0x401D),
        ),
    ];
    for (code, width, raw, wanted) in cases {
        let decoded = decode_extended(code).expect("fild (%rsi)");
        // La largeur est dans l'opcode et le champ `reg` : c'est la valeur
        // empilée, plus bas, qui dit combien d'octets ont été lus.
        assert_eq!(
            decoded.op,
            Extra::X87 {
                opcode: code[0],
                modrm: code[1]
            }
        );
        let mut cpu = x87_start((0, 0), (0, 0));
        // Les octets au-delà de la largeur sont à un : ils ne doivent pas
        // être lus.
        let mut window = [0xFFu8; 8];
        window[..width as usize].copy_from_slice(&raw.to_le_bytes()[..width as usize]);
        cpu.memory.bytes[0x1000..0x1008].copy_from_slice(&window);
        cpu.execute_extended(&decoded).expect("sans faute");
        let top = cpu.x87_top();
        assert_eq!(top, 5, "empilé sous le sommet de départ");
        assert_eq!(
            cpu.x87[top], wanted,
            "fild {width:?} de {raw:#x} : {:x?}",
            cpu.x87[top]
        );
        #[cfg(target_arch = "x86_64")]
        assert_eq!(
            silicon_fild(&window, width),
            wanted,
            "fild {width:?} de {raw:#x} : ce que rend le processeur de l'hôte"
        );
    }
}

/// `fild` puis `fstp` sur le processeur de l'hôte : les dix octets du
/// registre, tels que le silicium les range.
#[cfg(target_arch = "x86_64")]
fn silicon_fild(window: &[u8; 8], width: Width) -> Register {
    use std::arch::asm;
    let mut stored = [0u8; 16];
    macro_rules! load {
        ($fild:literal) => {
            // SAFETY: les deux pointeurs désignent des tampons vivants et
            // assez longs (huit octets lus au plus, dix écrits) ; la pile du
            // x87 est vide à l'entrée — la convention d'appel l'exige — et
            // `fstp` la rend vide.
            unsafe {
                asm!(
                    $fild,
                    "fstp tbyte ptr [{to}]",
                    from = in(reg) window.as_ptr(),
                    to = in(reg) stored.as_mut_ptr(),
                    out("st(0)") _, out("st(1)") _, out("st(2)") _, out("st(3)") _,
                    out("st(4)") _, out("st(5)") _, out("st(6)") _, out("st(7)") _,
                    options(nostack),
                )
            }
        };
    }
    match width {
        Width::Word => load!("fild word ptr [{from}]"),
        Width::Dword => load!("fild dword ptr [{from}]"),
        _ => load!("fild qword ptr [{from}]"),
    }
    (
        u64::from_le_bytes(stored[..8].try_into().unwrap()),
        u16::from_le_bytes([stored[8], stored[9]]),
    )
}

// ---- Le x87, le MMX et le flottant de SSE, là où le corpus se tait ----

/// Exécuter des octets sur un processeur, par le second décodeur.
fn run_extended(cpu: &mut Cpu, code: &[u8]) {
    let decoded = decode_extended(code).unwrap_or_else(|| panic!("{code:02x?} se lit"));
    assert_eq!(decoded.length, code.len(), "{code:02x?} : la longueur");
    cpu.execute_extended(&decoded).expect("sans faute");
}

const ONE: Register = (1 << 63, 0x3fff);
const INDEFINITE: Register = (0xC000_0000_0000_0000, 0xFFFF);

/// **Lire un registre vide est un débordement par le bas**, quelle que soit
/// l'instruction (le manuel ; le cœur Swift ne le faisait que pour `fxch`) :
/// invalide et faute de pile, C1 à zéro, et l'indéfini à la place de la
/// valeur — ou « non ordonné » pour une comparaison.
#[test]
fn reading_an_empty_register_is_a_stack_underflow() {
    // fadd %st(2),%st : ST(2) est vide.
    let mut cpu = x87_start(ONE, ONE);
    cpu.fpu_status |= 0x0200;
    run_extended(&mut cpu, &[0xd8, 0xc2]);
    assert_eq!(cpu.x87[6], INDEFINITE);
    assert_eq!(cpu.fpu_status & 0x47ff, 0x41, "IE et SF, C1 à zéro");
    // fcom %st(3) : C3, C2 et C0.
    let mut cpu = x87_start(ONE, ONE);
    run_extended(&mut cpu, &[0xd8, 0xd3]);
    assert_eq!(cpu.fpu_status & 0x47ff, 0x4541);
    // fistps 0x20(%rsi) d'une pile vide : l'entier indéfini.
    let mut cpu = x87_start(ONE, ONE);
    cpu.fpu_tags = 0;
    run_extended(&mut cpu, &[0xdf, 0x5e, 0x20]);
    assert_eq!(&cpu.memory.bytes[0x1020..0x1022], &[0x00, 0x80]);
    assert_eq!(cpu.fpu_status & 0x41, 0x41);
    // Et un registre occupé se lit sans rien signaler.
    let mut cpu = x87_start(ONE, ONE);
    run_extended(&mut cpu, &[0xd8, 0xc1]);
    assert_eq!(cpu.x87[6], (1 << 63, 0x4000), "1 + 1 = 2");
    assert_eq!(cpu.fpu_status & 0x41, 0);
}

/// **`fucomp` dépile** (`dd e9`), ce que le cœur Swift oubliait ; `fucom`
/// non (`dd e1`).
#[test]
fn fucomp_pops_and_fucom_does_not() {
    let mut cpu = x87_start(ONE, ONE);
    run_extended(&mut cpu, &[0xdd, 0xe1]);
    assert_eq!(cpu.x87_top(), 6);
    run_extended(&mut cpu, &[0xdd, 0xe9]);
    assert_eq!(cpu.x87_top(), 7, "dépilé");
    assert_eq!(cpu.fpu_tags, 0b1000_0000);
    assert_eq!(cpu.fpu_status & 0x4500, 0x4000, "égaux : C3");
}

/// **`fnsave` range l'environnement et les huit registres, puis remet le
/// x87 à zéro ; `frstor` rend tout** — 108 octets, les registres dans l'ordre
/// de la pile.
#[test]
fn fnsave_then_frstor_gives_back_the_state() {
    let mut ram = vec![0u8; 0x2000];
    ram[0x1000..0x1100].fill(0xEE);
    let mut cpu = x87_start((0xC000_0000_0000_0000, 0xC000), ONE);
    cpu.memory.bytes = ram;
    cpu.fpu_control = 0x0b7f;
    cpu.fpu_status |= 0x0021;
    let before = (cpu.x87, cpu.fpu_control, cpu.fpu_status, cpu.fpu_tags);
    // fnsave 0x10(%rsi)
    run_extended(&mut cpu, &[0xdd, 0x76, 0x10]);
    assert_eq!(
        (cpu.fpu_control, cpu.fpu_status, cpu.fpu_tags),
        (0x037f, 0, 0)
    );
    let area = &cpu.memory.bytes[0x1010..0x1010 + 108];
    assert_eq!(&area[0..4], &[0x7f, 0x0b, 0xff, 0xff], "le mot de contrôle");
    assert_eq!(
        &area[28..38],
        &[0, 0, 0, 0, 0, 0, 0, 0xc0, 0x00, 0xc0],
        "ST(0)"
    );
    assert_eq!(
        &area[38..48],
        &[0, 0, 0, 0, 0, 0, 0, 0x80, 0xff, 0x3f],
        "ST(1)"
    );
    assert_eq!(cpu.memory.bytes[0x1010 + 108], 0xEE, "cent huit octets");
    // frstor 0x10(%rsi)
    run_extended(&mut cpu, &[0xdd, 0x66, 0x10]);
    assert_eq!(
        (cpu.x87, cpu.fpu_control, cpu.fpu_status, cpu.fpu_tags),
        before
    );
}

/// **`fnstenv` sous `66` range quatorze octets** : les trois mots sur seize
/// bits, puis les pointeurs à zéro ; et toutes les exceptions sont masquées
/// ensuite.
#[test]
fn fnstenv_under_66_is_fourteen_bytes() {
    let mut cpu = x87_start(ONE, ONE);
    cpu.fpu_control = 0x0360;
    cpu.memory.bytes[0x1000..0x1020].fill(0xEE);
    run_extended(&mut cpu, &[0x66, 0xd9, 0x36]);
    let tags = cpu.x87_tag_word().to_le_bytes();
    assert_eq!(
        &cpu.memory.bytes[0x1000..0x1010],
        &[0x60, 0x03, 0x00, 0x30, tags[0], tags[1], 0, 0, 0, 0, 0, 0, 0, 0, 0xEE, 0xEE]
    );
    assert_eq!(cpu.fpu_control, 0x037f);
}

/// **`fbld` et `fbstp`, dix-huit chiffres décimaux** : un aller-retour rend
/// les mêmes octets ; 10¹⁸ ne tient pas, et `fbstp` range l'indéfini décimal
/// en signalant une opération invalide.
#[test]
fn fbld_and_fbstp_go_through_eighteen_digits() {
    let bcd: [u8; 10] = [0x78, 0x56, 0x34, 0x12, 0x90, 0x78, 0x56, 0x34, 0x12, 0x80];
    let mut cpu = x87_start(ONE, ONE);
    cpu.memory.bytes[0x1000..0x100a].copy_from_slice(&bcd);
    run_extended(&mut cpu, &[0xdf, 0x26]);
    assert_eq!(
        cpu.x87[5],
        Cpu::x87_from_integer(-123_456_789_012_345_678),
        "fbld"
    );
    run_extended(&mut cpu, &[0xdf, 0x76, 0x20]);
    assert_eq!(&cpu.memory.bytes[0x1020..0x102a], &bcd, "fbstp");
    assert_eq!(cpu.x87_top(), 6);
    let mut cpu = x87_start(Cpu::x87_from_integer(1_000_000_000_000_000_000), ONE);
    run_extended(&mut cpu, &[0xdf, 0x76, 0x20]);
    assert_eq!(
        &cpu.memory.bytes[0x1020..0x102a],
        &[0, 0, 0, 0, 0, 0, 0, 0xc0, 0xff, 0xff]
    );
    assert_eq!(cpu.fpu_status & 1, 1);
}

/// **Le zéro décimal garde son signe** : `fbld` de dix octets nuls, le bit
/// de signe levé, empile −0 — et `fbstp` le range tel quel.
#[test]
fn fbld_keeps_the_sign_of_a_decimal_zero() {
    let mut cpu = x87_start(ONE, ONE);
    let mut negative_zero = [0u8; 10];
    negative_zero[9] = 0x80;
    cpu.memory.bytes[0x1000..0x100a].copy_from_slice(&negative_zero);
    run_extended(&mut cpu, &[0xdf, 0x26]);
    assert_eq!(cpu.x87[5], (0, 0x8000), "−0");
    run_extended(&mut cpu, &[0xdf, 0x76, 0x20]);
    assert_eq!(&cpu.memory.bytes[0x1020..0x102a], &negative_zero);
}

/// **C2 dit « hors du domaine », et seulement le temps d'une instruction** :
/// `fsin` de 2⁶³ lève C2, fait tomber C1 et laisse l'opérande ; le `fsin`
/// suivant, d'un argument dans le domaine, fait tomber C2. La `libm` réduit
/// l'argument dans une boucle `fsin ; fnstsw %ax ; test $0x400,%ax`, qui ne
/// sortirait pas d'un C2 resté levé.
#[test]
fn the_sine_raises_c2_out_of_its_domain_and_drops_it_inside() {
    let huge = (1u64 << 63, 0x403e);
    let mut cpu = x87_start(huge, ONE);
    cpu.fpu_status |= 0x0200;
    run_extended(&mut cpu, &[0xd9, 0xfe]);
    assert_eq!(cpu.x87[6], huge, "l'opérande intact");
    assert_eq!(cpu.fpu_status & 0x0600, 0x0400, "C2 levé, C1 tombé");
    run_extended(&mut cpu, &[0xd9, 0xc9]);
    run_extended(&mut cpu, &[0xd9, 0xfe]);
    assert_eq!(cpu.fpu_status & 0x0400, 0, "C2 tombé");
    assert_eq!(
        cpu.x87[6],
        (0xD76A_A478_4867_7021, 0x3ffe),
        "sin 1, au plus proche"
    );
}

/// **`fptan` dit l'arrondi de la tangente**, même après avoir empilé 1 : tan
/// 0,5 vaut `8bda7adf9a3a5218,737…` en unités du dernier rang. Au plus proche
/// elle monte, C1 levé ; vers −∞ elle descend, C1 à zéro — ce que le
/// silicium de l'hôte rend aussi.
#[test]
fn fptan_reports_the_rounding_of_the_tangent() {
    for (control, tangent, c1) in [
        (0x037f, 0x8BDA_7ADF_9A3A_5219, 0x0200),
        (0x077f, 0x8BDA_7ADF_9A3A_5218, 0),
    ] {
        let mut cpu = x87_start((1 << 63, 0x3ffe), ONE);
        cpu.fpu_control = control;
        run_extended(&mut cpu, &[0xd9, 0xf2]);
        assert_eq!(cpu.x87[6], (tangent, 0x3ffe), "cw {control:x} : tan 0,5");
        assert_eq!(cpu.x87[5], ONE, "cw {control:x} : 1 empilé");
        assert_eq!(cpu.fpu_status & 0x0200, c1, "cw {control:x} : C1");
    }
}

/// **C1 tombe sur un chargement** : levé par une racine arrondie vers le
/// haut, il retombe avec `fld1`, comme sur le silicium de l'hôte.
#[test]
fn a_load_drops_c1() {
    // √5 au plus proche monte : C1 levé.
    let mut cpu = x87_start((0xA000_0000_0000_0000, 0x4001), ONE);
    run_extended(&mut cpu, &[0xd9, 0xfa]);
    assert_eq!(cpu.x87[6], (0x8F1B_BCDC_BFA5_3E0B, 0x4000), "√5");
    assert_eq!(cpu.fpu_status & 0x0200, 0x0200, "√5 arrondi vers le haut");
    run_extended(&mut cpu, &[0xd9, 0xe8]);
    assert_eq!(cpu.fpu_status & 0x0200, 0, "C1 tombé");
}

/// **Un réel lu en mémoire signale son NaN signalant et son dénormal** :
/// `flds` d'un NaN signalant le range silencieux, invalide levé ; `fldl` du
/// plus petit dénormal le range normalisé, dénormal levé.
#[test]
fn a_real_read_from_memory_reports_what_it_is() {
    let mut cpu = x87_start(ONE, ONE);
    cpu.memory.bytes[0x1000..0x1004].copy_from_slice(&0x7F80_0001u32.to_le_bytes());
    run_extended(&mut cpu, &[0xd9, 0x06]);
    assert_eq!(cpu.x87[5], (0xC000_0100_0000_0000, 0x7fff));
    assert_eq!(cpu.fpu_status & 0x3f, 1);
    let mut cpu = x87_start(ONE, ONE);
    cpu.memory.bytes[0x1000..0x1008].copy_from_slice(&1u64.to_le_bytes());
    run_extended(&mut cpu, &[0xdd, 0x06]);
    assert_eq!(cpu.x87[5], (1 << 63, (16383 - 1074) as u16));
    assert_eq!(cpu.fpu_status & 0x3f, 2);
}

/// **`fdecstp` et `fincstp` tournent le sommet, et rien d'autre.**
#[test]
fn fdecstp_and_fincstp_turn_the_top_only() {
    let mut cpu = x87_start(ONE, ONE);
    let registers = cpu.x87;
    run_extended(&mut cpu, &[0xd9, 0xf6]);
    assert_eq!(cpu.x87_top(), 5);
    run_extended(&mut cpu, &[0xd9, 0xf7]);
    run_extended(&mut cpu, &[0xd9, 0xf7]);
    assert_eq!(cpu.x87_top(), 7);
    assert_eq!((cpu.x87, cpu.fpu_tags), (registers, 0b1100_0000));
}

/// **La précision du mot de contrôle** (bits 8 et 9) arrondit l'addition :
/// 1 + 2⁻⁵³ en 53 bits tombe pile sur la demie, et l'arrondi au pair rend 1,
/// inexact ; en 64 bits, la somme est exacte.
#[test]
fn the_precision_control_rounds_the_sum() {
    let tiny: Register = (1 << 63, (16383 - 53) as u16);
    let mut cpu = x87_start(ONE, tiny);
    cpu.fpu_control = 0x027f;
    run_extended(&mut cpu, &[0xd8, 0xc1]);
    assert_eq!(cpu.x87[6], ONE);
    assert_eq!(cpu.fpu_status & 0x20, 0x20, "inexact");
    let mut cpu = x87_start(ONE, tiny);
    run_extended(&mut cpu, &[0xd8, 0xc1]);
    assert_eq!(cpu.x87[6], ((1 << 63) | (1 << 10), 0x3fff));
    assert_eq!(cpu.fpu_status & 0x20, 0, "exacte");
}

/// **`maskmovq` ne range que les octets que le masque choisit**, à `[RDI]`.
#[test]
fn maskmovq_writes_only_the_chosen_bytes() {
    let mut cpu = x87_start(ONE, ONE);
    cpu.x87[0] = (0x8877_6655_4433_2211, 0xffff);
    cpu.x87[1] = (0x80_00_80_7F_FF_00_01_80, 0xffff);
    cpu.regs[7] = DATA;
    cpu.memory.bytes[0x1000..0x1008].fill(0xEE);
    run_extended(&mut cpu, &[0x0f, 0xf7, 0xc1]);
    assert_eq!(
        &cpu.memory.bytes[0x1000..0x1008],
        &[0x11, 0xEE, 0xEE, 0x44, 0xEE, 0x66, 0xEE, 0x88]
    );
    assert_eq!(
        (cpu.x87_top(), cpu.fpu_tags),
        (0, 0xff),
        "entré dans le MMX"
    );
}

/// **`rcpps` et `rsqrtps` restent dans la borne du manuel** (1,5 · 2⁻¹² en
/// relatif) sur des valeurs tirées, et rendent ce que le manuel dit des
/// valeurs particulières.
#[test]
fn rcp_and_rsqrt_stay_within_the_bound() {
    let mut cpu = x87_start(ONE, ONE);
    let mut seed = 0x5EED_u64;
    for _ in 0..2000 {
        seed = seed
            .wrapping_mul(6_364_136_223_846_793_005)
            .wrapping_add(1_442_695_040_888_963_407);
        let x = f32::from_bits(((seed >> 33) as u32 & 0x3FFF_FFFF) | 0x1000_0000);
        cpu.xmm[1] = [u64::from(x.to_bits()), 0];
        run_extended(&mut cpu, &[0x0f, 0x53, 0xc1]);
        let reciprocal = f32::from_bits(cpu.xmm[0][0] as u32);
        assert!(
            ((reciprocal * x) as f64 - 1.0).abs() <= 1.5 / 4096.0,
            "rcp {x}"
        );
        run_extended(&mut cpu, &[0x0f, 0x52, 0xc1]);
        let root = f32::from_bits(cpu.xmm[0][0] as u32) as f64;
        assert!(
            (root * root * x as f64 - 1.0).abs() <= 3.0 / 4096.0,
            "rsqrt {x}"
        );
    }
    for (code, x, wanted) in [
        (0x53u8, 0u32, 0x7F80_0000u32),
        (0x53, 0x8000_0000, 0xFF80_0000),
        (0x53, 0x7F80_0000, 0),
        (0x53, 1, 0x7F80_0000),
        (0x52, 0xBF80_0000, 0xFFC0_0000),
        (0x52, 0, 0x7F80_0000),
        (0x52, 0x8000_0000, 0xFF80_0000),
    ] {
        cpu.xmm[1] = [u64::from(x), 0];
        run_extended(&mut cpu, &[0xf3, 0x0f, code, 0xc1]);
        assert_eq!(cpu.xmm[0][0] as u32, wanted, "{code:02x} de {x:#x}");
    }
}

/// **`fxrstor` garde le mot de contrôle comme `fldcw`** : le bit 6 levé, les
/// bits 7 et 13 à 15 effacés. Relu par `fnstcw` après `fxrstor` sur le
/// silicium de l'hôte (un Xeon) : 0x0000 rend 0x0040, 0xe97a rend 0x097a,
/// 0xffff rend 0x1f7f et 0x0080 rend 0x0040.
#[test]
fn fxrstor_keeps_the_control_word_like_the_silicon() {
    for (written, kept) in [
        (0x0000u16, 0x0040u16),
        (0xe97a, 0x097a),
        (0xffff, 0x1f7f),
        (0x0080, 0x0040),
    ] {
        let mut cpu = Cpu {
            memory: GuestMemory {
                base: DATA,
                bytes: vec![0u8; 0x1000],
            },
            ..Default::default()
        };
        cpu.memory.bytes[..2].copy_from_slice(&written.to_le_bytes());
        cpu.memory.bytes[0x18..0x1c].copy_from_slice(&0x1f80u32.to_le_bytes());
        assert_eq!(cpu.restore_floating_point_state(DATA), Ok(()));
        assert_eq!(cpu.fpu_control, kept, "fxrstor de {written:#06x}");
    }
}

/// Un double, en registre du x87 (normal, exact).
fn extended_of(value: f64) -> Register {
    let bits = value.to_bits();
    let exponent = ((bits >> 52) & 0x7ff) as u16 - 1023 + 16383;
    (1 << 63 | (bits & ((1 << 52) - 1)) << 11, exponent)
}

/// **Une instruction qu'une exception démasquée arrête fait tomber C1** —
/// hors d'un débordement de la pile par le haut. C1 est d'abord levé par une
/// racine arrondie vers le haut, puis l'instruction jugée s'arrête. Sur le
/// silicium de l'hôte, au sommet 6 :
///
/// - `fdiv %st(1),%st` par zéro, ZE démasquée : 0xb0a4 ;
/// - `fcom %st(1)` d'un NaN silencieux, IE démasquée : 0xf5a1 (C3, C2 et C0
///   posés, C1 tombé) ;
/// - `fsts` d'une valeur qui dépasse le simple, OE démasquée : 0xb0a8, rien
///   d'écrit.
#[test]
fn a_stopped_instruction_drops_c1() {
    const QUIET: Register = (0xC000_0000_0000_0000, 0x7fff);
    let five = extended_of(5.0);
    for (name, st1, control, code, status) in [
        ("fdiv", (0, 0), 0x037b, &[0xd8, 0xf1][..], 0xb0a4),
        ("fcom", QUIET, 0x037e, &[0xd8, 0xd1], 0xf5a1),
    ] {
        let mut cpu = x87_start(five, st1);
        cpu.fpu_control = 0x0b7f;
        run_extended(&mut cpu, &[0xd9, 0xfa]);
        assert_eq!(cpu.fpu_status & 0x0200, 0x0200, "{name} : C1 levé avant");
        let root = cpu.x87[6];
        cpu.fpu_control = control;
        run_extended(&mut cpu, code);
        assert_eq!(cpu.fpu_status, status, "{name} : le mot d'état");
        assert_eq!(cpu.x87[6], root, "{name} : rien de rangé");
    }
    let mut cpu = x87_start(extended_of(2e300), ONE);
    cpu.fpu_control = 0x0b7f;
    run_extended(&mut cpu, &[0xd9, 0xfa]);
    assert_eq!(cpu.fpu_status & 0x0200, 0x0200, "fsts : C1 levé avant");
    cpu.fpu_control = 0x0377;
    run_extended(&mut cpu, &[0xd9, 0x16]);
    assert_eq!(cpu.fpu_status, 0xb0a8, "fsts : le mot d'état");
    assert_eq!(
        &cpu.memory.bytes[0x1000..0x1004],
        &[0x10, 0x11, 0x12, 0x13],
        "fsts : rien d'écrit"
    );
}

/// **La pile pleine dont ST(0) est vide** : `fxtract`, `fsincos` et `fptan`
/// lisent un registre vide (débordement par le bas, C1 à zéro), puis
/// empilent sur un registre occupé. Sur le silicium de l'hôte, après
/// `fninit ; fld1 ×7 ; fldpi ; ffree %st(0)` : sw 0x3841 — C1 reste à zéro —,
/// étiquettes 0x8002, l'indéfini dans les deux registres.
#[test]
fn a_full_stack_with_an_empty_top_keeps_c1_down() {
    for (name, code) in [
        ("fxtract", [0xd9, 0xf4]),
        ("fsincos", [0xd9, 0xfb]),
        ("fptan", [0xd9, 0xf2]),
    ] {
        let mut cpu = x87_start(ONE, ONE);
        (cpu.fpu_status, cpu.fpu_tags) = (0, 0);
        for _ in 0..7 {
            run_extended(&mut cpu, &[0xd9, 0xe8]);
        }
        run_extended(&mut cpu, &[0xd9, 0xeb]);
        run_extended(&mut cpu, &[0xdd, 0xc0]);
        run_extended(&mut cpu, &code);
        assert_eq!(cpu.fpu_status, 0x3841, "{name} : le mot d'état");
        assert_eq!(cpu.x87_tag_word(), 0x8002, "{name} : les étiquettes");
        assert_eq!(
            (cpu.x87[7], cpu.x87[0]),
            (INDEFINITE, INDEFINITE),
            "{name} : deux indéfinis"
        );
    }
}

/// **Ce qui n'attend pas, par le second décodeur lui-même** : sous une
/// division par zéro démasquée en attente (ES levé), `fninit`, `fnclex`,
/// `fnstsw`, `fnstcw`, `fnstenv`, `fnsave`, `fneni`, `fndisi` et `fnsetpm`
/// s'exécutent ; `fld1`, `fnop`, `fldcw` et `emms` rendent
/// `FloatingPoint` sans rien changer. Dans la machine, `fninit` passe par
/// `decode` (`Op::FpuInit`) ; `execute_extended` doit le traiter de même pour
/// qui l'appelle directement.
#[test]
fn the_no_wait_forms_run_under_a_pending_exception() {
    let pending = |cpu: &mut Cpu| {
        cpu.fpu_control = 0x037b;
        cpu.fpu_status = (6 << 11) | 0x8084;
    };
    for code in [
        &[0xdb, 0xe3][..],
        &[0xdb, 0xe2],
        &[0xdf, 0xe0],
        &[0xdd, 0x3e],
        &[0xd9, 0x3e],
        &[0xd9, 0x36],
        &[0xdd, 0x36],
        &[0xdb, 0xe0],
        &[0xdb, 0xe1],
        &[0xdb, 0xe4],
    ] {
        let mut cpu = x87_start(ONE, ONE);
        pending(&mut cpu);
        run_extended(&mut cpu, code);
    }
    for code in [
        &[0xd9, 0xe8][..],
        &[0xd9, 0xd0],
        &[0xd9, 0x2e],
        &[0x0f, 0x77],
    ] {
        let mut cpu = x87_start(ONE, ONE);
        pending(&mut cpu);
        let decoded = decode_extended(code).expect("se lit");
        assert_eq!(
            cpu.execute_extended(&decoded),
            Err(ExtendedFault::FloatingPoint),
            "{code:02x?}"
        );
        assert_eq!(
            (cpu.fpu_status, cpu.fpu_tags, cpu.x87[5]),
            ((6 << 11) | 0x8084, 0b1100_0000, (0, 0)),
            "{code:02x?} : rien de changé"
        );
    }
}
