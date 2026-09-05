//! **Le cœur x86 en Rust, jugé par du vrai silicium.**
//!
//! `Tests/Fixtures/x86-oracle.tsv` a été produit en exécutant chaque
//! instruction sur un vrai processeur, avec vingt-quatre états d'entrée
//! choisis pour tomber sur les bords : zéro, un, 0x7f, 0x80, la valeur qui
//! déborde, celle qui ne déborde que d'un bit. Un cœur qui se juge lui-même ne
//! se juge pas ; celui-ci se juge contre ce que la machine a répondu.
//!
//! **Le masque compte autant que la valeur.** L'architecture laisse certains
//! drapeaux indéfinis après certaines instructions — le processeur y met ce
//! qu'il veut, et deux exemplaires du même modèle peuvent différer. Le fichier
//! porte, pour chaque instruction, le masque de ce qui est **défini**. Comparer
//! hors de ce masque ferait échouer un cœur juste, ou pire, passer un cœur faux
//! pour la mauvaise raison.

use std::collections::HashMap;
use std::path::{Path, PathBuf};

use wisq_vm::x86::{decode, Cpu, Decoded, Flags};

fn oracle_path() -> PathBuf {
    // CARGO_MANIFEST_DIR est crates/wisq-vm.
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .and_then(Path::parent)
        .expect("racine de l'espace de travail")
        .join("Tests/Fixtures/x86-oracle.tsv")
}

#[derive(Clone)]
struct State {
    rax: u64,
    rcx: u64,
    rdx: u64,
    flags: u64,
}

#[derive(Clone)]
struct Instruction {
    bytes: Vec<u8>,
    defined: u64,
    mnemonic: String,
}

struct Case {
    instruction: String,
    state: String,
    rax: u64,
    rcx: u64,
    rdx: u64,
    flags: u64,
}

fn hex(text: &str) -> u64 {
    u64::from_str_radix(text, 16).expect("un nombre hexadécimal")
}

fn bytes(text: &str) -> Vec<u8> {
    (0..text.len() / 2)
        .map(|i| u8::from_str_radix(&text[i * 2..i * 2 + 2], 16).expect("un octet"))
        .collect()
}

fn read_oracle() -> (
    HashMap<String, State>,
    HashMap<String, Instruction>,
    Vec<Case>,
) {
    let text = std::fs::read_to_string(oracle_path()).expect("l'oracle matériel doit être lisible");
    let mut states = HashMap::new();
    let mut instructions = HashMap::new();
    let mut cases = Vec::new();
    for line in text.lines() {
        if line.starts_with('#') || line.trim().is_empty() {
            continue;
        }
        let field: Vec<&str> = line.split('\t').collect();
        match field[0] {
            "état" => {
                states.insert(
                    field[1].to_string(),
                    State {
                        rax: hex(field[2]),
                        rcx: hex(field[3]),
                        rdx: hex(field[4]),
                        flags: hex(field[5]),
                    },
                );
            }
            "instr" => {
                instructions.insert(
                    field[1].to_string(),
                    Instruction {
                        bytes: bytes(field[2]),
                        defined: hex(field[3]),
                        mnemonic: field[4].to_string(),
                    },
                );
            }
            "cas" => cases.push(Case {
                instruction: field[1].to_string(),
                state: field[2].to_string(),
                rax: hex(field[3]),
                rcx: hex(field[4]),
                rdx: hex(field[5]),
                flags: hex(field[6]),
            }),
            _ => {}
        }
    }
    (states, instructions, cases)
}

/// Décoder une séquence entière, ou rien. Un décodage partiel n'est pas une
/// couverture partielle : c'est un état faux.
fn decode_all(bytes: &[u8]) -> Option<Vec<Decoded>> {
    let mut program = Vec::new();
    let mut at = 0usize;
    while at < bytes.len() {
        let step = decode(&bytes[at..])?;
        at += step.length;
        program.push(step);
    }
    if program.is_empty() {
        return None;
    }
    Some(program)
}

/// **Chaque cas que ce cœur prétend connaître doit tomber juste.**
///
/// Le test ne demande pas que tout soit couvert — la tranche annonce le groupe
/// arithmétique et rien d'autre, et une instruction que le décodeur refuse est
/// comptée à part plutôt qu'ignorée. Ce qui n'est pas négociable, c'est qu'une
/// instruction **acceptée** rende exactement ce que le silicium a rendu.
#[test]
fn every_accepted_instruction_matches_the_silicon() {
    let (states, instructions, cases) = read_oracle();
    let mut checked = 0usize;
    let mut refused: Vec<&str> = Vec::new();
    let mut wrong: Vec<String> = Vec::new();

    for case in &cases {
        let instruction = &instructions[&case.instruction];
        let state = &states[&case.state];
        // **Une entrée peut porter plusieurs instructions**, et certaines
        // portent une boucle entière. Si un seul octet échappe au décodeur,
        // l'entrée entière est refusée : exécuter la moitié d'une séquence
        // rendrait un état faux qu'on comparerait sérieusement.
        let Some(program) = decode_all(&instruction.bytes) else {
            if !refused.contains(&instruction.mnemonic.as_str()) {
                refused.push(&instruction.mnemonic);
            }
            continue;
        };

        let mut cpu = Cpu::default();
        cpu.regs[0] = state.rax;
        cpu.regs[1] = state.rcx;
        cpu.regs[2] = state.rdx;
        let mut flags = Flags::default();
        flags.write(state.flags);
        cpu.flags = flags;

        for step in &program {
            cpu.execute(step);
        }
        checked += 1;

        let got = (cpu.regs[0], cpu.regs[1], cpu.regs[2], cpu.flags.read());
        let want = (case.rax, case.rcx, case.rdx, case.flags);
        let mask = instruction.defined;
        if got.0 != want.0
            || got.1 != want.1
            || got.2 != want.2
            || (got.3 & mask) != (want.3 & mask)
        {
            if wrong.len() < 12 {
                wrong.push(format!(
                    "{} état {} : rax {:x}≠{:x} rcx {:x}≠{:x} rdx {:x}≠{:x} drapeaux {:x}≠{:x} (masque {:x})",
                    instruction.mnemonic,
                    case.state,
                    got.0, want.0, got.1, want.1, got.2, want.2,
                    got.3 & mask, want.3 & mask, mask,
                ));
            } else {
                wrong.push(String::new());
            }
        }
    }

    println!(
        "x86 Rust : {checked} cas matériels vérifiés, {} instructions refusées par le décodeur",
        refused.len()
    );
    assert!(
        wrong.is_empty(),
        "{} cas sur {checked} ne rendent pas ce que le processeur rend :\n{}",
        wrong.len(),
        wrong
            .iter()
            .filter(|line| !line.is_empty())
            .cloned()
            .collect::<Vec<_>>()
            .join("\n")
    );
    // Une tranche qui ne vérifierait rien passerait ce test sans rien dire.
    assert!(
        checked > 1500,
        "le décodeur ne reconnaît plus que {checked} cas : la couverture a reculé"
    );
}
