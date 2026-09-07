//! **Ce que la correspondance rapporte vraiment.**
//!
//! `--example chain` a mesuré ce que coûte un changement de région quand
//! l'hôte s'en charge : **environ 190 ns**, dont l'essentiel n'est pas
//! WebAssembly mais le site d'appel JavaScript, qui devient mégamorphe et perd
//! son cache en ligne. Ce programme mesure le même anneau de soixante-quatre
//! maillons quand le module trouve la région suivante **lui-même**, par la
//! correspondance adresse → indice, et y va par `call_indirect`.
//!
//!     cargo run -p wisq-vm --release --example resolved
//!
//! **Le même anneau, une seule différence.** Les maillons sont identiques à
//! ceux de `chain` — un `movabs`, quatre additions, un `jmp *%rax` — pour que
//! la comparaison porte sur l'enchaînement et rien d'autre. La boucle hôte
//! disparaît : un seul appel à `run` traverse l'anneau autant de fois que le
//! budget le permet.
//!
//! Le chiffre demande Bun, qui embarque le JavaScriptCore de `WKWebView`. Sans
//! lui, le programme dit ce qu'il n'a pas pu faire plutôt que de deviner.

use std::collections::HashMap;

use wisq_vm::x86_wasm::{
    table_base, table_slot, Module, BENCH_BASE, GLOBAL_COUNT, RIP_SLOT, TABLE_IMPORT, TABLE_PAGES,
};

const WORK: usize = 4;
const PER_LINK: u64 = 1 + WORK as u64 + 1;
const LINKS: usize = 64;
const STRIDE: u64 = 64;
/// Une puissance de deux qui couvre `BENCH_BASE` : le confinement l'exige, et
/// c'est ce qui met la correspondance hors de portée de l'invité.
const PAGES: u32 = 0x4000;

fn link(next: u64) -> Vec<u8> {
    let mut code = vec![0x48, 0xb8];
    code.extend_from_slice(&next.to_le_bytes());
    for _ in 0..WORK {
        code.extend_from_slice(&[0x48, 0x01, 0xc2]);
    }
    code.extend_from_slice(&[0xff, 0xe0]);
    code
}

fn main() {
    let address = |index: usize| BENCH_BASE + index as u64 * STRIDE;

    // **Les collisions se comptent avant de mesurer.** Une case ne range
    // qu'une adresse ; deux maillons qui tomberaient au même endroit
    // rendraient la main, et la mesure vaudrait pour un anneau qui n'est pas
    // celui qu'on croit chronométrer. Mieux vaut refuser que publier un
    // chiffre dont on ignore ce qu'il mesure.
    let mut taken: HashMap<u32, usize> = HashMap::new();
    for index in 0..LINKS {
        if let Some(other) = taken.insert(table_slot(address(index)), index) {
            println!(
                "les maillons {other} et {index} tombent dans la même case : \
                 l'anneau se romprait, rien n'est mesuré"
            );
            return;
        }
    }

    let mut modules = Vec::new();
    for index in 0..LINKS {
        let code = link(address((index + 1) % LINKS));
        let Some(module) = Module::resolving(&code, address(index), 0, index as u32, PAGES) else {
            eprintln!("l'émetteur refuse le maillon {index} — rien à mesurer");
            std::process::exit(1);
        };
        modules.push(module);
    }
    println!(
        "{LINKS} maillons de {PER_LINK} instructions, un saut indirect chacun, \
         aucune collision dans la correspondance"
    );

    let Some(bun) = ["/root/.bun/bin/bun", "bun"].into_iter().find(|path| {
        std::process::Command::new(path)
            .arg("--version")
            .output()
            .is_ok()
    }) else {
        println!("Bun est absent : le gain n'est pas mesuré. Il n'est pas nul, il est inconnu.");
        return;
    };

    let scratch = std::env::temp_dir().join(format!("wisq-resolved-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&scratch);
    std::fs::create_dir_all(&scratch).expect("répertoire de travail");
    let mut listing = String::new();
    let mut entries = String::new();
    for (index, module) in modules.iter().enumerate() {
        let path = scratch.join(format!("r{index}.wasm"));
        std::fs::write(&path, module).expect("le module");
        listing.push_str(&format!("{:?},", path.to_string_lossy()));
        entries.push_str(&format!(
            "[{}n,{},{}],",
            address(index),
            table_slot(address(index)),
            index
        ));
    }

    let steps = 2_000_000u64;
    let driver = scratch.join("d.js");
    std::fs::write(
        &driver,
        format!(
            r#"
const fs = require("fs");
const memory = new WebAssembly.Memory({{ initial: {pages} + {tablePages} }});
const blocks = new WebAssembly.Table({{ element: "anyfunc", initial: {links} }});
const slots = [];
const imports = {{ env: {{ mem: memory, {table}: blocks }} }};
for (let slot = 0; slot < {globals}; slot++) {{
  slots.push(new WebAssembly.Global({{ value: "i64", mutable: true }}, 0n));
  imports.env["g" + slot] = slots[slot];
}}
const runs = [];
for (const path of [{listing}]) {{
  const bytes = fs.readFileSync(path);
  runs.push(new WebAssembly.Instance(new WebAssembly.Module(bytes), imports).exports.run);
}}

// **L'hôte range, avec les mêmes fonctions que le module relit.** Les cases et
// les indices viennent de `table_slot` côté Rust ; s'ils divergeaient, rien ne
// serait trouvé et l'anneau se romprait au premier saut.
const addresses = new BigUint64Array(memory.buffer);
const indices = new Int32Array(memory.buffer);
for (const [address, slot, index] of [{entries}]) {{
  const at = {base} + slot * 16;
  addresses[at / 8] = address;
  indices[at / 4 + 2] = index;
}}

const RIP = {rip};
const u = slot => BigInt.asUintN(64, slots[slot].value);

// **Vérifier avant de chronométrer.** Un anneau qui se romprait au premier
// saut rendrait la main tout de suite, et la mesure dirait « très rapide ».
// Ce qu'on demande ici est que le budget soit consommé jusqu'au bout : RIP
// doit avoir avancé, et RDX porté la somme de tout ce qui a tourné.
slots[RIP].value = {entry}n;
slots[2].value = 0n;
runs[0](1000n);
const wentAround = slots[2].value !== 0n;
if (!wentAround) {{
  console.log(JSON.stringify({{ broken: true, rip: u(RIP).toString(16) }}));
  process.exit(0);
}}

function drive(steps) {{
  slots[RIP].value = {entry}n;
  runs[0](BigInt(steps));
}}
drive(200000); // échauffement
const began = process.hrtime.bigint();
drive({steps});
const seconds = Number(process.hrtime.bigint() - began) / 1e9;

// L'instrument doit dire de combien il tremble avant qu'on lise un écart.
const againBegan = process.hrtime.bigint();
drive({steps});
const againSeconds = Number(process.hrtime.bigint() - againBegan) / 1e9;

console.log(JSON.stringify({{ broken: false, seconds, againSeconds }}));
"#,
            pages = PAGES,
            tablePages = TABLE_PAGES,
            table = TABLE_IMPORT,
            globals = GLOBAL_COUNT,
            listing = listing,
            entries = entries,
            base = table_base(PAGES),
            rip = RIP_SLOT,
            entry = BENCH_BASE,
            steps = steps,
            links = LINKS,
        ),
    )
    .expect("le pilote");

    let output = std::process::Command::new(bun)
        .arg("run")
        .arg(&driver)
        .output()
        .expect("bun doit démarrer");
    let text = String::from_utf8_lossy(&output.stdout).to_string();
    if !output.status.success() {
        println!(
            "le pilote a échoué :\n{}",
            String::from_utf8_lossy(&output.stderr)
        );
        let _ = std::fs::remove_dir_all(&scratch);
        return;
    }
    let _ = std::fs::remove_dir_all(&scratch);
    let number = |key: &str| -> f64 {
        text.split(&format!("\"{key}\":"))
            .nth(1)
            .and_then(|rest| {
                let end = rest.find([',', '}']).unwrap_or(rest.len());
                rest[..end].trim().parse().ok()
            })
            .unwrap_or(f64::NAN)
    };
    if text.contains("\"broken\":true") {
        println!("l'anneau s'est rompu au premier saut : rien à chronométrer.");
        println!("{text}");
        return;
    }
    let ns = number("seconds") * 1e9 / steps as f64;
    let again = number("againSeconds") * 1e9 / steps as f64;
    println!();
    println!("un changement de région, **résolu dans le module** : {ns:.1} ns");
    println!("  la même mesure une seconde fois : {again:.1} ns");
    println!(
        "  soit {:.1} % d'écart entre deux mesures de la même chose — c'est le \
         tremblement de l'instrument",
        (again - ns).abs() / ns * 100.0
    );
    println!();
    println!("Le terme de comparaison est `--example chain`, qui mesure le même anneau");
    println!("enchaîné par l'hôte : **environ 190 ns**. Ce qui disparaît n'est pas du");
    println!("WebAssembly, c'est un aller-retour par un site d'appel JavaScript devenu");
    println!("mégamorphe.");
    println!();
    println!(
        "À {PER_LINK} instructions par maillon, {ns:.1} ns par changement de région valent {:.0} \
         MIPS de plafond",
        PER_LINK as f64 * 1000.0 / ns
    );
    println!("— contre 247 MIPS que l'émetteur atteint *dans* une région, sans jamais");
    println!("changer. L'écart entre ces deux plafonds borne ce que l'enchaînement");
    println!("coûte encore :");
    let inside = PER_LINK as f64 * 1000.0 / 247.0;
    println!(
        "  {:.1} ns par maillon ici, {inside:.1} ns si les mêmes {PER_LINK} instructions \
         tournaient",
        ns
    );
    println!(
        "  sans jamais changer de région — soit **{:.0} ns** pour le changement lui-même.",
        ns - inside
    );
    println!();
    println!("Ce dernier nombre est une **déduction de deux mesures**, pas une mesure : il");
    println!("suppose que les 247 MIPS relevés sur la boucle du banc valent aussi pour ces");
    println!("six instructions-ci. À prendre comme un ordre de grandeur.");
}
