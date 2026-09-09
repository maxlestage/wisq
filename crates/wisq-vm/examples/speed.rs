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
    host_pages, Module, BENCH_BASE, BENCH_CONFINED_PAGES, BENCH_LOOP,
    BENCH_MEMORY_ACCESSES_PER_TURN, BENCH_MEMORY_LOOP, BENCH_MEMORY_PER_TURN, BENCH_PER_TURN,
    GLOBAL_COUNT, GUEST_PAGES, RIP_SLOT,
};

/// **Les deux formes, et pourquoi il faut les deux.**
///
/// L'application n'exécute que la forme confinée — `LocalDesktop` passe par
/// `DesktopTranslator.resolvingRegion`, donc par `Module::resolving`. Ce banc
/// n'a longtemps mesuré que la forme libre, et son chiffre est celui que la
/// feuille de route cite partout. Les deux sont mesurées maintenant : la libre
/// reste, parce que toute la série l'a citée, et la confinée dit ce que
/// l'application fera vraiment.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Shape {
    /// `Module::region` : pas de masque, pas de pagination.
    Free,
    /// `Module::resolving` : masque, marche dans les tables, tampon.
    Confined,
}

impl Shape {
    fn name(self) -> &'static str {
        match self {
            Shape::Free => "libre",
            Shape::Confined => "confinée (ce que l'application exécute)",
        }
    }
}

/// Une boucle à chronométrer : son nom, ses octets, et ce qu'un tour vaut.
struct Bench {
    name: &'static str,
    code: &'static [u8],
    per_turn: u64,
    /// Combien d'accès mémoire un tour fait. Zéro pour la boucle historique —
    /// et c'est justement ce qui la rend incapable de dire quoi que ce soit du
    /// surcoût de la forme confinée.
    accesses_per_turn: u64,
}

/// La RAM déclarée pour la forme confinée, en pages de 64 Kio. Elle vient de
/// la bibliothèque : la sonde WebKit de l'application déclare la même, et deux
/// copies feraient rendre à l'iPhone un chiffre qu'on croirait comparable.
const CONFINED_PAGES: u32 = BENCH_CONFINED_PAGES;

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

    // **Quatre mesures, et c'est le tableau qui dit quelque chose.**
    //
    // Une seule case ne dit rien : le surcoût de la forme confinée est
    // entièrement sur les accès mémoire, donc la comparer à la forme libre sur
    // une boucle qui n'en fait aucun rend « aucune différence » — vrai, et sans
    // rapport avec ce que le bureau fera tourner.
    let benches = [
        Bench {
            name: "registres seuls",
            code: &LOOP,
            per_turn: PER_TURN,
            accesses_per_turn: 0,
        },
        Bench {
            name: "une lecture et une écriture",
            code: &BENCH_MEMORY_LOOP,
            per_turn: BENCH_MEMORY_PER_TURN,
            accesses_per_turn: BENCH_MEMORY_ACCESSES_PER_TURN,
        },
    ];

    println!();
    let mut table: Vec<(&str, Shape, f64, u64, u64)> = Vec::new();
    for bench in &benches {
        for shape in [Shape::Free, Shape::Confined] {
            let ran = turns * bench.per_turn;
            match compiled(shape, bench, turns, ran) {
                Measured::Done {
                    mips,
                    seconds,
                    tremor,
                } => {
                    println!(
                        "{} · {} : {mips:.1} MIPS ({seconds:.3} s, l'instrument tremble de {:.0} %)",
                        bench.name,
                        shape.name(),
                        tremor * 100.0
                    );
                    table.push((bench.name, shape, mips, bench.accesses_per_turn, turns));
                }
                Measured::NoBun => {
                    println!(
                        "  émetteur : Bun est absent, donc le second chemin n'est pas mesuré. \
                         Il n'est pas nul, il est inconnu."
                    );
                    return;
                }
                // La raison vient d'être imprimée, avec le détail que seule
                // `compiled` avait. La répéter en l'appelant autrement serait
                // la contredire.
                Measured::Explained => return,
            }
        }
    }
    println!("  interpréteur Rust, pour mémoire : {interpreted:.1} MIPS");

    // **Ce que le confinement coûte, en nanosecondes par accès.**
    //
    // Pas en pourcentage, et c'est une règle : un pourcentage sur cette boucle
    // supposerait que le vrai code ait la même densité d'opérandes mémoire —
    // deux accès pour quatre instructions — et cette densité n'est écrite nulle
    // part dans ce dépôt. Une nanoseconde par accès se reporte sur n'importe
    // quelle densité ; un pourcentage ne se reporte sur rien.
    println!();
    for bench in &benches {
        let of = |shape: Shape| {
            table
                .iter()
                .find(|(name, form, _, _, _)| *name == bench.name && *form == shape)
                .map(|(_, _, mips, _, _)| *mips)
        };
        let (Some(free), Some(confined)) = (of(Shape::Free), of(Shape::Confined)) else {
            continue;
        };
        // Le temps par instruction, dans les deux formes, puis l'écart.
        let gap = 1000.0 / confined - 1000.0 / free; // ns par instruction
        if bench.accesses_per_turn == 0 {
            println!(
                "{} : {gap:+.3} ns par instruction — aucune mémoire touchée, \
                 donc rien à imputer au confinement",
                bench.name
            );
            continue;
        }
        let per_access = gap * bench.per_turn as f64 / bench.accesses_per_turn as f64;
        println!(
            "{} : {gap:+.3} ns par instruction, soit **{per_access:+.2} ns par accès mémoire**",
            bench.name
        );
        // **Et le tremblement imprimé plus haut ne borne pas ce chiffre-ci.**
        // Les deux relevés d'une même case sont dos à dos : ils partagent la
        // charge de la machine, donc ils s'accordent entre eux bien mieux que
        // deux exécutions du programme. Mesuré : huit exécutions ont rendu de
        // 0,5 à 1,7 ns par accès, là où chaque case annonçait 0 à 3 % de
        // tremblement. Un seul relevé de cette ligne ne vaut donc pas mieux
        // qu'un ordre de grandeur.
        println!(
            "  à relancer quelques fois : entre deux exécutions ce nombre bouge \
             beaucoup plus que le tremblement annoncé par case"
        );
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
        /// De combien les deux relevés du même montage se sont écartés, en
        /// proportion. Une différence entre deux formes plus petite que ça ne
        /// veut rien dire.
        tremor: f64,
    },
    /// Bun n'est pas installé. Personne d'autre n'a rien dit.
    NoBun,
    /// `compiled` a déjà nommé l'obstacle, et elle seule pouvait le nommer.
    Explained,
}

/// **Bun est-il là ?** C'est la seule question dont la réponse mérite un autre
/// message : tout le reste est un obstacle que `measure` sait nommer.
fn compiled(shape: Shape, bench: &Bench, turns: u64, instructions: u64) -> Measured {
    let Some(bun) = ["/root/.bun/bin/bun", "bun"].into_iter().find(|path| {
        std::process::Command::new(path)
            .arg("--version")
            .output()
            .is_ok()
    }) else {
        return Measured::NoBun;
    };
    match measure(bun, shape, bench, turns, instructions) {
        Ok((mips, seconds, tremor)) => Measured::Done {
            mips,
            seconds,
            tremor,
        },
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
fn measure(
    bun: &str,
    shape: Shape,
    bench: &Bench,
    turns: u64,
    instructions: u64,
) -> Result<(f64, f64, f64), String> {
    // **La forme confinée est liée** : elle importe la table de l'hôte et pose
    // ses blocs dedans. C'est celle que l'application exécute, et la mesurer
    // sans sa table mesurerait autre chose.
    let module = match shape {
        Shape::Free => Module::region(bench.code, CODE, 0),
        Shape::Confined => Module::resolving(bench.code, CODE, 0, 0, CONFINED_PAGES),
    }
    .ok_or_else(|| {
        format!(
            "l'émetteur refuse « {} » sous la forme {}",
            bench.name,
            shape.name()
        )
    })?;
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
{}
const slots = [];
for (let slot = 0; slot < {}; slot++) {{
  slots.push(new WebAssembly.Global({{ value: "i64", mutable: true }}, 0n));
}}
const imports = {{ env: {{ mem: memory, out: () => undefined, in: () => 0n }} }};
{}
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

// **Deux fois, et l'écart est imprimé.** Un chronomètre sur une machine
// partagée rend des valeurs qui bougent ; sans un second relevé, rien ne dit
// si un écart entre deux formes est réel ou s'il est le bruit. C'est la leçon
// de `--example resolved`, qui a d'abord publié un rapport gonflé de moitié
// pour avoir comparé deux exécutions séparées d'une heure.
const againBegan = process.hrtime.bigint();
once();
const againSeconds = Number(process.hrtime.bigint() - againBegan) / 1e9;
console.log(JSON.stringify({{
  seconds,
  againSeconds,
  rsi: slots[6].value.toString(),
  rip: BigInt.asUintN(64, slots[{}].value).toString(16),
}}));
"#,
            path.to_string_lossy(),
            // **La taille vient de `host_pages`, jamais d'une addition ici.**
            // Un pilote qui refaisait la somme lui-même a manqué la page du
            // tampon et ne s'instanciait plus, en sortant avec zéro ; un test
            // interdit désormais l'addition sur place.
            match shape {
                Shape::Free => GUEST_PAGES,
                Shape::Confined => host_pages(CONFINED_PAGES),
            },
            // La forme liée réclame la table de l'hôte. La forme libre n'en
            // veut pas, et lui en donner une ne changerait rien — mais un
            // module qui l'importe sans la recevoir ne démarre pas.
            //
            // **L'ordre suit le gabarit, pas la logique.** La déclaration vient
            // avant le compte de globales dans le texte ; les intervertir ici a
            // rendu un pilote qui ne se lisait même pas — « Unexpected ; ».
            match shape {
                Shape::Free => String::new(),
                Shape::Confined =>
                    "const blocks = new WebAssembly.Table({ element: \"anyfunc\", initial: 64 });"
                        .to_string(),
            },
            GLOBAL_COUNT,
            match shape {
                Shape::Free => String::new(),
                Shape::Confined => "imports.env.blocks = blocks;".to_string(),
            },
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
    let unreadable = || format!("la sortie du pilote est illisible — {text}");
    let number = |key: &str| -> Result<f64, String> {
        let start = text.find(key).ok_or_else(unreadable)? + key.len();
        let stop = start + text[start..].find([',', '}']).ok_or_else(unreadable)?;
        text[start..stop].trim().parse().map_err(|_| unreadable())
    };
    let seconds = number("\"seconds\":")?;
    let again = number("\"againSeconds\":")?;
    // **Le meilleur des deux, et l'écart à côté.** Le plus rapide est celui où
    // la machine a le moins été dérangée ; le retenir borne le bruit d'un seul
    // côté au lieu de le laisser des deux. L'écart, lui, est imprimé pour que
    // personne ne lise une différence plus petite que le tremblement.
    let best = seconds.min(again);
    let tremor = (seconds - again).abs() / best;
    Ok((instructions as f64 / best / 1e6, best, tremor))
}
