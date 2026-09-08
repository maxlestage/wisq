//! **Combien coûte un retour de main, maintenant que l'hôte possède l'état ?**
//!
//! Le module de l'émetteur cite deux chiffres relevés avant que la mémoire et
//! les registres soient **importés** : 62,6 ns par bloc quand chaque bloc était
//! son propre module, 2,05 ns quand la répartition vivait dedans. Le premier
//! condamnait l'idée — à 4,5 instructions par bloc, c'est 72 MIPS de plafond,
//! moins que l'interpréteur Rust.
//!
//! Ces deux chiffres ne mesurent plus ce que fait le dépôt. L'hôte possède la
//! mémoire et les vingt-neuf globales ; un module qui rend la main ne recopie
//! rien, et le suivant reprend sur le même état. Ce que coûte cet enchaînement
//! n'a jamais été mesuré, et c'est **le** nombre qui décide si le bureau local
//! tient : un noyau saute indirectement tout le temps, et chaque saut indirect
//! vers l'inconnu est un retour de main.
//!
//!     cargo run -p wisq-vm --release --example chain
//!
//! Le chiffre demande Bun, qui embarque le JavaScriptCore de `WKWebView`. Sans
//! lui, la mesure dit ce qu'elle n'a pas pu faire plutôt que de deviner.
//!
//! **Un seul chiffre mentirait ici**, donc le programme en rend trois : ce que
//! coûte un enchaînement, ce qui le coûte, et ce que ça implique. Le premier
//! seul ferait conclure que le bureau plafonne à vingt MIPS ; le troisième dit
//! que ça dépend entièrement de la taille des régions, ce qui est la vraie
//! réponse.
use wisq_vm::x86_wasm::{Module, BENCH_BASE, GLOBAL_COUNT, GUEST_PAGES, RIP_SLOT, TABLE_IMPORT};

/// Chaque maillon fait le même travail, puis saute **indirectement** au
/// suivant. L'indirection est le sujet : une cible connue à la compilation
/// resterait dans la région, et il n'y aurait pas d'enchaînement à mesurer.
///
/// ```text
///     movabs $suivant, %rax
///     addq   %rax, %rdx        (quatre fois : de quoi ne pas mesurer que le saut)
///     jmp    *%rax
/// ```
const WORK: usize = 4;
/// Instructions par maillon : le `movabs`, le travail, le saut.
const PER_LINK: u64 = 1 + WORK as u64 + 1;
/// Le nombre de maillons. Assez pour que le cache de modules ne tienne pas dans
/// un seul emplacement de prédiction, pas assez pour sortir des caches.
const LINKS: usize = 64;
/// L'écart entre deux maillons, en octets. Chacun tient largement dedans.
const STRIDE: u64 = 64;

fn link(next: u64) -> Vec<u8> {
    let mut code = vec![0x48, 0xb8];
    code.extend_from_slice(&next.to_le_bytes()); // movabs $next, %rax
    for _ in 0..WORK {
        code.extend_from_slice(&[0x48, 0x01, 0xc2]); // addq %rax, %rdx
    }
    code.extend_from_slice(&[0xff, 0xe0]); // jmp *%rax
    code
}

fn main() {
    let address = |index: usize| BENCH_BASE + index as u64 * STRIDE;
    let mut modules = Vec::new();
    let mut bound = Vec::new();
    for index in 0..LINKS {
        let code = link(address((index + 1) % LINKS));
        let Some(module) = Module::region(&code, address(index), 0) else {
            eprintln!("l'émetteur refuse le maillon {index} — rien à mesurer");
            std::process::exit(1);
        };
        modules.push((address(index), module));
        // **La même chaîne, en forme liée.** Chaque maillon pose son unique
        // bloc dans la table de l'hôte, à son propre emplacement. Ce qu'on
        // cherche à savoir : est-ce que la forme liée coûte quelque chose de
        // plus, tant que rien ne s'enchaîne par la table ?
        let Some(module) = Module::linked(&code, address(index), 0, index as u32) else {
            eprintln!("l'émetteur refuse le maillon lié {index}");
            std::process::exit(1);
        };
        bound.push((address(index), module));
    }
    println!(
        "{LINKS} maillons de {PER_LINK} instructions, un saut indirect chacun \
         ({} octets de module en tout)",
        modules.iter().map(|(_, m)| m.len()).sum::<usize>()
    );

    let Some(bun) = ["/root/.bun/bin/bun", "bun"].into_iter().find(|path| {
        std::process::Command::new(path)
            .arg("--version")
            .output()
            .is_ok()
    }) else {
        println!(
            "Bun est absent : l'enchaînement n'est pas mesuré. Il n'est pas nul, il est inconnu."
        );
        return;
    };

    let scratch = std::env::temp_dir().join(format!("wisq-chain-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&scratch);
    std::fs::create_dir_all(&scratch).expect("répertoire de travail");
    let mut listing = String::new();
    for (index, (base, module)) in modules.iter().enumerate() {
        let path = scratch.join(format!("m{index}.wasm"));
        std::fs::write(&path, module).expect("le module");
        listing.push_str(&format!("[{base}n,{:?}],", path.to_string_lossy()));
    }
    let mut bound_listing = String::new();
    for (index, (base, module)) in bound.iter().enumerate() {
        let path = scratch.join(format!("b{index}.wasm"));
        std::fs::write(&path, module).expect("le module lié");
        bound_listing.push_str(&format!("[{base}n,{:?}],", path.to_string_lossy()));
    }

    // **Le cache est chaud avant le chronomètre.** Un noyau repasse par le même
    // code des millions de fois ; ce qui l'intéresse est le régime établi, pas
    // la première traduction. Mesurer la compilation ici mélangerait deux coûts
    // que l'application paie à des moments différents.
    let steps = 2_000_000u64;
    let driver = scratch.join("d.js");
    std::fs::write(
        &driver,
        format!(
            r#"
const fs = require("fs");
const memory = new WebAssembly.Memory({{ initial: {pages} }});
const slots = [];
const imports = {{ env: {{ mem: memory, out: () => undefined, in: () => 0n }} }};
for (let slot = 0; slot < {globals}; slot++) {{
  slots.push(new WebAssembly.Global({{ value: "i64", mutable: true }}, 0n));
  imports.env["g" + slot] = slots[slot];
}}
const cache = new Map();
for (const [base, path] of [{listing}]) {{
  const bytes = fs.readFileSync(path);
  cache.set(base, new WebAssembly.Instance(new WebAssembly.Module(bytes), imports).exports.run);
}}
// La même chaîne en forme liée : une table partagée, un emplacement par maillon.
const table = new WebAssembly.Table({{ element: "anyfunc", initial: {links} }});
const linkedImports = {{ env: {{ ...imports.env, {table}: table }} }};
const linked = new Map();
{{
  let slot = 0;
  for (const [base, path] of [{bound}]) {{
    const bytes = fs.readFileSync(path);
    linked.set(base,
      new WebAssembly.Instance(new WebAssembly.Module(bytes), linkedImports).exports.run);
    slot++;
  }}
}}
const RIP = {rip};
const u = slot => BigInt.asUintN(64, slots[slot].value);

// La boucle hôte : appeler la région qui commence à RIP, relire RIP, recommencer.
function driveWith(which, steps) {{
  let taken = 0;
  slots[RIP].value = {entry}n;
  for (let step = 0; step < steps; step++) {{
    const run = which.get(u(RIP));
    if (run === undefined) return {{ taken, lost: u(RIP).toString(16) }};
    run(16n);
    taken++;
  }}
  return {{ taken, lost: null }};
}}
const drive = steps => driveWith(cache, steps);

drive(100000);                       // échauffement, non chronométré
const began = process.hrtime.bigint();
const out = drive({steps});
const seconds = Number(process.hrtime.bigint() - began) / 1e9;

// **D'où vient le coût.** Le même nombre d'appels, une fois vers une seule
// fonction et une fois vers les soixante-quatre en rotation. La différence est
// le cache en ligne de JavaScriptCore, et elle n'a rien à voir avec
// WebAssembly : c'est le site d'appel JavaScript qui devient mégamorphe.
const flat = [...cache.values()];
const BUDGET = 16n;
const bench = fn => {{
  fn(100000);
  const t = process.hrtime.bigint();
  fn({steps});
  return Number(process.hrtime.bigint() - t) / {steps};
}};
const one = bench(n => {{ for (let i = 0; i < n; i++) flat[0](BUDGET); }});
const many = bench(n => {{ let j = 0; for (let i = 0; i < n; i++) {{ flat[j](BUDGET); j = (j + 1) & {mask}; }} }});
// La forme liée, chronométrée exactement pareil.
driveWith(linked, 100000);
const boundBegan = process.hrtime.bigint();
const boundOut = driveWith(linked, {steps});
const boundSeconds = Number(process.hrtime.bigint() - boundBegan) / 1e9;

// **Et la première forme une seconde fois.** Sans ça, un écart de trois pour
// cent entre les deux formes se lirait comme un coût, alors que c'est peut-être
// la variation de la mesure elle-même. L'instrument doit dire de combien il
// tremble avant qu'on lise un écart.
const againBegan = process.hrtime.bigint();
const againOut = drive({steps});
const againSeconds = Number(process.hrtime.bigint() - againBegan) / 1e9;

console.log(JSON.stringify({{
  seconds, taken: out.taken, lost: out.lost, one, many,
  boundSeconds, boundTaken: boundOut.taken, boundLost: boundOut.lost,
  againSeconds, againTaken: againOut.taken,
}}));
"#,
            pages = GUEST_PAGES,
            globals = GLOBAL_COUNT,
            listing = listing,
            rip = RIP_SLOT,
            entry = BENCH_BASE,
            steps = steps,
            mask = LINKS - 1,
            links = LINKS,
            table = TABLE_IMPORT,
            bound = bound_listing
        ),
    )
    .expect("le pilote");

    let output = std::process::Command::new(bun)
        .arg("run")
        .arg(&driver)
        .output()
        .expect("bun doit démarrer");
    let text = String::from_utf8_lossy(&output.stdout).to_string();
    let _ = std::fs::remove_dir_all(&scratch);
    if !output.status.success() {
        println!(
            "JavaScriptCore a refusé la chaîne :\n{}",
            String::from_utf8_lossy(&output.stderr)
        );
        return;
    }
    // **Le compte d'abord.** Une chaîne qui se perd rendrait un débit
    // magnifique et faux ; le croire serait pire que ne rien mesurer.
    if !text.contains("\"lost\":null") || !text.contains("\"boundLost\":null") {
        println!("la chaîne s'est perdue : {text}");
        return;
    }
    let number = |key: &str| -> Option<f64> {
        let start = text.find(key)? + key.len();
        let stop = start
            + text[start..]
                .find(|c: char| !c.is_ascii_digit() && c != '.' && c != 'e' && c != '-')
                .unwrap_or(text.len() - start);
        text[start..stop].parse().ok()
    };
    let (Some(seconds), Some(taken)) = (number("\"seconds\":"), number("\"taken\":")) else {
        println!("mesure illisible : {text}");
        return;
    };
    let per_step = seconds / taken * 1e9;
    println!("  {taken:.0} enchaînements en {seconds:.3} s");
    println!("  **un retour de main coûte {per_step:.0} ns**");

    // **Et ce qui le coûte.** Un chiffre sans sa cause se lit de travers : celui
    // d'ici n'est pas le prix d'un appel WebAssembly, c'est le prix d'un site
    // d'appel qui vise soixante-quatre fonctions différentes. JavaScriptCore y
    // perd son cache en ligne, et c'est inhérent à une boucle hôte qui répartit
    // par adresse depuis JavaScript.
    if let (Some(one), Some(many)) = (number("\"one\":"), number("\"many\":")) {
        println!(
            "  dont : {one:.0} ns pour appeler **une** fonction, {many:.0} ns pour en appeler \
             soixante-quatre en rotation"
        );
        println!(
            "  le site d'appel mégamorphe coûte donc ×{:.1}, et c'est le poste principal",
            many / one
        );
    }

    // **Ce que ça implique, et c'est là que le premier chiffre trompe.** Le coût
    // est par *retour de main*, pas par instruction : ce qui décide est le
    // nombre d'instructions qu'une région exécute avant de rendre la main.
    // Cette chaîne-ci est le pire cas construit exprès — six instructions par
    // maillon, un saut indirect à chaque fois.
    println!("  ce que ça donne selon la taille des régions :");
    for (instructions, what) in [
        (PER_LINK as f64, "cette chaîne, le pire cas"),
        (4.5, "un bloc de base du noyau Alpine"),
        (
            113.8,
            "une région du noyau **si elle s'exécutait en entier** — statique",
        ),
        (1000.0, "une région dix fois plus grande"),
    ] {
        println!(
            "    {instructions:>6.1} instructions par retour de main → {:>5.0} MIPS  ({what})",
            instructions / (per_step / 1e9) / 1e6
        );
    }
    // **Et la forme liée, qui ne change encore rien — c'est le résultat
    // attendu, et le vérifier est le sujet.** Ses blocs vivent dans la table de
    // l'hôte, mais `resolve` ne nomme toujours que les blocs de sa propre
    // région : la boucle hôte reste le seul chemin d'une région à l'autre. Si
    // ces deux chiffres divergeaient, la forme liée coûterait quelque chose,
    // et il faudrait savoir quoi avant d'aller plus loin.
    if let (Some(bound_seconds), Some(bound_taken)) =
        (number("\"boundSeconds\":"), number("\"boundTaken\":"))
    {
        let bound_step = bound_seconds / bound_taken * 1e9;
        let gap = (bound_step / per_step - 1.0) * 100.0;
        println!("  la même chaîne en **forme liée** : {bound_step:.0} ns ({gap:+.0} %)");
        // **De combien l'instrument tremble.** La première forme, mesurée deux
        // fois : l'écart entre ces deux-là est le bruit, et il faut le connaître
        // avant de lire l'écart entre les deux formes.
        if let (Some(again_seconds), Some(again_taken)) =
            (number("\"againSeconds\":"), number("\"againTaken\":"))
        {
            let again_step = again_seconds / again_taken * 1e9;
            let noise = (again_step / per_step - 1.0) * 100.0;
            println!(
                "  la **même** forme, remesurée : {again_step:.0} ns ({noise:+.0} %) — c'est \
                 le tremblement de l'instrument"
            );
            if gap.abs() <= noise.abs().max(3.0) {
                println!(
                    "  l'écart entre les deux formes tient dans ce tremblement : **la table \
                     partagée ne coûte rien de mesurable**, tant que rien ne s'enchaîne par \
                     elle — et rien ne s'y enchaîne encore, `resolve` ne nommant que les \
                     blocs de sa propre région."
                );
            } else {
                println!(
                    "  l'écart dépasse le tremblement : la forme liée coûte quelque chose, \
                     et il faut savoir quoi avant d'aller plus loin."
                );
            }
        }
    }

    println!(
        "  **La conclusion n'est pas un plafond, c'est une contrainte** : le bureau tient si les \
         régions sont grandes, et pas autrement.\n  Les 113,8 sont un compte *statique* — \
         combien une région contient, pas combien elle exécute avant de sortir. Le chiffre \
         dynamique demande une machine qui tourne, et il n'existe pas encore."
    );
}
