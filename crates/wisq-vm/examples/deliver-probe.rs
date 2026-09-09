// **Ce que coûte le point de délivrance d'une interruption, mesuré avant d'en
// écrire un.**
//
//     cargo run -p wisq-vm --release --example deliver-probe
//
// `docs/DEMARRAGE.md` pose la question avant la décision : une interruption
// arrive entre deux instructions, et il faut un endroit où la machine regarde
// si l'une attend. Il y a deux endroits possibles, et **ils ne se paient pas
// dans la même monnaie** :
//
// - **Dans le module**, un contrôle entre blocs. Le coût est du temps, payé à
//   chaque bloc, qu'une interruption attende ou non.
// - **Dans la boucle hôte**, qui reprend la main quand le budget de pas
//   s'épuise. Le coût dans le module est **nul** ; ce qu'on paie est le retour
//   de main lui-même, et ce qu'on achète est la **latence** : une interruption
//   n'arrive qu'à la fin d'un budget.
//
// **La première moitié est déjà mesurée**, et la remesurer serait du gaspillage
// : `docs/DEMARRAGE.md` chiffre le contrôle en ligne — une globale lue, testée,
// une branche jamais prise — à **−0,17 à +0,30 ns par occurrence** sur les deux
// motifs de balayage, la plage incluant zéro. C'est exactement la forme qu'un
// contrôle d'interruption prendrait.
//
// **La seconde ne l'est pas**, et c'est ce que ce programme mesure : le débit du
// même travail, découpé en budgets de plus en plus petits. La courbe donne
// directement ce qu'une latence coûte.
//
// **Ce que le résultat ne dira pas tout seul.** Le passage d'un coût par
// occurrence à un coût par instruction demande la fréquence des blocs, et elle
// vient d'ailleurs — `--example coverage` relève **4,5 instructions par bloc**
// sur le noyau Alpine. Un chiffre déduit de deux mesures n'est pas une mesure,
// et ce programme le dit plutôt que de le taire.
use wisq_vm::x86_wasm::{
    host_pages, Module, BENCH_BASE, BENCH_MEMORY_LOOP, BENCH_MEMORY_PER_TURN, GLOBAL_COUNT,
    RIP_SLOT,
};

/// La RAM confinée, en pages de 64 Kio. Une puissance de deux, que le masque
/// exige.
const PAGES: u32 = 0x4000;

/// Les budgets éprouvés. **Ils comptent des blocs, pas des instructions** — la
/// boucle de répartition décrémente une fois par `call_indirect`, donc une fois
/// par bloc de base. Vérifié plutôt que supposé : à budget 1 000, huit millions
/// de tours rendent la main huit mille fois, et un tour de cette boucle est un
/// bloc.
///
/// Le plus grand ne rend jamais la main avant la fin ; c'est lui la référence.
const BUDGETS: [u64; 8] = [1, 10, 100, 1_000, 10_000, 100_000, 1_000_000, 40_000_000];

/// Combien d'instructions chaque mesure exécute, quel que soit le budget.
/// **C'est la garde de ce programme** : un budget qui s'arrêterait tôt rendrait
/// un débit magnifique et faux, et c'est le piège que ce dépôt s'est déjà fait
/// prendre une fois.
const TURNS: u64 = 8_000_000;

fn main() {
    let instructions = TURNS * BENCH_MEMORY_PER_TURN;
    println!(
        "{TURNS} tours de {BENCH_MEMORY_PER_TURN} instructions, soit {instructions} instructions, \
         découpés en budgets décroissants"
    );
    println!();

    let Some(module) = Module::resolving(&BENCH_MEMORY_LOOP, BENCH_BASE, 0, 0, PAGES) else {
        eprintln!("l'émetteur refuse la boucle du banc — rien à mesurer");
        std::process::exit(1);
    };

    let Some(bun) = ["/root/.bun/bin/bun", "bun"].into_iter().find(|path| {
        std::process::Command::new(path)
            .arg("--version")
            .output()
            .is_ok()
    }) else {
        // Même partage que `examples/coverage.rs` : 1 quand il y a quelque
        // chose à réparer, 2 quand la mesure est impossible ici.
        eprintln!(
            "Bun est absent : la mesure n'est pas faite. Elle n'est pas nulle, elle est inconnue."
        );
        std::process::exit(2);
    };

    let scratch = std::env::temp_dir().join(format!("wisq-deliver-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&scratch);
    std::fs::create_dir_all(&scratch).expect("le répertoire de travail");
    let path = scratch.join("m.wasm");
    std::fs::write(&path, &module).expect("le module sur disque");
    let driver = scratch.join("d.js");
    std::fs::write(
        &driver,
        format!(
            r#"
const fs = require("fs");
const bytes = fs.readFileSync({module:?});
const memory = new WebAssembly.Memory({{ initial: {pages} }});
const blocks = new WebAssembly.Table({{ element: "anyfunc", initial: 64 }});
const slots = [];
const imports = {{ env: {{ mem: memory, out: () => undefined, in: () => 0n, blocks }} }};
for (let slot = 0; slot < {globals}; slot++) {{
  slots.push(new WebAssembly.Global({{ value: "i64", mutable: true }}, 0n));
  imports.env["g" + slot] = slots[slot];
}}
const run = new WebAssembly.Instance(new WebAssembly.Module(bytes), imports).exports.run;
const RIP = {rip};
const TURNS = {turns}n;

// **Un tour complet, découpé en morceaux de `budget` pas.**
//
// L'hôte reprend la main à chaque morceau : c'est exactement ce que ferait une
// boucle qui vérifie s'il y a une interruption à délivrer. Le compte de retours
// est rendu, parce que c'est lui qu'on paie.
function drive(budget) {{
  for (const global of slots) {{ global.value = 0n; }}
  slots[6].value = TURNS;             // rsi : le compteur de tours
  slots[RIP].value = {base}n;
  let handbacks = 0;
  while (slots[6].value !== 0n) {{
    run(BigInt(budget));
    handbacks++;
    if (handbacks > 20000000) break;  // une boucle qui n'avance pas
  }}
  return handbacks;
}}

drive(BUDGETS_WARM);                  // échauffement, non chronométré

const results = [];
for (const budget of [{budgets}]) {{
  const began = process.hrtime.bigint();
  const handbacks = drive(budget);
  const seconds = Number(process.hrtime.bigint() - began) / 1e9;
  // **La garde** : rsi doit être à zéro, sinon le budget a rendu la main sans
  // que le travail soit fait, et le débit mesuré ne veut rien dire.
  results.push({{ budget, seconds, handbacks, finished: slots[6].value === 0n }});
}}
console.log(JSON.stringify(results));
"#,
            module = path.to_string_lossy(),
            pages = host_pages(PAGES),
            globals = GLOBAL_COUNT,
            rip = RIP_SLOT,
            base = BENCH_BASE,
            turns = TURNS,
            budgets = BUDGETS
                .iter()
                .map(|b| b.to_string())
                .collect::<Vec<_>>()
                .join(", "),
        )
        .replace("BUDGETS_WARM", &BUDGETS[BUDGETS.len() - 1].to_string()),
    )
    .expect("le pilote sur disque");

    let output = std::process::Command::new(bun)
        .arg("run")
        .arg(&driver)
        .output()
        .expect("bun doit démarrer");
    let text = String::from_utf8_lossy(&output.stdout).to_string();
    let _ = std::fs::remove_dir_all(&scratch);
    if !output.status.success() {
        eprintln!(
            "le pilote a échoué :\n{}",
            String::from_utf8_lossy(&output.stderr)
        );
        std::process::exit(1);
    }

    // Le relevé est un tableau JSON d'objets plats ; le lire à la main évite une
    // dépendance pour six lignes.
    let mut rows: Vec<(u64, f64, u64)> = Vec::new();
    for piece in text.split("{\"budget\":").skip(1) {
        let field = |key: &str| -> f64 {
            piece
                .split(&format!("\"{key}\":"))
                .nth(1)
                .and_then(|rest| {
                    let end = rest.find([',', '}']).unwrap_or(rest.len());
                    rest[..end].trim().parse().ok()
                })
                .unwrap_or(f64::NAN)
        };
        if !piece.contains("\"finished\":true") {
            eprintln!("un budget n'a pas fini son travail — la mesure ne veut rien dire :\n{text}");
            std::process::exit(1);
        }
        let budget: f64 = piece
            .split(',')
            .next()
            .and_then(|first| first.trim().parse().ok())
            .unwrap_or(f64::NAN);
        rows.push((budget as u64, field("seconds"), field("handbacks") as u64));
    }
    if rows.is_empty() {
        eprintln!("le pilote n'a rien rendu :\n{text}");
        std::process::exit(1);
    }

    // La référence : le plus grand budget, celui qui ne rend la main qu'à la
    // fin. Tout le reste se lit comme un écart à lui.
    let (_, reference, _) = *rows.last().expect("au moins une ligne");
    let per = |seconds: f64| seconds * 1e9 / instructions as f64;
    println!("| budget (pas) | retours de main | débit | surcoût par instruction |");
    println!("| --- | --- | --- | --- |");
    for (budget, seconds, handbacks) in &rows {
        println!(
            "| {budget} | {handbacks} | {:.1} MIPS | {:+.3} ns |",
            instructions as f64 / seconds / 1e6,
            per(*seconds) - per(reference)
        );
    }
    println!();
    println!(
        "La dernière ligne est la référence : elle ne rend la main qu'à la fin. \
         Les autres se lisent comme un écart à elle."
    );
    println!(
        "**Les deux plus petits budgets ne sont pas stables** : trois exécutions ont rendu \
         +80, +65 et +16 ns pour un budget de 1. À ce rythme d'appels on mesure le moteur \
         qui recompile et ramasse, pas le retour de main. À partir de mille, l'écart tient."
    );
    println!(
        "**Ce que ça achète** : un budget de N borne la latence d'une interruption à N \
         **blocs** — soit environ 4,5 N instructions sur le noyau Alpine, et un bloc par \
         tour sur cette boucle-ci."
    );
    println!(
        "**Ce qu'il faut y ajouter pour comparer** : le contrôle dans le module coûte \
         −0,17 à +0,30 ns par occurrence (docs/DEMARRAGE.md), une fois par bloc, et un bloc \
         fait 4,5 instructions sur le noyau Alpine (--example coverage). Le report est une \
         **déduction de deux mesures**, pas une mesure."
    );
}
