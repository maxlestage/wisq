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

use wisq_vm::x86::{decode, Cpu, Flags, GuestMemory, Op, Step};

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
    /// La fenêtre de données après l'instruction, ou rien quand elle n'a pas
    /// bougé — le corpus écrit « - » dans ce cas, et la plupart des
    /// instructions ne la touchent pas.
    memory: Option<Vec<u8>>,
    /// Et la pile. Un `push` à la mauvaise adresse laisse tous les registres
    /// justes ; sans cette colonne, rien ne le verrait.
    stack: Option<Vec<u8>>,
    /// **RSP, RBP et RSI.** Les trois seuls registres que le corpus autorise à
    /// bouger — le script vérifie que les treize autres ne bougent pas — et
    /// donc les trois seuls qu'il doit relever. Un sabotage l'a montré :
    /// `leave` qui dépile **avant** de reprendre RBP laisse RAX, RCX, RDX, les
    /// drapeaux et les deux fenêtres exactement justes, et passait.
    pointers: (u64, u64, u64),
}

/// Des octets, pour un message d'écart lisible.
fn hexadecimal(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn hex(text: &str) -> u64 {
    u64::from_str_radix(text, 16).expect("un nombre hexadécimal")
}

fn bytes(text: &str) -> Vec<u8> {
    (0..text.len() / 2)
        .map(|i| u8::from_str_radix(&text[i * 2..i * 2 + 2], 16).expect("un octet"))
        .collect()
}

/// Le fichier, relu. Une structure plutôt qu'un quadruplet : la quatrième
/// valeur — l'état de départ du silicium — n'est pas devinable depuis sa
/// position, et un tuple à quatre membres la rendrait facile à intervertir.
struct Oracle {
    states: HashMap<String, State>,
    instructions: HashMap<String, Instruction>,
    cases: Vec<Case>,
    fixed: [u64; 16],
    /// **Les fenêtres de mémoire**, et le motif dont chacune part à chaque cas.
    /// Il y en a deux : les données, où pointe RSI, et la pile, des deux côtés
    /// de RSP. Lues dans le fichier, jamais devinées — même leçon que les
    /// registres fixes, et elle a coûté 144 cas la première fois.
    windows: Vec<(u64, Vec<u8>)>,
    /// **La base du segment GS**, telle que le pilote l'a posée. Elle vaut la
    /// fenêtre de données, exprès : c'est ce qui rend `%gs:0x10` lisible avec
    /// le même motif que `0x10(%rsi)`.
    gs_base: u64,
}

/// La mémoire que ces fenêtres décrivent : une étendue contiguë qui les couvre
/// toutes, le creux entre elles à zéro. L'invité n'y touche pas — mais s'il le
/// faisait, mieux vaut un zéro franc qu'un octet d'une autre fenêtre.
fn span(windows: &[(u64, Vec<u8>)]) -> GuestMemory {
    let base = windows.iter().map(|(at, _)| *at).min().unwrap_or(0);
    let end = windows
        .iter()
        .map(|(at, bytes)| at + bytes.len() as u64)
        .max()
        .unwrap_or(0);
    let mut memory = GuestMemory {
        base,
        bytes: vec![0; (end - base) as usize],
    };
    for (at, pristine) in windows {
        let start = (at - base) as usize;
        memory.bytes[start..start + pristine.len()].copy_from_slice(pristine);
    }
    memory
}

fn read_oracle() -> Oracle {
    let text = std::fs::read_to_string(oracle_path()).expect("l'oracle matériel doit être lisible");
    let mut states = HashMap::new();
    let mut instructions = HashMap::new();
    let mut cases = Vec::new();
    // **Ce que le silicium avait dans les registres que « état » ne porte
    // pas.** Rien ici ne peut être deviné : le fichier le dit, et s'il ne le
    // disait pas ce harnais comparerait son résultat à celui d'un processeur
    // parti d'ailleurs.
    let mut fixed = [0u64; 16];
    let mut seeded = 0usize;
    let mut windows: Vec<(u64, Vec<u8>)> = Vec::new();
    let mut gs_base: Option<u64> = None;
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
            "fenêtre" => windows.push((hex(field[1]), bytes(field[2]))),
            // **La base du segment GS**, que le pilote pose par `arch_prctl`.
            // Elle n'apparaît dans aucun registre : sans cette ligne, le
            // harnais partirait de zéro et lirait la page zéro là où le
            // silicium lisait la fenêtre de données.
            "segment" if field[1] == "gs" => gs_base = Some(hex(field[2])),
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
            "fixe" => {
                let register: usize = field[1].parse().expect("un numéro de registre");
                fixed[register] = hex(field[2]);
                seeded += 1;
            }
            "cas" => cases.push(Case {
                instruction: field[1].to_string(),
                state: field[2].to_string(),
                rax: hex(field[3]),
                rcx: hex(field[4]),
                rdx: hex(field[5]),
                flags: hex(field[6]),
                memory: match field.get(7) {
                    Some(&"-") | None => None,
                    Some(text) => Some(bytes(text)),
                },
                stack: match field.get(8) {
                    Some(&"-") | None => None,
                    Some(text) => Some(bytes(text)),
                },
                pointers: (hex(field[9]), hex(field[10]), hex(field[11])),
            }),
            _ => {}
        }
    }
    // **Sans ces lignes, le harnais serait faux en silence** : il partirait de
    // zéro et tomberait juste tant qu'aucune instruction acceptée ne lit un
    // de ces treize registres. C'est exactement ce qui s'est passé jusqu'à
    // `movzbl %bh, %eax`.
    assert_eq!(
        seeded, 13,
        "l'oracle doit déclarer les treize registres fixes, il en déclare {seeded}"
    );
    assert_eq!(
        windows.len(),
        2,
        "l'oracle doit déclarer les deux fenêtres — les données et la pile"
    );
    // **Un enregistrement inconnu est ignoré en silence** — c'est ce que le
    // `_ => {}` plus haut fait, et c'est voulu, pour qu'un corpus plus riche
    // n'exige pas un harnais plus neuf. Mais cette tolérance rendrait une base
    // de segment mal orthographiée invisible : le harnais partirait de zéro et
    // tomberait juste tant qu'aucun cas ne porte le préfixe. Elle est donc
    // exigée ici, comme les treize registres fixes.
    let gs_base = gs_base.expect("l'oracle doit déclarer la base du segment GS");
    Oracle {
        states,
        instructions,
        cases,
        fixed,
        windows,
        gs_base,
    }
}

/// **Tout ce que ces octets peuvent atteindre se décode-t-il ?**
///
/// Avant les sauts, la question était simple : décoder linéairement du début à
/// la fin. Elle ne l'est plus. Un `jmp` en arrière fait repasser sur des octets
/// déjà lus, un `jcc` crée deux suites, et l'octet qui suit un saut
/// inconditionnel peut n'être atteint par personne — le décoder comme du code
/// refuserait des entrées parfaitement exécutables.
///
/// On parcourt donc le **graphe** : depuis l'entrée, chaque bloc jusqu'à son
/// instruction de contrôle, puis ses suites. Une cible hors des octets connus
/// n'est pas un refus : c'est la sortie de la région.
fn decodes_everywhere(bytes: &[u8]) -> bool {
    let mut seen = std::collections::HashSet::new();
    let mut queue = vec![0usize];
    let mut any = false;
    while let Some(mut at) = queue.pop() {
        loop {
            if at >= bytes.len() || !seen.insert(at) {
                break;
            }
            let Some(step) = decode(&bytes[at..]) else {
                return false;
            };
            any = true;
            let after = at + step.length;
            match step.op {
                Op::Jump(condition) => {
                    let target = after as i64 + step.imm as i64;
                    if (0..bytes.len() as i64).contains(&target) {
                        queue.push(target as usize);
                    }
                    if condition.is_none() {
                        break;
                    }
                    at = after;
                }
                Op::LoopWhile => {
                    let target = after as i64 + step.imm as i64;
                    if (0..bytes.len() as i64).contains(&target) {
                        queue.push(target as usize);
                    }
                    at = after;
                }
                // Une cible en registre n'est pas connue à la lecture : le
                // parcours s'arrête là, et l'exécution le dira.
                Op::JumpIndirect => break,
                _ => at = after,
            }
        }
    }
    any
}

/// **Combien de pas au plus.** Les programmes du corpus sont courts — le plus
/// long boucle dix fois — et un cœur qui partirait en rond doit être arrêté
/// plutôt qu'attendu. Dépasser ce budget compte comme un refus, pas comme un
/// écart : on ne compare pas un état qu'on a interrompu.
const BUDGET: usize = 10_000;

/// **L'adresse à laquelle le code de l'invité est chargé.** C'est celle que
/// `oracle.c` donne à son arène — `ARENA + 0x0000` — et elle n'est pas un
/// détail de mise en page : un `call` empile l'adresse de retour, et cette
/// adresse dépend de l'endroit où le programme est posé. Faire tourner le
/// décodeur depuis zéro empilerait `0x0000000d` là où le processeur a empilé
/// `0x3000000d`, et les registres, eux, seraient tous justes.
const CODE: u64 = 0x3000_0000;

/// **Chaque cas que ce cœur prétend connaître doit tomber juste.**
///
/// Le test ne demande pas que tout soit couvert — la tranche annonce le groupe
/// arithmétique et rien d'autre, et une instruction que le décodeur refuse est
/// comptée à part plutôt qu'ignorée. Ce qui n'est pas négociable, c'est qu'une
/// instruction **acceptée** rende exactement ce que le silicium a rendu.
#[test]
fn every_accepted_instruction_matches_the_silicon() {
    let Oracle {
        states,
        instructions,
        cases,
        fixed,
        windows,
        gs_base,
    } = read_oracle();
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
        if !decodes_everywhere(&instruction.bytes) {
            if !refused.contains(&instruction.mnemonic.as_str()) {
                refused.push(&instruction.mnemonic);
            }
            continue;
        }

        let mut cpu = Cpu {
            regs: fixed,
            memory: span(&windows),
            gs_base,
            ..Default::default()
        };
        cpu.regs[0] = state.rax;
        cpu.regs[1] = state.rcx;
        cpu.regs[2] = state.rdx;
        let mut flags = Flags::default();
        flags.write(state.flags);
        cpu.flags = flags;

        // **Exécuter depuis l'entrée, en suivant le pointeur d'instruction.**
        // Dérouler les instructions dans l'ordre du fichier reviendrait à
        // ignorer les sauts tout en prétendant les exécuter.
        let mut steps = 0usize;
        let mut ran_out = false;
        cpu.rip = CODE;
        while (cpu.rip.wrapping_sub(CODE) as usize) < instruction.bytes.len() {
            if steps == BUDGET {
                ran_out = true;
                break;
            }
            steps += 1;
            let at = cpu.rip.wrapping_sub(CODE) as usize;
            if cpu.step(&instruction.bytes[at..]) == Step::Unknown {
                ran_out = true;
                break;
            }
        }
        if ran_out {
            if !refused.contains(&instruction.mnemonic.as_str()) {
                refused.push(&instruction.mnemonic);
            }
            continue;
        }
        checked += 1;

        let got = (cpu.regs[0], cpu.regs[1], cpu.regs[2], cpu.flags.read());
        let want = (case.rax, case.rcx, case.rdx, case.flags);
        let mask = instruction.defined;
        // **La fenêtre compte autant que les registres.** Une écriture au
        // mauvais endroit laisse les trois registres justes, et c'est
        // exactement le genre de faute qu'un cœur peut porter longtemps.
        let expected = span(&[
            (
                windows[0].0,
                case.memory.clone().unwrap_or_else(|| windows[0].1.clone()),
            ),
            (
                windows[1].0,
                case.stack.clone().unwrap_or_else(|| windows[1].1.clone()),
            ),
        ]);
        let expected_memory = &expected.bytes;
        let pointers = (cpu.regs[4], cpu.regs[5], cpu.regs[6]);
        if cpu.faulted
            || &cpu.memory.bytes != expected_memory
            || got.0 != want.0
            || got.1 != want.1
            || got.2 != want.2
            || pointers != case.pointers
            || (got.3 & mask) != (want.3 & mask)
        {
            if wrong.len() < 12 {
                wrong.push(format!(
                    "{} état {} : rax {:x}≠{:x} rcx {:x}≠{:x} rdx {:x}≠{:x} \
                     rsp {:x}≠{:x} rbp {:x}≠{:x} rsi {:x}≠{:x} \
                     drapeaux {:x}≠{:x} (masque {:x}){}{}",
                    instruction.mnemonic,
                    case.state,
                    got.0,
                    want.0,
                    got.1,
                    want.1,
                    got.2,
                    want.2,
                    pointers.0,
                    case.pointers.0,
                    pointers.1,
                    case.pointers.1,
                    pointers.2,
                    case.pointers.2,
                    got.3 & mask,
                    want.3 & mask,
                    mask,
                    if cpu.faulted {
                        " — accès hors de la fenêtre"
                    } else {
                        ""
                    },
                    if &cpu.memory.bytes != expected_memory {
                        format!(
                            "\n  mémoire {}\n       ≠ {}",
                            hexadecimal(&cpu.memory.bytes),
                            hexadecimal(expected_memory)
                        )
                    } else {
                        String::new()
                    },
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
        checked > 12420,
        "le décodeur ne reconnaît plus que {checked} cas : la couverture a reculé"
    );
    // **Et le cliquet dans l'autre sens.** Un plancher sur les cas vérifiés ne
    // voit pas une instruction qui passe de « juste » à « refusée » : elle
    // sort du compte au lieu d'y échouer. Un sabotage l'a montré — casser le
    // SIB sans base faisait refuser les deux formes concernées, et le test
    // restait vert. Ce nombre-là ne doit donc jamais monter.
    assert!(
        refused.len() <= 3,
        "le décodeur refuse maintenant {} instructions au lieu de 3 : \
         quelque chose qu'il savait lire ne se décode plus\n{}",
        refused.len(),
        refused.join("\n")
    );
}
