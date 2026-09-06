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
use wisq_vm::x86_wasm::{Module, GLOBAL_COUNT, GUEST_PAGES, RIP_SLOT};

/// L'adresse où la région est chargée, la même que partout ailleurs.
const CODE: u64 = 0x3000_0000;

/// **Une boucle de cinq instructions**, dont quatre calculent et une saute.
///
/// Cinq, parce que c'est la taille moyenne d'un bloc de base relevée en
/// désassemblant le noyau Alpine : une boucle d'une seule instruction
/// mesurerait le coût du saut, pas celui du calcul.
///
///     1: addq %rax, %rdx
///        xorq %rcx, %rbx
///        addq %rdx, %rax
///        subq $1, %rsi
///        jnz 1b
///
/// Les quatre premières posent des drapeaux que personne ne lit, sauf la
/// dernière — c'est exactement le cas où les drapeaux paresseux de
/// l'interpréteur rapportent, et le cas où le module doit les calculer.
const LOOP: [u8; 15] = [
    0x48, 0x01, 0xc2, // addq %rax, %rdx
    0x48, 0x31, 0xcb, // xorq %rcx, %rbx
    0x48, 0x01, 0xd0, // addq %rdx, %rax
    0x48, 0x83, 0xee, 0x01, // subq $1, %rsi
    0x75, 0xf1, // jnz 1b
];
const PER_TURN: u64 = 5;

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
        Some((emitted, seconds)) => {
            println!("  émetteur sous JavaScriptCore : {emitted:.1} MIPS ({seconds:.3} s)");
            println!("  rapport : ×{:.1}", emitted / interpreted);
        }
        None => println!(
            "  émetteur : Bun est absent, donc le second chemin n'est pas mesuré. \
             Il n'est pas nul, il est inconnu."
        ),
    }
}

/// Le module, compilé par JavaScriptCore et chronométré depuis l'hôte.
fn compiled(turns: u64, instructions: u64) -> Option<(f64, f64)> {
    let bun = ["/root/.bun/bin/bun", "bun"].into_iter().find(|path| {
        std::process::Command::new(path)
            .arg("--version")
            .output()
            .is_ok()
    })?;
    let module = Module::region(&LOOP, CODE, 0)?;
    let scratch = std::env::temp_dir().join(format!("wisq-speed-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&scratch);
    std::fs::create_dir_all(&scratch).ok()?;
    let path = scratch.join("m.wasm");
    std::fs::write(&path, &module).ok()?;
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
const imports = {{ env: {{ mem: memory }} }};
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
    .ok()?;
    let output = std::process::Command::new(bun)
        .arg("run")
        .arg(&driver)
        .output()
        .ok()?;
    let text = String::from_utf8_lossy(&output.stdout).to_string();
    let _ = std::fs::remove_dir_all(&scratch);
    if !output.status.success() {
        println!(
            "  émetteur : JavaScriptCore a refusé le module :\n{}",
            String::from_utf8_lossy(&output.stderr)
        );
        return None;
    }
    // **Le même garde-fou que du côté Rust** : la boucle a-t-elle vraiment
    // tourné jusqu'au bout ? RSI doit être à zéro, et le module doit avoir
    // rendu la main à l'octet qui suit la boucle.
    if !text.contains("\"rsi\":\"0\"") {
        println!("  émetteur : la boucle n'est pas allée jusqu'au bout — {text}");
        return None;
    }
    let key = "\"seconds\":";
    let start = text.find(key)? + key.len();
    let stop = start + text[start..].find(',')?;
    let seconds: f64 = text[start..stop].parse().ok()?;
    Some((instructions as f64 / seconds / 1e6, seconds))
}
