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

use wisq_vm::x86::{decode, Width};
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

/// Le pilote : il charge le module, pose l'état, appelle `run`, rend l'état.
const DRIVER: &str = r#"
const fs = require("fs");
const bytes = fs.readFileSync(process.argv[2]);
const state = JSON.parse(process.argv[3]);
const instance = new WebAssembly.Instance(new WebAssembly.Module(bytes));
const memory = new BigUint64Array(instance.exports.mem.buffer);
for (const [slot, value] of Object.entries(state)) {
  memory[Number(slot)] = BigInt("0x" + value);
}
instance.exports.run();
const out = {};
for (const slot of [0, 1, 2, Number(process.argv[4])]) {
  out[slot] = memory[slot].toString(16);
}
console.log(JSON.stringify(out));
"#;

struct Oracle {
    states: HashMap<String, (u64, u64, u64, u64)>,
    instructions: HashMap<String, (Vec<u8>, u64, String)>,
    cases: Vec<(String, String, u64, u64, u64, u64)>,
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
    };
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
            "instr" => {
                let bytes = (0..f[2].len() / 2)
                    .map(|i| u8::from_str_radix(&f[2][i * 2..i * 2 + 2], 16).expect("octet"))
                    .collect();
                oracle
                    .instructions
                    .insert(f[1].into(), (bytes, hex(f[3]), f[4].into()));
            }
            "cas" => oracle.cases.push((
                f[1].into(),
                f[2].into(),
                hex(f[3]),
                hex(f[4]),
                hex(f[5]),
                hex(f[6]),
            )),
            _ => {}
        }
    }
    oracle
}

/// **Chaque instruction que l'émetteur accepte doit, une fois compilée par
/// JavaScriptCore, rendre exactement ce que le silicium a rendu.**
#[test]
fn what_the_emitter_produces_matches_the_silicon_under_javascriptcore() {
    let Some(bun) = bun() else {
        panic!(
            "Bun est absent : l'émetteur ne serait vérifié par rien. \
             Ce test refuse de passer en silence."
        );
    };
    let oracle = read_oracle();
    let scratch = std::env::temp_dir().join("wisq-x86-wasm");
    std::fs::create_dir_all(&scratch).expect("répertoire de travail");
    let driver = scratch.join("driver.js");
    std::fs::write(&driver, DRIVER).expect("le pilote");

    let mut checked = 0usize;
    let mut refused = 0usize;
    let mut wrong: Vec<String> = Vec::new();

    for (instruction, state, want_rax, want_rcx, want_rdx, want_flags) in &oracle.cases {
        let (bytes, defined, mnemonic) = &oracle.instructions[instruction];
        let Some(step) = decode(bytes) else {
            refused += 1;
            continue;
        };
        let Some(module) = Module::block(&[step]) else {
            refused += 1;
            continue;
        };
        let (rax, rcx, rdx, flags) = oracle.states[state];

        let path = scratch.join("block.wasm");
        std::fs::write(&path, &module).expect("le module");
        let input = format!(
            r#"{{"0":"{rax:x}","1":"{rcx:x}","2":"{rdx:x}","{slot}":"{flags:x}"}}"#,
            slot = RFLAGS_OFFSET / REGISTER_BYTES
        );
        let output = Command::new(&bun)
            .arg("run")
            .arg(&driver)
            .arg(&path)
            .arg(&input)
            .arg((RFLAGS_OFFSET / REGISTER_BYTES).to_string())
            .output()
            .expect("bun doit démarrer");
        assert!(
            output.status.success(),
            "le module émis pour « {mnemonic} » a été refusé par JavaScriptCore :\n{}",
            String::from_utf8_lossy(&output.stderr)
        );
        let text = String::from_utf8_lossy(&output.stdout);
        let got = parse(&text, RFLAGS_OFFSET / REGISTER_BYTES);
        checked += 1;

        let mask = *defined;
        if got.0 != *want_rax
            || got.1 != *want_rcx
            || got.2 != *want_rdx
            || (got.3 & mask) != (want_flags & mask)
        {
            if wrong.len() < 10 {
                wrong.push(format!(
                    "{mnemonic} état {state} : rax {:x}≠{want_rax:x} rcx {:x}≠{want_rcx:x} \
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
        "x86 → WebAssembly : {checked} cas passés sous JavaScriptCore, {refused} refusés \
         par l'émetteur"
    );
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
    assert!(
        checked > 0,
        "l'émetteur n'a produit aucun module : rien n'est vérifié"
    );
}

fn parse(text: &str, flags_slot: usize) -> (u64, u64, u64, u64) {
    let field = |slot: usize| -> u64 {
        let key = format!("\"{slot}\":\"");
        text.find(&key)
            .map(|at| {
                let rest = &text[at + key.len()..];
                let end = rest.find('"').unwrap_or(0);
                hex(&rest[..end])
            })
            .unwrap_or(0)
    };
    (field(0), field(1), field(2), field(flags_slot))
}

/// Un garde-fou sur la largeur : elle vient du décodeur et sert d'index.
#[test]
fn widths_are_the_ones_the_decoder_speaks() {
    assert_eq!(Width::Qword.mask(), u64::MAX);
    assert_eq!(Width::Byte.mask(), 0xff);
}
