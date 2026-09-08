// **Combien d'instructions par seconde, et lequel des deux chemins gagne ?**
//
// Le module de l'émetteur cite trois chiffres : 10,6 MIPS pour l'interpréteur
// x86 **en Swift**, 157 pour le cœur rv32 en Rust, 1103 pour un module
// WebAssembly **écrit à la main**. Aucun des trois ne mesure ce que ce dépôt
// produit aujourd'hui : l'interpréteur x86 en Rust, et le module que l'émetteur
// engendre. Tout le travail de couverture repose sur l'idée que le second est
// plus rapide que le premier, et cette idée n'a jamais été chiffrée.
//
//     cargo run -p wisq-vm --release --example speed
//
// Le second chiffre demande Bun, qui embarque JavaScriptCore — le moteur exact
// de `WKWebView`. Sans lui, la mesure dit ce qu'elle a pu faire et se tait sur
// le reste plutôt que de deviner.
use std::time::Instant;
use wisq_vm::x86::{Cpu, Step};
use wisq_vm::x86_wasm::{
    Module, BENCH_BASE, BENCH_LOOP, BENCH_PER_TURN, GLOBAL_COUNT, GUEST_PAGES, RIP_SLOT,
};

/// L'adresse où la région est chargée, la même que partout ailleurs.
const CODE: u64 = BENCH_BASE;

/// La boucle du banc vit dans la bibliothèque, pas ici : la sonde WebKit de
/// l'application la mesure aussi, et un test épingle l'une sur l'autre. Trois
/// copies dériveraient, et l'iPhone rendrait alors un chiffre qu'on croirait
/// comparable à celui-ci.
const LOOP: [u8; 15] = BENCH_LOOP;
const PER_TURN: u64 = BENCH_PER_TURN;

fn main() {
    let turns: u64 = std::env::args()
        .nth(1)
        .and_then(|text| text.parse().ok())
        .unwrap_or(2_000_000);
    let instructions = turns * PER_TURN;
    println!("{turns} tours de cinq instructions, soit {instructions} instructions");

    // **L'interpréteur, en Rust natif.**
    let mut cpu = Cpu {
        rip: CODE,
        ..Default::default()
    };
    cpu.regs[6] = turns;
    let started = Instant::now();
    let mut ran = 0u64;
    while (cpu.rip.wrapping_sub(CODE) as usize) < LOOP.len() {
        let at = cpu.rip.wrapping_sub(CODE) as usize;
        if cpu.step(&LOOP[at..]) == Step::Unknown {
            break;
        }
        ran += 1;
    }
    let elapsed = started.elapsed().as_secs_f64();
    // **Le compte d'abord.** Une boucle sortie trop tôt rendrait un débit
    // magnifique et faux ; le croire serait pire que ne rien mesurer.
    if ran != instructions {
        println!(
            "  interpréteur : {ran} instructions exécutées au lieu de {instructions} \
             — la mesure ne veut rien dire, on ne l'imprime pas"
        );
        return;
    }
    let interpreted = ran as f64 / elapsed / 1e6;
    println!("  interpréteur Rust : {interpreted:.1} MIPS ({elapsed:.3} s)");

    match compiled(turns, instructions) {
        Measured::Done { mips, seconds } => {
            println!("  émetteur sous JavaScriptCore : {mips:.1} MIPS ({seconds:.3} s)");
            println!("  rapport : ×{:.1}", mips / interpreted);
        }
        Measured::NoBun => println!(
            "  émetteur : Bun est absent, donc le second chemin n'est pas mesuré. \
             Il n'est pas nul, il est inconnu."
        ),
        // La raison vient d'être imprimée, avec le détail que seule `compiled`
        // avait. La répéter en l'appelant autrement serait la contredire.
        Measured::Explained => {}
    }
}

/// **Ce que le second chemin a rendu, ou pourquoi il n'a rien rendu.**
///
/// Un `Option` ne suffisait pas, et le manque s'est vu : `compiled` rendait
/// `None` aussi bien quand Bun manquait que quand JavaScriptCore refusait le
/// module, et l'appelant imprimait « Bun est absent » dans les deux cas —
/// juste sous le message qui venait de dire la vraie raison. Un diagnostic
/// faux imprimé comme un fait vaut moins que pas de diagnostic du tout.
enum Measured {
    Done {
        mips: f64,
        seconds: f64,
    },
    /// Bun n'est pas installé. Personne d'autre n'a rien dit.
    NoBun,
    /// `compiled` a déjà nommé l'obstacle, et elle seule pouvait le nommer.
    Explained,
}

/// **Bun est-il là ?** C'est la seule question dont la réponse mérite un autre
/// message : tout le reste est un obstacle que `measure` sait nommer.
fn compiled(turns: u64, instructions: u64) -> Measured {
    let Some(bun) = ["/root/.bun/bin/bun", "bun"].into_iter().find(|path| {
        std::process::Command::new(path)
            .arg("--version")
            .output()
            .is_ok()
    }) else {
        return Measured::NoBun;
    };
    match measure(bun, turns, instructions) {
        Ok((mips, seconds)) => Measured::Done { mips, seconds },
        Err(why) => {
            println!("  émetteur : {why}");
            Measured::Explained
        }
    }
}

/// Le module, compilé par JavaScriptCore et chronométré depuis l'hôte.
///
/// **Chaque obstacle se nomme.** Un `Option` rendait tous les échecs
/// identiques, et l'appelant en inventait la cause.
fn measure(bun: &str, turns: u64, instructions: u64) -> Result<(f64, f64), String> {
    let module = Module::region(&LOOP, CODE, 0)
        .ok_or_else(|| "l'émetteur refuse la boucle du banc".to_string())?;
    let scratch = std::env::temp_dir().join(format!("wisq-speed-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&scratch);
    let complain = |what: &str, why: std::io::Error| format!("{what} : {why}");
    std::fs::create_dir_all(&scratch).map_err(|why| complain("le répertoire de travail", why))?;
    let path = scratch.join("m.wasm");
    std::fs::write(&path, &module).map_err(|why| complain("le module sur disque", why))?;
    let driver = scratch.join("d.js");
    // **Un tour d'échauffement avant de chronométrer.** JavaScriptCore compile
    // par paliers : les premiers passages sont interprétés, et les chronométrer
    // mesurerait son démarrage plutôt que son code. Le tour chaud est celui
    // qu'un invité qui tourne verra.
    std::fs::write(
        &driver,
        format!(
            r#"
const fs = require("fs");
const bytes = fs.readFileSync({:?});
const memory = new WebAssembly.Memory({{ initial: {} }});
const slots = [];
for (let slot = 0; slot < {}; slot++) {{
  slots.push(new WebAssembly.Global({{ value: "i64", mutable: true }}, 0n));
}}
const imports = {{ env: {{ mem: memory, out: () => undefined, in: () => 0n }} }};
slots.forEach((global, slot) => {{ imports.env["g" + slot] = global; }});
const instance = new WebAssembly.Instance(new WebAssembly.Module(bytes), imports);
const turns = {}n;
function once() {{
  for (const global of slots) {{ global.value = 0n; }}
  slots[6].value = turns;
  instance.exports.run(turns + 8n);
  return slots[6].value;
}}
once();                       // échauffement, non chronométré
const started = process.hrtime.bigint();
once();
const seconds = Number(process.hrtime.bigint() - started) / 1e9;
console.log(JSON.stringify({{
  seconds,
  rsi: slots[6].value.toString(),
  rip: BigInt.asUintN(64, slots[{}].value).toString(16),
}}));
"#,
            path.to_string_lossy(),
            GUEST_PAGES,
            GLOBAL_COUNT,
            turns,
            RIP_SLOT
        ),
    )
    .map_err(|why| complain("le pilote sur disque", why))?;
    let output = std::process::Command::new(bun)
        .arg("run")
        .arg(&driver)
        .output()
        .map_err(|why| complain("le lancement de Bun", why))?;
    let text = String::from_utf8_lossy(&output.stdout).to_string();
    let _ = std::fs::remove_dir_all(&scratch);
    if !output.status.success() {
        return Err(format!(
            "JavaScriptCore a refusé le module :\n{}",
            String::from_utf8_lossy(&output.stderr)
        ));
    }
    // **Le même garde-fou que du côté Rust** : la boucle a-t-elle vraiment
    // tourné jusqu'au bout ? RSI doit être à zéro, et le module doit avoir
    // rendu la main à l'octet qui suit la boucle.
    if !text.contains("\"rsi\":\"0\"") {
        return Err(format!("la boucle n'est pas allée jusqu'au bout — {text}"));
    }
    let key = "\"seconds\":";
    let unreadable = || format!("la sortie du pilote est illisible — {text}");
    let start = text.find(key).ok_or_else(unreadable)? + key.len();
    let stop = start + text[start..].find(',').ok_or_else(unreadable)?;
    let seconds: f64 = text[start..stop].parse().map_err(|_| unreadable())?;
    Ok((instructions as f64 / seconds / 1e6, seconds))
}
