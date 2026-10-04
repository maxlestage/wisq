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
    /// **RSP, RBP, RSI et RDI.** Les quatre seuls registres que le corpus
    /// autorise à bouger — le script vérifie que les autres ne bougent pas — et
    /// donc les quatre seuls qu'il doit relever. Un sabotage l'a montré :
    /// `leave` qui dépile **avant** de reprendre RBP laisse RAX, RCX, RDX, les
    /// drapeaux et les deux fenêtres exactement justes, et passait.
    ///
    /// RDI est le dernier arrivé, avec les instructions de chaîne : `rep stos`
    /// l'avance d'autant d'octets qu'il en écrit. Il était dans la liste des
    /// registres qui ne doivent pas bouger ; l'y laisser aurait obligé à
    /// écarter ces programmes-là, c'est-à-dire à ne pas les juger.
    pointers: (u64, u64, u64, u64),
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
                pointers: (
                    hex(field[9]),
                    hex(field[10]),
                    hex(field[11]),
                    hex(field[12]),
                ),
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
                // Les trois `loop` et `jrcxz` : une cible relative connue à la
                // lecture, et le chemin qui tombe à côté continue — comme un
                // saut conditionnel.
                Op::LoopWhile { .. } | Op::JumpIfCountZero => {
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
        let pointers = (cpu.regs[4], cpu.regs[5], cpu.regs[6], cpu.regs[7]);
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
                     rsp {:x}≠{:x} rbp {:x}≠{:x} rsi {:x}≠{:x} rdi {:x}≠{:x} \
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
                    pointers.3,
                    case.pointers.3,
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
    //
    // **Et ce plancher ne peut pas être dérivé du fichier.** Il garde contre un
    // corpus qui RÉTRÉCIT, et le comparer à `oracle.cases.len()` serait
    // circulaire : les deux côtés tomberaient ensemble. #267 a fait cette
    // erreur sur l'émetteur — en remplaçant son plancher par une égalité, elle
    // a retiré la seule chose qui voyait une fixture tronquée. Mesuré : en
    // retirant 200 lignes `cas` du fichier, les trois cœurs restaient **verts**,
    // celui-ci à 13 188 cas contre un plancher de 13 140.
    //
    // Il doit donc rester un nombre écrit à la main, et sa seule discipline est
    // de valoir le corpus du jour — 13 388 cas au moment de #268.
    assert!(
        checked >= 13388,
        "le décodeur ne reconnaît plus que {checked} cas : la couverture a reculé"
    );
    // **Et le cliquet dans l'autre sens.** Un plancher sur les cas vérifiés ne
    // voit pas une instruction qui passe de « juste » à « refusée » : elle
    // sort du compte au lieu d'y échouer. Un sabotage l'a montré — casser le
    // SIB sans base faisait refuser les deux formes concernées, et le test
    // restait vert.
    //
    // **Il n'y en a plus aucune.** Ce cliquet a valu 85, puis 3 — les trois
    // formes de chaîne de bits — et vaut maintenant zéro : le décodeur lit tout
    // ce que le corpus matériel contient. C'est la borne la plus dure qu'il
    // puisse porter, et elle ne peut plus que se relâcher.
    assert!(
        refused.is_empty(),
        "le décodeur refuse maintenant {} instructions au lieu d'aucune : \
         quelque chose qu'il savait lire ne se décode plus\n{}",
        refused.len(),
        refused.join("\n")
    );
}

/// **Le corpus de pile, et pourquoi ce fichier-ci ne le lisait pas.**
///
/// `Tests/Fixtures/x86-stack-oracle.tsv` relève **les seize registres**, là où
/// le corpus arithmétique n'en relève que sept — RAX, RCX, RDX, et les quatre
/// pointeurs qu'il autorise à bouger. Il contient `5c` (`pop %rsp`) et `54`
/// (`push %rsp`), que l'autre ne contient pas.
///
/// Il n'était lu que par le cœur Swift. #300 a payé ça d'un `pop %rsp` faux
/// dans l'émetteur et de tout le mur du bureau ; #301 l'a branché sur
/// l'émetteur et y a trouvé `pushw` du premier coup. L'interpréteur Rust était
/// le dernier des trois à ne pas être tenu — et il portait le même défaut.
struct StackOracle {
    states: HashMap<String, ([u64; 16], u64)>,
    instructions: HashMap<String, (Vec<u8>, u64, String)>,
    cases: Vec<StackCase>,
    windows: Vec<(u64, Vec<u8>)>,
}

struct StackCase {
    instruction: String,
    state: String,
    regs: [u64; 16],
    flags: u64,
    data: Option<Vec<u8>>,
    stack: Option<Vec<u8>>,
}

fn read_stack_oracle() -> StackOracle {
    let path = oracle_path()
        .parent()
        .expect("le répertoire des fixtures")
        .join("x86-stack-oracle.tsv");
    let text = std::fs::read_to_string(&path).expect("Tests/Fixtures/x86-stack-oracle.tsv");
    let mut states = HashMap::new();
    let mut instructions = HashMap::new();
    let mut cases = Vec::new();
    let sixteen = |fields: &[&str], from: usize| -> [u64; 16] {
        let mut regs = [0u64; 16];
        for (slot, value) in regs.iter_mut().enumerate() {
            *value = hex(fields[from + slot]);
        }
        regs
    };
    for line in text.lines() {
        if line.starts_with('#') || line.trim().is_empty() {
            continue;
        }
        let f: Vec<&str> = line.split('\t').collect();
        match f[0] {
            "état" if f.len() == 19 => {
                states.insert(f[1].to_string(), (sixteen(&f, 2), hex(f[18])));
            }
            "instr" if f.len() == 5 => {
                instructions.insert(f[1].to_string(), (bytes(f[2]), hex(f[3]), f[4].to_string()));
            }
            "cas" if f.len() == 22 => cases.push(StackCase {
                instruction: f[1].to_string(),
                state: f[2].to_string(),
                regs: sixteen(&f, 3),
                flags: hex(f[19]),
                data: match f[20] {
                    "-" => None,
                    hexadecimal => Some(bytes(hexadecimal)),
                },
                stack: match f[21] {
                    "-" => None,
                    hexadecimal => Some(bytes(hexadecimal)),
                },
            }),
            _ => {}
        }
    }
    assert_eq!(states.len(), 8, "les huit états du corpus de pile");
    assert_eq!(instructions.len(), 81, "ses quatre-vingt-une formes");
    assert_eq!(cases.len(), 648, "et ses six cent quarante-huit cas");
    // **Les fenêtres viennent du fichier qui les déclare**, et non de ce code :
    // le corpus de pile ne les porte pas, le corpus arithmétique si, et les
    // deux partagent les mêmes à l'octet près. Les reconstruire ici
    // comparerait le résultat du cœur à un motif que j'aurais écrit.
    let windows = read_oracle().windows;
    assert_eq!(
        windows
            .iter()
            .map(|(at, w)| (*at, w.len()))
            .collect::<Vec<_>>(),
        vec![(0x3000_1000u64, 64usize), (0x3000_2fc0, 128)],
        "les deux fenêtres que les deux corpus partagent"
    );
    StackOracle {
        states,
        instructions,
        cases,
        windows,
    }
}

/// **Le sommet de pile que le harnais pose**, comme le pilote du corpus, comme
/// le test Swift et comme celui de l'émetteur : le corpus ne le porte pas en
/// entrée, « pour qu'un cas qui déborde n'écrase pas le harnais ».
const STACK_TOP: u64 = 0x3000_3000;

/// Les noms des seize registres, pour qu'un écart dise « rsp » et non « 4 ».
const STACK_REGISTER_NAMES: [&str; 16] = [
    "rax", "rcx", "rdx", "rbx", "rsp", "rbp", "rsi", "rdi", "r8", "r9", "r10", "r11", "r12", "r13",
    "r14", "r15",
];

/// **Le plancher du corpus de pile pour l'interpréteur**, mesuré et non
/// souhaité.
///
/// 568 cas jugés sur 648, zéro écart. Les 80 qui manquent sont dix formes que
/// le **décodeur** ne décode pas, et le relevé les nomme quand le plancher
/// tombe :
///
/// - les formes **courtes** de seize bits — `66 50`, `66 55`, `66 68`,
///   `66 58`, `66 5d` — refusées à dessein par `if !prefixes.operand_size` ;
///   les formes longues (`ff /6`), elles, sont décodées et désormais justes ;
/// - **tout le groupe `8f /0`** — `pop (%rsi)`, `pop %rax`, `pop %rbp`,
///   `popw %bp` —, y compris en soixante-quatre bits. Pas une largeur qui
///   manque : un opcode entier. Un noyau dépile par `5d`, donc ça ne l'a
///   jamais arrêté ; c'est un trou nommé, et l'émetteur a le même.
///
/// L'interpréteur en juge **seize de plus** que l'émetteur (552), parce que
/// l'émetteur refuse en plus les `pushw` qu'il ne sait pas descendre de deux.
/// Les deux sont justes là où ils agissent ; ils ne couvrent simplement pas la
/// même étendue.
const STACK_CASES_FLOOR: usize = 568;

/// **L'interpréteur Rust jugé sur le corpus de pile, les seize registres
/// comparés.** Le jumeau de `every_accepted_instruction_matches_the_silicon`,
/// sur l'autre corpus, et le troisième cœur enfin tenu sur la pile.
#[test]
fn every_accepted_instruction_matches_the_silicon_on_the_stack_corpus() {
    let oracle = read_stack_oracle();
    let mut checked = 0usize;
    let mut refused: Vec<String> = Vec::new();
    let mut wrong: Vec<String> = Vec::new();

    for case in &oracle.cases {
        let (program, mask, mnemonic) = &oracle.instructions[&case.instruction];
        let (before, before_flags) = oracle.states[&case.state];
        if !decodes_everywhere(program) {
            if !refused.contains(mnemonic) {
                refused.push(mnemonic.clone());
            }
            continue;
        }
        let mut regs = before;
        regs[4] = STACK_TOP;
        let mut cpu = Cpu {
            regs,
            memory: span(&oracle.windows),
            ..Default::default()
        };
        let mut flags = Flags::default();
        flags.write(before_flags);
        cpu.flags = flags;
        cpu.rip = CODE;

        let mut steps = 0usize;
        let mut ran_out = false;
        while (cpu.rip.wrapping_sub(CODE) as usize) < program.len() {
            if steps == BUDGET {
                ran_out = true;
                break;
            }
            steps += 1;
            let at = cpu.rip.wrapping_sub(CODE) as usize;
            if cpu.step(&program[at..]) == Step::Unknown {
                ran_out = true;
                break;
            }
        }
        if ran_out {
            if !refused.contains(mnemonic) {
                refused.push(mnemonic.clone());
            }
            continue;
        }
        checked += 1;

        let expected = span(&[
            (
                oracle.windows[0].0,
                case.data
                    .clone()
                    .unwrap_or_else(|| oracle.windows[0].1.clone()),
            ),
            (
                oracle.windows[1].0,
                case.stack
                    .clone()
                    .unwrap_or_else(|| oracle.windows[1].1.clone()),
            ),
        ]);
        let mut notes: Vec<String> = Vec::new();
        if cpu.faulted {
            notes.push("le cœur a fauté".to_string());
        }
        for (slot, name) in STACK_REGISTER_NAMES.iter().enumerate() {
            if cpu.regs[slot] != case.regs[slot] {
                notes.push(format!(
                    "{name} attendu {:x}, obtenu {:x}",
                    case.regs[slot], cpu.regs[slot]
                ));
            }
        }
        if (cpu.flags.read() & mask) != (case.flags & mask) {
            notes.push(format!(
                "drapeaux attendus {:x}, obtenus {:x} (masque {mask:x})",
                case.flags & mask,
                cpu.flags.read() & mask
            ));
        }
        if cpu.memory.bytes != expected.bytes {
            notes.push("la mémoire diffère (fenêtre de données ou de pile)".to_string());
        }
        if !notes.is_empty() && wrong.len() < 20 {
            wrong.push(format!(
                "{mnemonic} [état {}] : {}",
                case.state,
                notes.join(" ; ")
            ));
        }
    }

    assert!(
        wrong.is_empty(),
        "{} écart(s) entre l'interpréteur et le silicium sur le corpus de pile :\n{}",
        wrong.len(),
        wrong.join("\n")
    );
    assert!(
        checked >= STACK_CASES_FLOOR,
        "l'interpréteur ne juge plus que {checked} cas de pile sur {} ; \
         formes refusées : {refused:?}",
        oracle.cases.len()
    );
}

/// **Le corpus de chaîne, et pourquoi aucun cœur Rust ne le lisait.**
///
/// `Tests/Fixtures/x86-string-oracle.tsv` est né d'un comptage : sur les 389
/// formes du corpus arithmétique, *aucune* n'était un `MOVS`, `STOS`, `SCAS`,
/// `CMPS` ou `LODS`. La mesure tient encore, et dans les deux corpus que ce
/// fichier lit : `grep -o "rep [a-z]*"` en rend **zéro**, sur l'arithmétique
/// comme sur la pile. Les deux cœurs Rust n'avaient donc jamais été comparés
/// au silicium sur une seule instruction de chaîne, alors que tous les deux en
/// exécutent.
///
/// Ce n'est pas une classe accessoire : `copy_to_user` et `copy_from_user`
/// sont des `rep movsq` et des `rep movsb`, et le `memset` d'une table de
/// pages est un `rep stos`.
///
/// **Les deux branchements précédents ont rendu seize écarts chacun** — #301
/// pour l'émetteur sur la pile, #302 pour ce cœur-ci. Un corpus qu'on branche
/// n'est pas une formalité, et c'est la raison de brancher celui-là aussi.
struct StringOracle {
    /// `rax`, `rsi`, `rdi`, drapeaux. RCX n'y est pas : il vient de la forme,
    /// parce que c'est le compte que la répétition consomme.
    states: HashMap<String, (u64, u64, u64, u64)>,
    instructions: HashMap<String, (Vec<u8>, u64, String)>,
    cases: Vec<StringCase>,
    window: (u64, Vec<u8>),
}

struct StringCase {
    instruction: String,
    state: String,
    rax: u64,
    rcx: u64,
    rsi: u64,
    rdi: u64,
    flags: u64,
    memory: Option<Vec<u8>>,
}

/// **Les drapeaux que ce corpus compare** : retenue, parité, auxiliaire, zéro,
/// signe, débordement — le masque `X86Core.Flag.arithmetic` du cœur Swift, qui
/// lit déjà ce fichier. Le corpus ne porte pas de colonne de masque, et il n'en
/// a pas besoin : les treize valeurs distinctes qu'il enregistre sont toutes
/// comprises dans ce masque, sans le drapeau de direction — qui est une
/// **entrée** du cas — ni le bit réservé.
const STRING_FLAGS: u64 = 0x8d5;

/// **Le témoin des registres qu'aucune chaîne ne doit toucher**, celui de
/// `X86StringOracleTests` à l'octet près.
fn string_witness(slot: usize) -> u64 {
    0xAAAA_AAAA_AAAA_AAAAu64.wrapping_add(slot as u64)
}

/// RBX et R8 à R15 : ceux que le test Swift relève. RAX, RCX, RSI et RDI sont
/// justement ceux qu'une chaîne travaille.
const STRING_WATCHED: [usize; 9] = [3, 8, 9, 10, 11, 12, 13, 14, 15];

fn read_string_oracle() -> StringOracle {
    let path = oracle_path()
        .parent()
        .expect("le répertoire des fixtures")
        .join("x86-string-oracle.tsv");
    let text = std::fs::read_to_string(&path).expect("Tests/Fixtures/x86-string-oracle.tsv");
    let mut states = HashMap::new();
    let mut instructions = HashMap::new();
    let mut cases = Vec::new();
    for line in text.lines() {
        if line.starts_with('#') || line.trim().is_empty() {
            continue;
        }
        let f: Vec<&str> = line.split('\t').collect();
        match f[0] {
            // `état <indice> <rax> <rsi> <rdi> <drapeaux>`
            "état" if f.len() == 6 => {
                states.insert(
                    f[1].to_string(),
                    (hex(f[2]), hex(f[3]), hex(f[4]), hex(f[5])),
                );
            }
            // `instr <indice> <octets> <RCX de départ> <mnémonique>`
            //
            // **Le compte est en décimal**, et c'est le seul champ du fichier à
            // l'être : le lire en hexadécimal donnerait 50 pour « 32 » et 22
            // pour « 16 », un `rep movsb` sortirait de sa demi-fenêtre, et
            // l'écart serait mis sur le dos du cœur. Le lecteur Swift le lit
            // déjà ainsi.
            "instr" if f.len() == 5 => {
                let count = f[3].parse::<u64>().expect("un compte décimal");
                instructions.insert(f[1].to_string(), (bytes(f[2]), count, f[4].to_string()));
            }
            // `cas <instr> <état> <rax> <rcx> <rsi> <rdi> <drapeaux> <mémoire>`
            "cas" if f.len() == 9 => cases.push(StringCase {
                instruction: f[1].to_string(),
                state: f[2].to_string(),
                rax: hex(f[3]),
                rcx: hex(f[4]),
                rsi: hex(f[5]),
                rdi: hex(f[6]),
                flags: hex(f[7]),
                memory: match f[8] {
                    "-" => None,
                    hexadecimal => Some(bytes(hexadecimal)),
                },
            }),
            _ => {}
        }
    }
    assert_eq!(states.len(), 8, "les huit états du corpus de chaîne");
    assert_eq!(instructions.len(), 47, "ses quarante-sept formes");
    assert_eq!(cases.len(), 376, "et ses trois cent soixante-seize cas");
    // **La fenêtre vient du fichier qui la déclare**, pas de ce code : le
    // corpus de chaîne ne la porte pas, le corpus arithmétique si, et le test
    // Swift la reconstruit en 0x10 + i. Les trois doivent tomber d'accord, et
    // ce test l'exige plutôt que de le supposer.
    let window = read_oracle()
        .windows
        .into_iter()
        .next()
        .expect("la fenêtre de données du corpus arithmétique");
    assert_eq!(
        window.0, 0x3000_1000,
        "l'adresse que l'en-tête du corpus dit"
    );
    assert_eq!(
        window.1,
        (0..64u8).map(|i| 0x10 + i).collect::<Vec<u8>>(),
        "le motif que `X86StringOracleTests.pristine` pose"
    );
    StringOracle {
        states,
        instructions,
        cases,
        window,
    }
}

/// **Le plancher du corpus de chaîne pour l'interpréteur**, à mesurer.
const STRING_CASES_FLOOR: usize = 144;

/// **L'interpréteur Rust jugé sur le corpus de chaîne.** Le jumeau de
/// `every_accepted_instruction_matches_the_silicon_on_the_stack_corpus`, sur le
/// troisième corpus — et, comme lui, le refus d'une forme est **compté et
/// nommé** plutôt qu'ignoré.
#[test]
fn every_accepted_instruction_matches_the_silicon_on_the_string_corpus() {
    let oracle = read_string_oracle();
    let mut checked = 0usize;
    let mut refused: Vec<String> = Vec::new();
    let mut wrong: Vec<String> = Vec::new();

    for case in &oracle.cases {
        let (program, count, mnemonic) = &oracle.instructions[&case.instruction];
        let (rax, rsi, rdi, flags) = oracle.states[&case.state];
        if !decodes_everywhere(program) {
            if !refused.contains(mnemonic) {
                refused.push(mnemonic.clone());
            }
            continue;
        }
        // **Le témoin d'abord.** Un cœur qui lirait un registre que le corpus
        // ne pose pas tomberait juste tant que ce registre vaut zéro.
        let mut regs = [0u64; 16];
        for (slot, value) in regs.iter_mut().enumerate() {
            *value = string_witness(slot);
        }
        regs[0] = rax;
        regs[1] = *count;
        regs[4] = STACK_TOP;
        regs[6] = rsi;
        regs[7] = rdi;
        // **L'arène, et non la fenêtre.** Une chaîne **en arrière** descend
        // sous l'adresse de la fenêtre : `rep movsw` depuis l'état 4 part de
        // `0x30001018` et finit RSI à `0x30000ff8`, le silicium le dit. Une
        // mémoire limitée aux soixante-quatre octets faisait fauter le cœur sur
        // les quatre états en arrière — et c'est le harnais qui plantait, pas
        // l'instruction. Le même piège a déjà coûté un tour à ce corpus la
        // première fois qu'il a été écrit : « l'ABI exige que le drapeau de
        // direction soit effacé à la sortie de toute fonction, et le `memcpy`
        // du pilote partait à l'envers ». L'arène est donc celle du test Swift,
        // à l'octet près : seize kibioctets depuis `0x30000000`, la fenêtre
        // posée à `0x30001000`, et des zéros partout ailleurs — ce que le
        // silicium avait, puisque les cas en arrière lisent dessous et que leur
        // résultat enregistré est fait de ces zéros-là.
        let mut arena = GuestMemory {
            base: CODE,
            bytes: vec![0; 0x4000],
        };
        let at = (oracle.window.0 - CODE) as usize;
        arena.bytes[at..at + oracle.window.1.len()].copy_from_slice(&oracle.window.1);
        let mut cpu = Cpu {
            regs,
            memory: arena,
            ..Default::default()
        };
        let mut written = Flags::default();
        written.write(flags);
        cpu.flags = written;
        cpu.rip = CODE;

        let mut steps = 0usize;
        let mut ran_out = false;
        while (cpu.rip.wrapping_sub(CODE) as usize) < program.len() {
            if steps == BUDGET {
                ran_out = true;
                break;
            }
            steps += 1;
            let at = cpu.rip.wrapping_sub(CODE) as usize;
            if cpu.step(&program[at..]) == Step::Unknown {
                ran_out = true;
                break;
            }
        }
        if ran_out {
            if !refused.contains(mnemonic) {
                refused.push(mnemonic.clone());
            }
            continue;
        }
        checked += 1;

        let mut notes: Vec<String> = Vec::new();
        if cpu.faulted {
            notes.push("le cœur a fauté".to_string());
        }
        for (slot, want, name) in [
            (0usize, case.rax, "rax"),
            (1, case.rcx, "rcx"),
            (6, case.rsi, "rsi"),
            (7, case.rdi, "rdi"),
        ] {
            if cpu.regs[slot] != want {
                notes.push(format!(
                    "{name} attendu {want:x}, obtenu {:x}",
                    cpu.regs[slot]
                ));
            }
        }
        for slot in STRING_WATCHED {
            if cpu.regs[slot] != string_witness(slot) {
                notes.push(format!(
                    "{} a bougé : {:x} au lieu du témoin {:x}",
                    STACK_REGISTER_NAMES[slot],
                    cpu.regs[slot],
                    string_witness(slot)
                ));
            }
        }
        if (cpu.flags.read() & STRING_FLAGS) != case.flags {
            notes.push(format!(
                "drapeaux attendus {:x}, obtenus {:x} (masque {STRING_FLAGS:x})",
                case.flags,
                cpu.flags.read() & STRING_FLAGS
            ));
        }
        // **La fenêtre, pas l'arène** : le corpus n'enregistre que ces
        // soixante-quatre octets, et exiger le reste comparerait le cœur à des
        // octets que personne n'a relevés.
        let want = case
            .memory
            .clone()
            .unwrap_or_else(|| oracle.window.1.clone());
        if cpu.memory.bytes[at..at + want.len()] != want[..] {
            notes.push("la fenêtre de données diffère".to_string());
        }
        if !notes.is_empty() && wrong.len() < 20 {
            wrong.push(format!(
                "{mnemonic} [état {}] : {}",
                case.state,
                notes.join(" ; ")
            ));
        }
    }

    assert!(
        wrong.is_empty(),
        "{} écart(s) entre l'interpréteur et le silicium sur le corpus de chaîne :\n{}",
        wrong.len(),
        wrong.join("\n")
    );
    assert!(
        checked >= STRING_CASES_FLOOR,
        "l'interpréteur ne juge plus que {checked} cas de chaîne sur {} ; \
         formes refusées : {refused:?}",
        oracle.cases.len()
    );
}

/// **Le corpus de branchement, et pourquoi ce fichier-ci ne le lisait pas.**
///
/// `Tests/Fixtures/x86-branch-oracle.tsv` est né d'un comptage : le chargeur
/// dynamique de l'invité contient « 4 659 `jmp`, 4 436 `call`, 1 851 `ret` et
/// près de neuf mille sauts conditionnels », et les corpus figés d'alors n'en
/// portaient aucune forme. Il ne jugeait que le cœur Swift.
///
/// **Chaque cas est un programme**, pas une instruction : chaque bras écrit une
/// marque dans RAX — `a1` pris, `b2` tombé à côté, `c3` jamais entré dans la
/// boucle —, et RSP dit que la pile est revenue là où elle était.
struct BranchOracle {
    /// L'état d'entrée n'est **que** les drapeaux : c'est tout ce qu'une
    /// condition lit.
    states: HashMap<String, u64>,
    programs: HashMap<String, (Vec<u8>, String)>,
    cases: Vec<BranchCase>,
}

struct BranchCase {
    program: String,
    state: String,
    rax: u64,
    rcx: u64,
    rdx: u64,
    rsp: u64,
    flags: u64,
}

/// L'adresse où pointe RSI, et dont les deux formes indirectes par la mémoire
/// se servent — elles y **écrivent** leur cible avant de la lire, donc son
/// contenu de départ n'entre pas dans le résultat.
const BRANCH_WINDOW_AT: u64 = 0x3000_1000;

/// **Le plancher du corpus de branchement pour l'interpréteur**, mesuré.
///
/// 580 cas sur 630. Les 50 qui manquent sont cinq formes que le **décodeur**
/// ne décode pas : `loope` (`0xe1`), `loopne` (`0xe0`), les deux `jrcxz`
/// (`0xe3`) et `ret` qui jette ses arguments (`0xc2`). `loop` (`0xe2`), lui,
/// est décodé — un des quatre opcodes d'une même famille implémenté et trois
/// oubliés. Le cœur Swift les porte tous. Le relevé les nomme quand ce plancher
/// tombe, et il passera à 630 le jour où les quatre arriveront.
const BRANCH_CASES_FLOOR: usize = 630;

fn read_branch_oracle() -> BranchOracle {
    let path = oracle_path()
        .parent()
        .expect("le répertoire des fixtures")
        .join("x86-branch-oracle.tsv");
    let text = std::fs::read_to_string(&path).expect("Tests/Fixtures/x86-branch-oracle.tsv");
    let mut states = HashMap::new();
    let mut programs = HashMap::new();
    let mut cases = Vec::new();
    for line in text.lines() {
        if line.starts_with('#') || line.trim().is_empty() {
            continue;
        }
        let f: Vec<&str> = line.split('\t').collect();
        match f[0] {
            // `état <indice> <drapeaux>`
            "état" if f.len() == 3 => {
                states.insert(f[1].to_string(), hex(f[2]));
            }
            // `instr <indice> <octets> <nom>`
            "instr" if f.len() == 4 => {
                programs.insert(f[1].to_string(), (bytes(f[2]), f[3].to_string()));
            }
            // `cas <instr> <état> <rax> <rcx> <rdx> <rsp> <drapeaux>`
            "cas" if f.len() == 8 => cases.push(BranchCase {
                program: f[1].to_string(),
                state: f[2].to_string(),
                rax: hex(f[3]),
                rcx: hex(f[4]),
                rdx: hex(f[5]),
                rsp: hex(f[6]),
                flags: hex(f[7]),
            }),
            _ => {}
        }
    }
    assert_eq!(states.len(), 10, "les dix états de drapeaux du corpus");
    assert_eq!(programs.len(), 63, "ses soixante-trois programmes");
    assert_eq!(cases.len(), 630, "et ses six cent trente cas");
    BranchOracle {
        states,
        programs,
        cases,
    }
}

/// **L'interpréteur Rust jugé sur le corpus de branchement.** Le jumeau de
/// `every_accepted_instruction_matches_the_silicon_on_the_string_corpus`, sur le
/// quatrième corpus — et, comme lui, un refus est **compté et nommé** plutôt
/// qu'ignoré.
///
/// **L'arène, et non une fenêtre.** Le programme vit à `CODE`, la pile descend
/// depuis `0x30003000` et RSI pointe `0x30001000` : il faut une mémoire qui
/// couvre les trois. Seize kibioctets depuis `CODE`, comme le test Swift.
#[test]
fn every_accepted_instruction_matches_the_silicon_on_the_branch_corpus() {
    let oracle = read_branch_oracle();
    let mut checked = 0usize;
    let mut refused: Vec<String> = Vec::new();
    let mut wrong: Vec<String> = Vec::new();

    for case in &oracle.cases {
        let (program, name) = &oracle.programs[&case.program];
        let flags = oracle.states[&case.state];
        if !decodes_everywhere(program) {
            if !refused.contains(name) {
                refused.push(name.clone());
            }
            continue;
        }
        // **Le témoin d'abord**, puis les trois registres que le test Swift
        // pose : RAX à zéro pour qu'une marque soit lisible, le sommet de pile,
        // et RSI sur la fenêtre des formes indirectes par la mémoire.
        let mut regs = [0u64; 16];
        for (slot, value) in regs.iter_mut().enumerate() {
            *value = string_witness(slot);
        }
        regs[0] = 0;
        regs[4] = STACK_TOP;
        regs[6] = BRANCH_WINDOW_AT;
        let mut cpu = Cpu {
            regs,
            memory: GuestMemory {
                base: CODE,
                bytes: vec![0; 0x4000],
            },
            ..Default::default()
        };
        let mut written = Flags::default();
        written.write(flags);
        cpu.flags = written;
        cpu.rip = CODE;

        let end = CODE + program.len() as u64;
        let mut steps = 0usize;
        let mut ran_out = false;
        // **Un programme entier, jusqu'à ce qu'on en sorte par le bas**, et un
        // budget qui borne les boucles : un cœur qui saute mal pourrait tourner
        // sans fin, et un test qui pend n'est pas un test qui échoue.
        while cpu.rip >= CODE && cpu.rip < end {
            if steps == 512 {
                ran_out = true;
                break;
            }
            steps += 1;
            let at = cpu.rip.wrapping_sub(CODE) as usize;
            if cpu.step(&program[at..]) == Step::Unknown {
                ran_out = true;
                break;
            }
        }
        if ran_out {
            if !refused.contains(name) {
                refused.push(name.clone());
            }
            continue;
        }
        checked += 1;

        let mut notes: Vec<String> = Vec::new();
        if cpu.faulted {
            notes.push("le cœur a fauté".to_string());
        }
        for (slot, want, label) in [
            (0usize, case.rax, "rax"),
            (1, case.rcx, "rcx"),
            (2, case.rdx, "rdx"),
            (4, case.rsp, "rsp"),
        ] {
            if cpu.regs[slot] != want {
                notes.push(format!(
                    "{label} attendu {want:x}, obtenu {:x}",
                    cpu.regs[slot]
                ));
            }
        }
        for slot in STRING_WATCHED {
            if cpu.regs[slot] != string_witness(slot) {
                notes.push(format!(
                    "{} a bougé : {:x} au lieu du témoin {:x}",
                    STACK_REGISTER_NAMES[slot],
                    cpu.regs[slot],
                    string_witness(slot)
                ));
            }
        }
        if (cpu.flags.read() & STRING_FLAGS) != case.flags {
            notes.push(format!(
                "drapeaux attendus {:x}, obtenus {:x} (masque {STRING_FLAGS:x})",
                case.flags,
                cpu.flags.read() & STRING_FLAGS
            ));
        }
        if !notes.is_empty() && wrong.len() < 20 {
            wrong.push(format!(
                "{name} [état {}] : {}",
                case.state,
                notes.join(" ; ")
            ));
        }
    }

    assert!(
        wrong.is_empty(),
        "{} écart(s) entre l'interpréteur et le silicium sur le corpus de branchement :\n{}",
        wrong.len(),
        wrong.join("\n")
    );
    assert!(
        checked >= BRANCH_CASES_FLOOR,
        "l'interpréteur ne juge plus que {checked} cas de branchement sur {} ; \
         formes refusées : {refused:?}",
        oracle.cases.len()
    );
}
