//! **Les instructions SSE et SSE2 entières de l'interpréteur, jugées par le
//! silicium.**
//!
//! `Tests/Fixtures/x86-xmm-oracle.tsv` et `x86-simd-oracle.tsv` ont été relevés
//! sur un vrai processeur. L'émetteur les rejoue sous JavaScriptCore
//! (`tests/x86_wasm.rs`) ; ici c'est `Cpu::execute_vector`, le chemin de la
//! machine PC native, qui passe devant le même juge — sans moteur JavaScript.

use std::collections::HashMap;
use std::path::Path;

use wisq_vm::x86::{decode, Cpu, GuestMemory, Op};

/// Où RSI pointe : la fenêtre de soixante-quatre octets des deux corpus.
const DATA: u64 = 0x3000_1000;
/// Où l'instruction est posée — hors de la fenêtre.
const CODE: u64 = 0x3000_0000;

fn hex(text: &str) -> u64 {
    u64::from_str_radix(text, 16).expect("un nombre hexadécimal du corpus")
}

fn bytes(text: &str) -> Vec<u8> {
    (0..text.len() / 2)
        .map(|at| u8::from_str_radix(&text[2 * at..2 * at + 2], 16).expect("un octet du corpus"))
        .collect()
}

struct Oracle {
    states: HashMap<String, [u64; 6]>,
    instructions: HashMap<String, (Vec<u8>, String)>,
    cases: Vec<(String, String, [u64; 5], Option<String>)>,
}

fn read(name: &str) -> Oracle {
    let path = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../Tests/Fixtures")
        .join(name);
    let text = std::fs::read_to_string(path).expect("l'oracle matériel doit être lisible");
    let mut oracle = Oracle {
        states: HashMap::new(),
        instructions: HashMap::new(),
        cases: Vec::new(),
    };
    for line in text.lines() {
        if line.starts_with('#') || line.trim().is_empty() {
            continue;
        }
        let f: Vec<&str> = line.split('\t').collect();
        match f[0] {
            "état" => {
                let mut state = [0u64; 6];
                for (slot, field) in state.iter_mut().zip(&f[2..8]) {
                    *slot = hex(field);
                }
                oracle.states.insert(f[1].into(), state);
            }
            "instr" => {
                oracle
                    .instructions
                    .insert(f[1].into(), (bytes(f[2]), f[3].into()));
            }
            "cas" => {
                let mut after = [0u64; 5];
                for (slot, field) in after.iter_mut().zip(&f[3..8]) {
                    *slot = hex(field);
                }
                let memory = match f.get(8) {
                    Some(&"-") | None => None,
                    Some(text) => Some((*text).to_string()),
                };
                oracle.cases.push((f[1].into(), f[2].into(), after, memory));
            }
            _ => {}
        }
    }
    oracle
}

/// Rejouer un corpus : le nombre de cas jugés, et la liste des écarts.
fn replay(name: &str) -> (usize, Vec<String>) {
    let oracle = read(name);
    let window: Vec<u8> = (0x10u8..0x50).collect();
    let pristine: String = window.iter().map(|byte| format!("{byte:02x}")).collect();
    let mut wrong = Vec::new();
    let mut checked = 0;
    for (instruction, state, want, memory) in &oracle.cases {
        let (code, mnemonic) = &oracle.instructions[instruction];
        let start = oracle.states[state];
        let Some(decoded) = decode(code) else {
            wrong.push(format!("{mnemonic} : illisible"));
            continue;
        };
        if !matches!(decoded.op, Op::Vector(_)) || decoded.length != code.len() {
            wrong.push(format!("{mnemonic} : lue comme {:?}", decoded.op));
            continue;
        }
        // Une seule fenêtre de RAM, du code aux données.
        let mut ram = vec![0u8; 0x2000];
        ram[0x1000..0x1040].copy_from_slice(&window);
        let mut cpu = Cpu {
            rip: CODE,
            memory: GuestMemory {
                base: CODE,
                bytes: ram,
            },
            mxcsr: 0x1f80,
            ..Default::default()
        };
        cpu.regs[0] = start[4];
        cpu.regs[6] = DATA;
        cpu.flags.write(start[5] | 2);
        // Les quatorze autres registres portent un témoin : y écrire se voit.
        for (index, register) in cpu.xmm.iter_mut().enumerate() {
            *register = [0x1111_0000 + index as u64, 0x2222_0000 + index as u64];
        }
        cpu.xmm[0] = [start[0], start[1]];
        cpu.xmm[1] = [start[2], start[3]];
        let outcome = cpu.execute_vector(&decoded);
        checked += 1;
        let mut differences = Vec::new();
        if outcome.is_err() || cpu.faulted {
            differences.push(format!("n'est pas allée au bout : {outcome:?}"));
        }
        for (label, value, wanted) in [
            ("xmm0 bas", cpu.xmm[0][0], want[0]),
            ("xmm0 haut", cpu.xmm[0][1], want[1]),
            ("xmm1 bas", cpu.xmm[1][0], want[2]),
            ("xmm1 haut", cpu.xmm[1][1], want[3]),
            ("rax", cpu.regs[0], want[4]),
            ("drapeaux", cpu.flags.read(), start[5] | 2),
            ("rsi", cpu.regs[6], DATA),
            ("mxcsr", u64::from(cpu.mxcsr), 0x1f80),
        ] {
            if value != wanted {
                differences.push(format!("{label} {value:x} au lieu de {wanted:x}"));
            }
        }
        for (index, register) in cpu.xmm.iter().enumerate().skip(2) {
            if *register != [0x1111_0000 + index as u64, 0x2222_0000 + index as u64] {
                differences.push(format!("a écrit dans xmm{index}"));
            }
        }
        let after: String = cpu.memory.bytes[0x1000..0x1040]
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect();
        let wanted = memory.clone().unwrap_or_else(|| pristine.clone());
        if after != wanted {
            differences.push(format!("mémoire {after} au lieu de {wanted}"));
        }
        if !differences.is_empty() {
            wrong.push(format!(
                "{mnemonic}, état {state} : {}",
                differences.join(" ; ")
            ));
        }
    }
    (checked, wrong)
}

fn judge(name: &str, expected: Option<usize>) {
    let (checked, wrong) = replay(name);
    assert!(
        wrong.is_empty(),
        "{} écarts sur {checked} cas :\n{}",
        wrong.len(),
        wrong
            .iter()
            .take(40)
            .cloned()
            .collect::<Vec<_>>()
            .join("\n")
    );
    let cases = read(name).cases.len();
    assert_eq!(checked, cases, "tous les cas du corpus doivent être jugés");
    if let Some(expected) = expected {
        assert_eq!(checked, expected, "le corpus a changé de taille");
    }
}

/// Les déplacements, la logique et les entrelacements : 58 formes, 976 cas.
#[test]
fn the_interpreter_matches_the_silicon_on_the_xmm_corpus() {
    judge("x86-xmm-oracle.tsv", Some(976));
}

/// L'arithmétique SSE2 entière : comparaisons, additions saturées ou non,
/// permutations, décalages, multiplications, masques, empaquetages.
#[test]
fn the_interpreter_matches_the_silicon_on_the_sse2_integer_corpus() {
    judge("x86-simd-oracle.tsv", None);
}

/// `execute`, lui, refuse toujours : c'est la machine PC qui choisit
/// d'exécuter les vecteurs, et l'interpréteur de référence reste ce qu'il
/// était pour le test différentiel.
#[test]
fn the_plain_interpreter_still_refuses_vectors() {
    let decoded = decode(&[0x66, 0x0f, 0xef, 0xc1]).expect("pxor %xmm1, %xmm0");
    let mut cpu = Cpu::default();
    cpu.execute(&decoded);
    assert!(cpu.faulted, "execute ne porte pas les XMM");
}

/// `ldmxcsr` avec un bit réservé : `#GP(0)`, et MXCSR intact.
#[test]
fn a_reserved_mxcsr_bit_is_refused_and_changes_nothing() {
    use wisq_vm::x86::VectorFault;
    let decoded = decode(&[0x0f, 0xae, 0x16]).expect("ldmxcsr (%rsi)");
    let mut ram = vec![0u8; 0x1000];
    ram[..4].copy_from_slice(&0x0001_1f80u32.to_le_bytes());
    let mut cpu = Cpu {
        memory: GuestMemory {
            base: DATA,
            bytes: ram,
        },
        mxcsr: 0x1f80,
        ..Default::default()
    };
    cpu.regs[6] = DATA;
    assert_eq!(
        cpu.execute_vector(&decoded),
        Err(VectorFault::ReservedControl)
    );
    assert_eq!(cpu.mxcsr, 0x1f80);
    // Et une valeur permise se charge.
    cpu.memory.bytes[..4].copy_from_slice(&0x0000_1fa0u32.to_le_bytes());
    assert_eq!(cpu.execute_vector(&decoded), Ok(()));
    assert_eq!(cpu.mxcsr, 0x1fa0);
}
