//! **Le compilateur que j'écris, jugé par le moteur qui l'exécutera.**
//!
//! iOS interdit d'écrire une page exécutable ; il n'interdit pas de produire
//! une **donnée** que WebKit compile. C'est le contournement, et il ne déplace
//! pas le travail : le décodage, la traduction et la génération de code sont
//! ici. WebKit n'a que la dernière étape, l'assemblage machine.
//!
//! **Pourquoi ce test peut exister sur Linux.** Bun embarque JavaScriptCore,
//! le moteur exact de `WKWebView`. Un module émis ici et exécuté sous Bun
//! passe par le même compilateur WebAssembly que sur un iPhone. Le juge, lui,
//! reste extérieur : les cas de `x86-oracle.tsv` viennent d'un vrai
//! processeur.
//!
//! Sans Bun, le test **saute bruyamment** plutôt que de passer en silence : un
//! émetteur que rien n'exécute n'est pas un émetteur vérifié.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::process::Command;

use wisq_vm::x86::{decode, Decoded, Width};
use wisq_vm::x86_wasm::{Module, REGISTER_BYTES, RFLAGS_OFFSET};

fn workspace_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .and_then(Path::parent)
        .expect("racine de l'espace de travail")
        .to_path_buf()
}

fn bun() -> Option<PathBuf> {
    for candidate in ["/root/.bun/bin/bun", "/usr/local/bin/bun", "bun"] {
        if Command::new(candidate).arg("--version").output().is_ok() {
            return Some(PathBuf::from(candidate));
        }
    }
    None
}

/// **Le pilote, et pourquoi il prend tout d'un coup.**
///
/// La première version lançait un processus Bun par cas : 2664 démarrages de
/// moteur pour une mesure, dix minutes par tour. La boucle de retour était le
/// goulot, pas le code — et un test qu'on n'ose pas relancer cesse d'être un
/// test. Celui-ci reçoit tous les modules et tous les états en une fois,
/// instancie **une fois par instruction** plutôt qu'une fois par cas, et rend
/// tout.
const DRIVER: &str = r#"
const fs = require("fs");
const job = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const out = {};
for (const unit of job.jobs) {
  const bytes = fs.readFileSync(unit.module);
  const instance = new WebAssembly.Instance(new WebAssembly.Module(bytes));
  const memory = new BigUint64Array(instance.exports.mem.buffer);
  for (const test of unit.cases) {
    // Remettre à zéro : un résidu du cas précédent ferait lire à une
    // instruction un registre que l'oracle n'a pas posé.
    for (let slot = 0; slot < 24; slot++) { memory[slot] = 0n; }
    for (const [slot, value] of Object.entries(test.regs)) {
      memory[Number(slot)] = BigInt("0x" + value);
    }
    instance.exports.run();
    out[test.id] = [0, 1, 2, job.flagsSlot].map(s => memory[s].toString(16));
  }
}
fs.writeFileSync(process.argv[3], JSON.stringify(out));
"#;

/// Un cas de l'oracle. Nommé plutôt que laissé en tuple : six champs anonymes
/// manipulés par référence forment un type que personne ne relit — clippy le
/// refuse, et il a raison.
struct Case {
    instruction: String,
    state: String,
    rax: u64,
    rcx: u64,
    rdx: u64,
    flags: u64,
}

struct Oracle {
    states: HashMap<String, (u64, u64, u64, u64)>,
    instructions: HashMap<String, (Vec<u8>, u64, String)>,
    cases: Vec<Case>,
    /// **Ce que le silicium avait dans les registres que « état » ne porte
    /// pas.** Les laisser à zéro rendait ce harnais faux en silence : il
    /// tombait juste tant qu'aucune instruction traduite n'en lisait un, et
    /// `movzbl %bh, %eax` lit RBX.
    fixed: [u64; 16],
}

fn hex(text: &str) -> u64 {
    u64::from_str_radix(text, 16).expect("un nombre hexadécimal")
}

fn read_oracle() -> Oracle {
    let text = std::fs::read_to_string(workspace_root().join("Tests/Fixtures/x86-oracle.tsv"))
        .expect("l'oracle matériel doit être lisible");
    let mut oracle = Oracle {
        states: HashMap::new(),
        instructions: HashMap::new(),
        cases: Vec::new(),
        fixed: [0; 16],
    };
    let mut seeded = 0usize;
    for line in text.lines() {
        if line.starts_with('#') || line.trim().is_empty() {
            continue;
        }
        let f: Vec<&str> = line.split('\t').collect();
        match f[0] {
            "état" => {
                oracle
                    .states
                    .insert(f[1].into(), (hex(f[2]), hex(f[3]), hex(f[4]), hex(f[5])));
            }
            "fixe" => {
                let register: usize = f[1].parse().expect("un numéro de registre");
                oracle.fixed[register] = hex(f[2]);
                seeded += 1;
            }
            "instr" => {
                let bytes = (0..f[2].len() / 2)
                    .map(|i| u8::from_str_radix(&f[2][i * 2..i * 2 + 2], 16).expect("octet"))
                    .collect();
                oracle
                    .instructions
                    .insert(f[1].into(), (bytes, hex(f[3]), f[4].into()));
            }
            "cas" => oracle.cases.push(Case {
                instruction: f[1].into(),
                state: f[2].into(),
                rax: hex(f[3]),
                rcx: hex(f[4]),
                rdx: hex(f[5]),
                flags: hex(f[6]),
            }),
            _ => {}
        }
    }
    assert_eq!(
        seeded, 13,
        "l'oracle doit déclarer les treize registres fixes, il en déclare {seeded}"
    );
    oracle
}

/// **Chaque instruction que l'émetteur accepte doit, une fois compilée par
/// JavaScriptCore, rendre exactement ce que le silicium a rendu.**
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

#[test]
fn what_the_emitter_produces_matches_the_silicon_under_javascriptcore() {
    let Some(bun) = bun() else {
        panic!(
            "Bun est absent : l'émetteur ne serait vérifié par rien. \
             Ce test refuse de passer en silence."
        );
    };
    let oracle = read_oracle();
    // **Un chemin par processus.** Un chemin fixe se fait écraser dès que deux
    // exécutions se croisent — la CI parallélise, et j'ai moi-même lancé deux
    // tours concurrents : le module se lisait à moitié écrit et JavaScriptCore
    // refusait « un module d'au moins huit octets ». Le défaut était dans le
    // harnais, pas dans l'émetteur.
    let scratch = std::env::temp_dir().join(format!("wisq-x86-wasm-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&scratch);
    std::fs::create_dir_all(&scratch).expect("répertoire de travail");
    let driver = scratch.join("driver.js");
    std::fs::write(&driver, DRIVER).expect("le pilote");

    let flags_slot = RFLAGS_OFFSET / REGISTER_BYTES;
    // Regrouper les cas par instruction : un module par instruction, instancié
    // une seule fois pour tous ses états.
    let mut by_instruction: Vec<(String, Vec<&Case>)> = Vec::new();
    let mut seen: HashMap<String, usize> = HashMap::new();
    for case in &oracle.cases {
        match seen.get(&case.instruction) {
            Some(&at) => by_instruction[at].1.push(case),
            None => {
                seen.insert(case.instruction.clone(), by_instruction.len());
                by_instruction.push((case.instruction.clone(), vec![case]));
            }
        }
    }

    let mut jobs = String::from("{\"flagsSlot\":");
    jobs.push_str(&flags_slot.to_string());
    jobs.push_str(",\"jobs\":[");
    let mut emitted = 0usize;
    let mut refused = 0usize;
    let mut expected: HashMap<String, (u64, u64, u64, u64, u64, String)> = HashMap::new();

    for (index, (instruction, cases)) in by_instruction.iter().enumerate() {
        let (bytes, defined, mnemonic) = &oracle.instructions[instruction];
        // **Décoder la séquence entière, ou refuser l'entrée.** Certaines
        // entrées de l'oracle portent plusieurs instructions, et quelques-unes
        // une boucle complète. N'en traduire que la première rend un état que
        // rien ne distingue d'un état juste — c'est ce qui a produit les faux
        // écarts portant « une boucle qui additionne » ou « un saut
        // conditionnel long » dans leur nom.
        let Some(program) = decode_all(bytes) else {
            refused += cases.len();
            continue;
        };
        let Some(module) = Module::block(&program) else {
            refused += cases.len();
            continue;
        };
        let path = scratch.join(format!("m{index}.wasm"));
        std::fs::write(&path, &module).expect("le module");

        if emitted > 0 {
            jobs.push(',');
        }
        emitted += 1;
        jobs.push_str(&format!(
            "{{\"module\":{:?},\"cases\":[",
            path.to_string_lossy()
        ));
        for (position, case) in cases.iter().enumerate() {
            let (rax, rcx, rdx, flags) = oracle.states[&case.state];
            let id = format!("{}|{}", case.instruction, case.state);
            if position > 0 {
                jobs.push(',');
            }
            // Les treize registres fixes sont posés **avant** les trois de
            // l'état, pour qu'un chevauchement futur soit décidé par l'état
            // et pas par l'ordre d'écriture d'un objet JSON.
            let mut regs = String::new();
            for (slot, value) in oracle.fixed.iter().enumerate() {
                if *value != 0 {
                    regs.push_str(&format!("\"{slot}\":\"{value:x}\","));
                }
            }
            jobs.push_str(&format!(
                "{{\"id\":{id:?},\"regs\":{{{regs}\"0\":\"{rax:x}\",\"1\":\"{rcx:x}\",\
                 \"2\":\"{rdx:x}\",\"{flags_slot}\":\"{flags:x}\"}}}}"
            ));
            expected.insert(
                id,
                (
                    case.rax,
                    case.rcx,
                    case.rdx,
                    case.flags,
                    *defined,
                    mnemonic.clone(),
                ),
            );
        }
        jobs.push_str("]}");
    }
    jobs.push_str("]}");

    let job_path = scratch.join("job.json");
    let result_path = scratch.join("result.json");
    std::fs::write(&job_path, &jobs).expect("la liste de travail");

    let output = Command::new(&bun)
        .arg("run")
        .arg(&driver)
        .arg(&job_path)
        .arg(&result_path)
        .output()
        .expect("bun doit démarrer");
    assert!(
        output.status.success(),
        "JavaScriptCore a refusé un module émis :\n{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let text = std::fs::read_to_string(&result_path).expect("le résultat");

    let mut checked = 0usize;
    let mut wrong: Vec<String> = Vec::new();
    for (id, (want_rax, want_rcx, want_rdx, want_flags, mask, mnemonic)) in &expected {
        let Some(got) = field(&text, id) else {
            wrong.push(format!("{mnemonic} : aucun résultat rendu pour {id}"));
            continue;
        };
        checked += 1;
        if got.0 != *want_rax
            || got.1 != *want_rcx
            || got.2 != *want_rdx
            || (got.3 & mask) != (want_flags & mask)
        {
            if wrong.len() < 10 {
                wrong.push(format!(
                    "{mnemonic} [{id}] : rax {:x}≠{want_rax:x} rcx {:x}≠{want_rcx:x} \
                     rdx {:x}≠{want_rdx:x} drapeaux {:x}≠{:x} (masque {mask:x})",
                    got.0,
                    got.1,
                    got.2,
                    got.3 & mask,
                    want_flags & mask
                ));
            } else {
                wrong.push(String::new());
            }
        }
    }

    println!(
        "x86 → WebAssembly : {checked} cas passés sous JavaScriptCore ({emitted} modules), \
         {refused} refusés par l'émetteur"
    );
    let _ = std::fs::remove_dir_all(&scratch);
    assert!(
        wrong.is_empty(),
        "{} cas sur {checked} ne rendent pas ce que le processeur rend :\n{}",
        wrong.len(),
        wrong
            .iter()
            .filter(|l| !l.is_empty())
            .cloned()
            .collect::<Vec<_>>()
            .join("\n")
    );
    // **Le plancher monte avec chaque famille traduite.** Il ne dit pas
    // « c'est assez » : il dit « ne recule pas ». Les décalages ont ajouté
    // soixante instructions au groupe arithmétique, les transferts trente-six
    // de plus — huit cent soixante-quatre cas de silicium.
    assert!(
        checked > 4700,
        "l'émetteur ne couvre plus que {checked} cas : la couverture a reculé"
    );
}

/// Lire les quatre valeurs rendues pour un cas.
fn field(text: &str, id: &str) -> Option<(u64, u64, u64, u64)> {
    let key = format!("{id:?}:[");
    let at = text.find(&key)? + key.len();
    let end = text[at..].find(']')? + at;
    let values: Vec<u64> = text[at..end]
        .split(',')
        .map(|piece| hex(piece.trim().trim_matches('"')))
        .collect();
    Some((
        *values.first()?,
        *values.get(1)?,
        *values.get(2)?,
        *values.get(3)?,
    ))
}

/// Un garde-fou sur la largeur : elle vient du décodeur et sert d'index.
#[test]
fn widths_are_the_ones_the_decoder_speaks() {
    assert_eq!(Width::Qword.mask(), u64::MAX);
    assert_eq!(Width::Byte.mask(), 0xff);
}
