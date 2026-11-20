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
    decode, decode_extended, Cpu, ExtendedFault, Extra, FpuWord, GuestMemory, Width, FXSAVE_WRITTEN,
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
    // Neuf formes — `fild` aux trois largeurs et à deux adresses, `fnstsw
    // %ax`, `fnstcw`, `fldcw` —, soixante états chacune.
    let mut forms: Vec<_> = judged.keys().copied().collect();
    forms.sort_unstable();
    assert_eq!(
        forms,
        [
            "fildl 0x0(%rsi)",
            "fildl 0x8(%rsi)",
            "fildll 0x0(%rsi)",
            "fildll 0x8(%rsi)",
            "filds 0x0(%rsi)",
            "filds 0x8(%rsi)",
            "fldcw 0x20(%rsi)",
            "fnstcw 0x20(%rsi)",
            "fnstsw %ax",
        ]
    );
    assert_eq!(judged.values().sum::<usize>(), 540);
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

/// **Le second décodeur ne lit que ce qu'il nomme.** Ses voisins restent
/// illisibles : `d9 /0` est `fld`, un vrai calcul.
#[test]
fn the_extended_decoder_reads_exactly_its_forms() {
    let read =
        |code: &[u8]| decode_extended(code).map(|instruction| (instruction.op, instruction.length));
    assert_eq!(
        read(&[0xd9, 0x7c, 0x24, 0x0c]),
        Some((Extra::FpuWord(FpuWord::StoreControl), 4)),
        "fnstcw 0xc(%rsp), le premier mur du décompresseur"
    );
    assert_eq!(
        read(&[0xdd, 0x7c, 0x24, 0x0e]),
        Some((Extra::FpuWord(FpuWord::StoreStatus), 4))
    );
    assert_eq!(
        read(&[0xd9, 0x2e]),
        Some((Extra::FpuWord(FpuWord::LoadControl), 2))
    );
    assert_eq!(
        read(&[0xdf, 0xe0]),
        Some((Extra::FpuWord(FpuWord::StatusToAccumulator), 2))
    );
    assert_eq!(
        read(&[0xdb, 0xe2]),
        Some((Extra::FpuWord(FpuWord::ClearExceptions), 2))
    );
    assert_eq!(read(&[0x0f, 0x77]), Some((Extra::Emms, 2)));
    assert_eq!(
        read(&[0xdb, 0x07]),
        Some((Extra::FpuLoadInteger, 2)),
        "fildl (%rdi)"
    );
    assert_eq!(
        decode_extended(&[0xdf, 0x2e]).map(|instruction| instruction.width),
        Some(Width::Qword),
        "fildll"
    );
    for (name, code) in [
        ("fld m32", &[0xd9, 0x06][..]),
        ("fstp m32", &[0xd9, 0x1e]),
        ("fldl m64", &[0xdd, 0x06]),
        ("fistpl", &[0xdb, 0x1e]),
        ("fld m80", &[0xdb, 0x2e]),
        ("fbld", &[0xdf, 0x26]),
        ("fistpll", &[0xdf, 0x3e]),
        ("fld1", &[0xd9, 0xe8]),
        ("fnstsw %ax précédé de 66", &[0x66, 0xdf, 0xe0]),
        ("emms précédé de f3", &[0xf3, 0x0f, 0x77]),
        ("femms", &[0x0f, 0x0e]),
        ("fnstcw à adresse de 32 bits", &[0x67, 0xd9, 0x38]),
        ("fnstcw coupé", &[0xd9, 0x7c, 0x24]),
    ] {
        assert_eq!(decode_extended(code), None, "{name} doit rester illisible");
    }
    // Et ce que `decode` lit déjà n'est pas à lui : `fninit` reste au premier.
    assert!(decode(&[0xdb, 0xe3]).is_some());
    assert_eq!(decode_extended(&[0xdb, 0xe3]), None);
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
        assert_eq!(decoded.width, width);
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
