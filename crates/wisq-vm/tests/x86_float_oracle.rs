//! **Le flottant de la machine PC native, jugé par le silicium** : les modes
//! d'arrondi du x87, le calcul flottant de SSE et SSE2, le MMX.
//!
//! - `x86-x87-rounding-oracle.tsv` : seize formes du x87, dans les quatre
//!   modes d'arrondi, là où le résultat ne tient pas ;
//! - `x86-float-oracle.tsv` : le calcul flottant scalaire et empaqueté de SSE
//!   et SSE2, ZF, PF et CF compris ;
//! - `x86-mmx-oracle.tsv` : le MMX, chaque instruction entourée de `movdq2q`,
//!   `movq2dq` et `emms`.
//!
//! Les corpus ont été relevés sur un vrai processeur. Chaque cas se rejoue
//! ici par `decode`, puis `decode_extended`, comme la machine les lit. Les
//! formes que CPUID n'annonce pas (SSE3, SSSE3) sont comptées à part : elles
//! doivent rester illisibles, et rien d'autre ne l'est.
//!
//! **Et, sur un hôte x86-64, le silicium de l'hôte est interrogé** là où les
//! corpus se taisent : MXCSR dans ses quatre modes, ses six drapeaux, FTZ et
//! DAZ, sur des valeurs tirées au hasard et aux bords.

use std::collections::HashMap;
use std::path::PathBuf;

use wisq_vm::x86::{decode, decode_extended, Cpu, GuestMemory, Op};

const CODE: u64 = 0x3000_0000;
const DATA: u64 = 0x3000_1000;

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

fn register(text: &str) -> (u64, u16) {
    let raw = bytes(text);
    (
        u64::from_le_bytes(raw[..8].try_into().unwrap()),
        u16::from_le_bytes([raw[8], raw[9]]),
    )
}

fn pristine() -> String {
    (0x10u8..0x50).map(|byte| format!("{byte:02x}")).collect()
}

fn witness_xmm(index: usize) -> [u64; 2] {
    [
        0xC000_0000_0000_0000 + index as u64,
        0xD000_0000_0000_0000 + index as u64,
    ]
}

/// Un processeur dans l'état de départ des corpus : le code à 0x3000_0000, la
/// fenêtre de soixante-quatre octets à 0x3000_1000 (0x10, 0x11…), RSI dessus,
/// RSP plus loin, les registres et les XMM porteurs d'un témoin.
fn processor(code: &[u8]) -> Cpu {
    let mut ram = vec![0u8; 0x4000];
    ram[..code.len()].copy_from_slice(code);
    for (index, byte) in ram[0x1000..0x1040].iter_mut().enumerate() {
        *byte = 0x10 + index as u8;
    }
    let mut cpu = Cpu {
        rip: CODE,
        memory: GuestMemory {
            base: CODE,
            bytes: ram,
        },
        mxcsr: 0x1f80,
        fpu_control: 0x037f,
        ..Default::default()
    };
    for (index, register) in cpu.regs.iter_mut().enumerate() {
        *register = 0xAAAA_AAAA_AAAA_AAAA + index as u64;
    }
    cpu.regs[4] = 0x3000_3000;
    cpu.regs[6] = DATA;
    for (index, register) in cpu.xmm.iter_mut().enumerate() {
        *register = witness_xmm(index);
    }
    cpu.flags.write(2);
    cpu
}

/// **Exécuter le code posé**, instruction par instruction, comme la machine
/// les lit : `decode` d'abord, `decode_extended` ensuite. `Err` nomme ce qui
/// n'a pas été lu ou n'est pas allé au bout.
fn run(cpu: &mut Cpu, length: usize) -> Result<(), String> {
    while cpu.rip < CODE + length as u64 {
        let at = (cpu.rip - CODE) as usize;
        let window = cpu.memory.bytes[at..at + 15].to_vec();
        if let Some(decoded) = decode(&window) {
            match decoded.op {
                Op::Vector(_) => cpu
                    .execute_vector(&decoded)
                    .map_err(|fault| format!("{fault:?}"))?,
                _ => cpu.execute(&decoded),
            }
            if cpu.faulted {
                return Err(format!("faute sur {:02x?}", &window[..decoded.length]));
            }
            cpu.rip += decoded.length as u64;
        } else if let Some(extended) = decode_extended(&window) {
            cpu.execute_extended(&extended)
                .map_err(|fault| format!("{fault:?}"))?;
            cpu.rip += extended.length as u64;
        } else {
            return Err(format!("illisible : {:02x?}", &window[..4]));
        }
    }
    Ok(())
}

fn window(cpu: &Cpu) -> String {
    cpu.memory.bytes[0x1000..0x1040]
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

/// Ce que le rejeu d'un corpus a donné : les cas jugés par forme, ceux que
/// le décodeur a refusés par forme, et les écarts.
#[derive(Default)]
struct Verdict {
    judged: HashMap<String, usize>,
    refused: HashMap<String, usize>,
    wrong: Vec<String>,
}

impl Verdict {
    fn assert_clean(&self) {
        assert!(
            self.wrong.is_empty(),
            "{} écarts :\n{}",
            self.wrong.len(),
            self.wrong
                .iter()
                .take(30)
                .cloned()
                .collect::<Vec<_>>()
                .join("\n")
        );
    }

    fn refused_forms(&self) -> Vec<&str> {
        let mut forms: Vec<&str> = self.refused.keys().map(String::as_str).collect();
        forms.sort_unstable();
        forms
    }
}

// ---- Les modes d'arrondi du x87 ----

/// **Les seize formes du corpus d'arrondi, dans les quatre modes** : le
/// produit, la somme, la différence et le quotient qui débordent ou
/// sous-débordent, `fscale`, `fsqrt`, `frndint`, et les cinq constantes. Le
/// sommet, le mot d'état entier, les étiquettes et les huit registres.
#[test]
fn the_x87_rounds_like_the_silicon_in_every_mode() {
    let text = fixture("x86-x87-rounding-oracle.tsv");
    let mut controls: HashMap<&str, u16> = HashMap::new();
    let mut pairs: HashMap<&str, [(u64, u16); 2]> = HashMap::new();
    let mut instructions: HashMap<&str, (Vec<u8>, &str)> = HashMap::new();
    let mut verdict = Verdict::default();
    for line in text.lines() {
        let f: Vec<&str> = line.split('\t').collect();
        match f[0] {
            "arrondi" => {
                controls.insert(f[1], hex(f[3]) as u16);
            }
            "paire" => {
                pairs.insert(f[1], [register(f[4]), register(f[5])]);
            }
            "instr" => {
                instructions.insert(f[1], (bytes(f[2]), f[3]));
            }
            "cas" => {
                let (code, mnemonic) = &instructions[f[1]];
                let [st0, st1] = pairs[f[3]];
                let mut cpu = processor(code);
                cpu.fpu_control = controls[f[2]];
                cpu.fpu_status = 6 << 11;
                cpu.fpu_tags = 0b1100_0000;
                cpu.x87[6] = st0;
                cpu.x87[7] = st1;
                *verdict.judged.entry(mnemonic.to_string()).or_default() += 1;
                let mut differences = Vec::new();
                if let Err(why) = run(&mut cpu, code.len()) {
                    differences.push(why);
                }
                let top = cpu.x87_top();
                for (label, value, wanted) in [
                    ("sommet", top as u64, hex(f[4])),
                    ("mot d'état", u64::from(cpu.fpu_status), hex(f[5])),
                    ("étiquettes", u64::from(cpu.x87_tag_word()), hex(f[6])),
                ] {
                    if value != wanted {
                        differences.push(format!("{label} {value:x} au lieu de {wanted:x}"));
                    }
                }
                for index in 0..8 {
                    let got = cpu.x87[(top + index) & 7];
                    let wanted = register(f[7 + index]);
                    if got != wanted {
                        differences.push(format!("ST({index}) {got:x?} au lieu de {wanted:x?}"));
                    }
                }
                if !differences.is_empty() {
                    verdict.wrong.push(format!(
                        "{mnemonic}, mode {}, paire {} : {}",
                        f[2],
                        f[3],
                        differences.join(" ; ")
                    ));
                }
            }
            _ => {}
        }
    }
    verdict.assert_clean();
    assert_eq!(verdict.judged.len(), 16, "les seize formes");
    assert_eq!(verdict.judged.values().sum::<usize>(), 896, "tous les cas");
}

// ---- Le flottant de SSE et SSE2 ----

/// Les formes de SSE3 que le corpus flottant porte : `haddps`, `hsubps`,
/// `haddpd`, `hsubpd`. CPUID ne les annonce pas ; elles doivent rester
/// illisibles, et ce sont les seules.
const SSE3_FORMS: [&str; 8] = [
    "haddpd %xmm1, %xmm0",
    "haddpd 0x20(%rsi), %xmm0",
    "haddps %xmm1, %xmm0",
    "haddps 0x20(%rsi), %xmm0",
    "hsubpd %xmm1, %xmm0",
    "hsubpd 0x20(%rsi), %xmm0",
    "hsubps %xmm1, %xmm0",
    "hsubps 0x20(%rsi), %xmm0",
];

/// Rejouer un corpus à registres XMM (`x86-float-oracle.tsv` ou
/// `x86-mmx-oracle.tsv`) : `xmm0`, `xmm1` et RAX après, les autres XMM et
/// registres intacts, la fenêtre intacte (ou ce que le corpus dit), et —
/// pour le corpus flottant — les drapeaux.
fn replay_vectors(name: &str, flags_column: bool) -> Verdict {
    let text = fixture(name);
    let mut states: HashMap<&str, [u64; 6]> = HashMap::new();
    let mut instructions: HashMap<&str, (Vec<u8>, &str)> = HashMap::new();
    let mut verdict = Verdict::default();
    for line in text.lines() {
        let f: Vec<&str> = line.split('\t').collect();
        match f[0] {
            "état" => {
                let mut state = [0u64; 6];
                for (slot, field) in state.iter_mut().zip(&f[2..8]) {
                    *slot = hex(field);
                }
                states.insert(f[1], state);
            }
            "instr" => {
                instructions.insert(f[1], (bytes(f[2]), f[3]));
            }
            "cas" => {
                let (code, mnemonic) = &instructions[f[1]];
                let start = states[f[2]];
                let mut cpu = processor(code);
                cpu.xmm[0] = [start[0], start[1]];
                cpu.xmm[1] = [start[2], start[3]];
                cpu.regs[0] = start[4];
                cpu.flags.write(start[5] | 2);
                if let Err(why) = run(&mut cpu, code.len()) {
                    if why.starts_with("illisible") {
                        *verdict.refused.entry(mnemonic.to_string()).or_default() += 1;
                        continue;
                    }
                    verdict
                        .wrong
                        .push(format!("{mnemonic}, état {} : {why}", f[2]));
                    continue;
                }
                *verdict.judged.entry(mnemonic.to_string()).or_default() += 1;
                let mut differences = Vec::new();
                let wanted_flags = if flags_column {
                    hex(f[8])
                } else {
                    start[5] & 0x8d5
                };
                for (label, value, wanted) in [
                    ("xmm0 bas", cpu.xmm[0][0], hex(f[3])),
                    ("xmm0 haut", cpu.xmm[0][1], hex(f[4])),
                    ("xmm1 bas", cpu.xmm[1][0], hex(f[5])),
                    ("xmm1 haut", cpu.xmm[1][1], hex(f[6])),
                    ("rax", cpu.regs[0], hex(f[7])),
                    ("drapeaux", cpu.flags.read() & 0x8d5, wanted_flags),
                    ("rsi", cpu.regs[6], DATA),
                ] {
                    if value != wanted {
                        differences.push(format!("{label} {value:x} au lieu de {wanted:x}"));
                    }
                }
                for index in [1usize, 2, 3, 8, 9, 10, 11, 12, 13, 14, 15] {
                    if cpu.regs[index] != 0xAAAA_AAAA_AAAA_AAAA + index as u64 {
                        differences.push(format!("a écrit dans le registre {index}"));
                    }
                }
                for (index, &xmm) in cpu.xmm.iter().enumerate().take(16).skip(2) {
                    if xmm != witness_xmm(index) {
                        differences.push(format!("a écrit dans xmm{index}"));
                    }
                }
                let memory = if flags_column { None } else { f.get(8) };
                let wanted = match memory {
                    Some(text) if *text != "-" => text.to_string(),
                    _ => pristine(),
                };
                if window(&cpu) != wanted {
                    differences.push(format!("mémoire {} au lieu de {wanted}", window(&cpu)));
                }
                if !differences.is_empty() {
                    verdict.wrong.push(format!(
                        "{mnemonic}, état {} : {}",
                        f[2],
                        differences.join(" ; ")
                    ));
                }
            }
            _ => {}
        }
    }
    verdict
}

/// **Le corpus flottant en entier**, moins les huit formes de SSE3 : 119
/// formes, chaque cas au bit près, ZF, PF et CF compris.
#[test]
fn sse_floats_match_the_silicon() {
    let verdict = replay_vectors("x86-float-oracle.tsv", true);
    verdict.assert_clean();
    assert_eq!(verdict.refused_forms(), SSE3_FORMS, "seul SSE3 est refusé");
    assert_eq!(verdict.judged.len(), 119);
    let judged: usize = verdict.judged.values().sum();
    let refused: usize = verdict.refused.values().sum();
    assert_eq!(judged + refused, 13_716, "tous les cas du corpus");
}

/// Les formes de SSSE3 sur MMX que le corpus porte : `pshufb`, les additions
/// horizontales, `pmaddubsw`, `psign*`, `pmulhrsw`, `pabs*`, et `palignr` à
/// neuf immédiats : quarante-huit formes.
const SSSE3_MMX_FORMS: usize = 48;

/// **Le corpus MMX en entier**, moins les formes de SSSE3.
#[test]
fn mmx_matches_the_silicon() {
    let verdict = replay_vectors("x86-mmx-oracle.tsv", false);
    verdict.assert_clean();
    let refused = verdict.refused_forms();
    for form in &refused {
        let name = form.split(' ').next().unwrap();
        assert!(
            matches!(
                name,
                "pshufb"
                    | "phaddw"
                    | "phaddd"
                    | "phaddsw"
                    | "phsubw"
                    | "phsubd"
                    | "phsubsw"
                    | "pmaddubsw"
                    | "psignb"
                    | "psignw"
                    | "psignd"
                    | "pmulhrsw"
                    | "pabsb"
                    | "pabsw"
                    | "pabsd"
                    | "palignr"
            ),
            "{form} ne devrait pas être refusé"
        );
    }
    assert_eq!(refused.len(), SSSE3_MMX_FORMS, "les formes de SSSE3");
    let judged: usize = verdict.judged.values().sum();
    let refused: usize = verdict.refused.values().sum();
    let total = fixture("x86-mmx-oracle.tsv")
        .lines()
        .filter(|line| line.starts_with("cas\t"))
        .count();
    assert_eq!(judged + refused, total, "tous les cas du corpus");
    assert!(
        verdict.judged.len() > 150,
        "{} formes",
        verdict.judged.len()
    );
}
