//! **Le cœur ARM64 contre `qemu-aarch64`.**
//!
//! `scripts/arm64-oracle.py` tire des programmes A64 au hasard dans toutes les
//! familles que le cœur sait exécuter, les fait tourner sous qemu, et garde ce
//! qu'ils écrivent : après chaque bloc de soixante-quatre instructions, la zone
//! de mémoire touchée, x0 à x27 et NZCV. Ce fichier fait tourner le cœur de
//! wisq sur les mêmes octets et exige la même sortie, octet pour octet. Une
//! différence est dite par bloc et par registre, pas par un « les tampons
//! diffèrent ».
//!
//! La CI n'a pas besoin de qemu : les fixtures sont dans `tests/arm64/`.

use wisq_vm::arm64::{Arm64Core, Arm64Step, FlatMemory};

const BASE: u64 = 0x40_0000;
const SCRATCH: usize = 1024;
const BLOCK_OUTPUT: usize = SCRATCH + 232;

/// Fait tourner un programme comme `qemu-aarch64` le ferait : `write` (64)
/// recopie la mémoire sur la sortie, `exit` (93) arrête.
fn run(code: &[u8]) -> Vec<u8> {
    let mut memory = FlatMemory::new(BASE, 0x3_0000);
    memory.bytes[..code.len()].copy_from_slice(code);
    let mut core = Arm64Core::new(BASE, BASE + 0x3_0000);
    let mut output = Vec::new();
    for _ in 0..2_000_000 {
        match core.step(&mut memory) {
            Arm64Step::Ran => {}
            Arm64Step::Svc(0) => match core.x[8] {
                64 => {
                    let start = (core.x[1] - BASE) as usize;
                    let length = core.x[2] as usize;
                    output.extend_from_slice(&memory.bytes[start..start + length]);
                    core.x[0] = core.x[2];
                }
                93 => return output,
                call => panic!("appel système {call} inattendu à {:#x}", core.pc),
            },
            other => panic!("{other:?} à {:#x} (instruction {:#010x})", core.pc, {
                let at = (core.pc - BASE) as usize;
                u32::from_le_bytes(memory.bytes[at..at + 4].try_into().unwrap())
            }),
        }
    }
    panic!("le programme ne s'est pas arrêté");
}

fn word(bytes: &[u8], at: usize) -> u64 {
    u64::from_le_bytes(bytes[at..at + 8].try_into().unwrap())
}

/// La première différence, nommée : bloc, puis registre, NZCV ou octet de la
/// zone.
fn first_difference(name: &str, got: &[u8], expected: &[u8]) -> Option<String> {
    if got == expected {
        return None;
    }
    if got.len() != expected.len() {
        return Some(format!(
            "{name} : {} octets écrits, {} attendus",
            got.len(),
            expected.len()
        ));
    }
    for (block, (mine, theirs)) in got
        .chunks(BLOCK_OUTPUT)
        .zip(expected.chunks(BLOCK_OUTPUT))
        .enumerate()
    {
        for r in 0..28 {
            let at = SCRATCH + 8 * r;
            if word(mine, at) != word(theirs, at) {
                return Some(format!(
                    "{name}, bloc {block} : x{r} vaut {:#018x}, qemu dit {:#018x}",
                    word(mine, at),
                    word(theirs, at)
                ));
            }
        }
        if word(mine, SCRATCH + 224) != word(theirs, SCRATCH + 224) {
            return Some(format!(
                "{name}, bloc {block} : NZCV vaut {:#x}, qemu dit {:#x}",
                word(mine, SCRATCH + 224) >> 28,
                word(theirs, SCRATCH + 224) >> 28
            ));
        }
        if let Some(at) = (0..SCRATCH).find(|&at| mine[at] != theirs[at]) {
            return Some(format!(
                "{name}, bloc {block} : l'octet {at} de la zone vaut {:#04x}, qemu dit {:#04x}",
                mine[at], theirs[at]
            ));
        }
    }
    Some(format!("{name} : différence introuvable"))
}

#[test]
fn random_programs_write_what_qemu_writes() {
    let folder = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/arm64");
    let mut compared = 0;
    for index in 0.. {
        let stem = folder.join(format!("aleatoire-{index}"));
        let Ok(code) = std::fs::read(stem.with_extension("bin")) else {
            break;
        };
        let expected = std::fs::read(stem.with_extension("attendu")).expect("la sortie de qemu");
        let got = run(&code);
        if let Some(difference) = first_difference(&format!("aleatoire-{index}"), &got, &expected) {
            panic!("{difference}");
        }
        compared += 1;
    }
    assert!(
        compared >= 8,
        "{compared} programmes seulement : les fixtures manquent"
    );
}

/// Assemble des mots d'instruction à `BASE` et les fait tourner `steps` pas.
fn execute(words: &[u32], steps: usize) -> (Arm64Core, FlatMemory, Arm64Step) {
    let mut memory = FlatMemory::new(BASE, 0x1_0000);
    for (index, insn) in words.iter().enumerate() {
        memory.bytes[index * 4..index * 4 + 4].copy_from_slice(&insn.to_le_bytes());
    }
    let mut core = Arm64Core::new(BASE, BASE + 0x1_0000);
    let mut last = Arm64Step::Ran;
    for _ in 0..steps {
        last = core.step(&mut memory);
        if last != Arm64Step::Ran {
            break;
        }
    }
    (core, memory, last)
}

/// `BL`, `RET`, `BLR` et `BR` : le lien est l'instruction suivante, le retour
/// y revient. Encodages d'`aarch64-linux-gnu-as`.
#[test]
fn calls_link_and_return() {
    let words = [
        0x9400_0003, // bl +12
        0xd280_0021, // mov x1, #1
        0xd420_0000, // brk #0
        0xd280_0040, // mov x0, #2
        0xd65f_03c0, // ret
    ];
    let (core, _, last) = execute(&words, 10);
    assert_eq!(last, Arm64Step::Brk(0));
    assert_eq!(core.pc, BASE + 8);
    assert_eq!((core.x[0], core.x[1], core.x[30]), (2, 1, BASE + 4));

    let indirect = [
        0x1000_0062, // adr x2, +12
        0xd63f_0040, // blr x2
        0xd420_0020, // brk #1
        0xd61f_03c0, // br x30
    ];
    let (core, _, last) = execute(&indirect, 10);
    assert_eq!(last, Arm64Step::Brk(1));
    assert_eq!(core.x[30], BASE + 8);
}

/// `LDR` littéral et `ADRP` : relatifs à `pc`, page de quatre kibioctets.
#[test]
fn pc_relative_forms() {
    let words = [
        0x5800_0040, // ldr x0, +8
        0xd420_0000, // brk #0
        0x8765_4321, // le littéral, bas
        0x1234_5678, // le littéral, haut
    ];
    let (core, _, last) = execute(&words, 4);
    assert_eq!(last, Arm64Step::Brk(0));
    assert_eq!(core.x[0], 0x1234_5678_8765_4321);

    let (core, _, _) = execute(&[0xb000_0001], 1); // adrp x1, +0x1000
    assert_eq!(core.x[1], (BASE & !0xfff) + 0x1000);
}

/// `SVC` rend la main après l'instruction ; un accès sans mémoire derrière
/// laisse `pc` et les registres comme ils étaient ; une instruction
/// flottante est dite indéfinie, pas exécutée de travers.
#[test]
fn what_hands_control_back() {
    let (core, _, last) = execute(&[0xd400_0a81], 1); // svc #0x54
    assert_eq!(last, Arm64Step::Svc(0x54));
    assert_eq!(core.pc, BASE + 4);

    let words = [
        0xd2a0_0021, // mov x1, #0x10000
        0xf940_0020, // ldr x0, [x1] — hors de la mémoire
    ];
    let (core, _, last) = execute(&words, 4);
    assert_eq!(last, Arm64Step::Fault(0x1_0000));
    assert_eq!(core.pc, BASE + 4);
    assert_eq!(core.x[0], 0);

    let (core, _, last) = execute(&[0x1e20_2800], 1); // fadd s0, s0, s0
    assert_eq!(last, Arm64Step::Undefined(0x1e20_2800));
    assert_eq!(core.pc, BASE);
}
