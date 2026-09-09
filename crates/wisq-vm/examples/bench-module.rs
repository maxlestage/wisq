//! **Les modules que la sonde de l'appareil chronomètre, engendrés ici.**
//!
//! L'iPhone ne peut pas appeler l'émetteur : il n'y a pas de FFI x86, et le
//! bureau local n'est pas encore branché. La sonde porte donc les modules en
//! base64, et ce programme est ce qui les écrit — pas une main.
//!
//!     cargo run -p wisq-vm --release --example bench-module
//!
//! Le texte imprimé se colle tel quel dans `Sources/WisqCore/WebKitBench.swift`.
//! Le test `bench_module_matches_the_probe` refuse de passer tant que les deux
//! ne coïncident pas à l'octet près, donc l'oubli de coller se voit en CI.
//!
//! **Trois modules, et ce n'est pas de la générosité.** La sonde a longtemps
//! porté un seul `Module::region` — la forme **libre** — sur `BENCH_LOOP`, cinq
//! instructions de registres sans un seul accès mémoire. C'était la seule
//! combinaison qui ne pouvait rien montrer : l'application n'exécute que
//! `Module::resolving`, et tout ce que le confinement ajoute est **sur les
//! accès mémoire**.
//!
//! Il faut donc trois relevés, et chacun répond à une question que les autres
//! ne posent pas :
//!
//!   * `moduleBase64` — confiné, boucle de registres : le débit de la forme que
//!     le bureau exécute, sur la boucle de cinq instructions qui est la taille
//!     moyenne d'un bloc de base du noyau Alpine. C'est le chiffre représentatif.
//!   * `memoryModuleBase64` — confiné, boucle mémoire.
//!   * `freeMemoryModuleBase64` — **libre**, la même boucle mémoire.
//!
//! Les deux derniers ne servent qu'ensemble : leur écart est ce que le
//! confinement coûte par accès mémoire, **sur cet appareil-là**. Le container
//! de la CI l'a mesuré autour d'une nanoseconde, en disant que c'était un ordre
//! de grandeur ; le JavaScriptCore d'un iPhone est une autre machine, et la
//! sonde est le seul endroit qui puisse le dire.
//!
//! Un seul relevé confiné ne peut pas rendre ce coût : il faut les deux formes
//! sur la **même** boucle. Soustraire deux boucles différentes mélangerait le
//! coût d'un accès et celui d'un jeu d'instructions.
use wisq_vm::x86_wasm::{
    host_pages, Module, BENCH_BASE, BENCH_CONFINED_PAGES, BENCH_LOOP, BENCH_MEMORY_LOOP,
};

/// L'encodeur, écrit ici plutôt qu'emprunté : la caisse n'a aucune dépendance,
/// **exprès** — elle est liée dans une application iOS, et chaque caisse de plus
/// est un audit et une compilation croisée de plus.
fn base64(bytes: &[u8]) -> String {
    const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::new();
    for group in bytes.chunks(3) {
        let mut word = 0u32;
        for (rank, byte) in group.iter().enumerate() {
            word |= u32::from(*byte) << (16 - 8 * rank);
        }
        for rank in 0..4 {
            if rank <= group.len() {
                out.push(ALPHABET[(word >> (18 - 6 * rank)) as usize & 0x3f] as char);
            } else {
                out.push('=');
            }
        }
    }
    out
}

fn main() {
    // **La forme est celle que l'application exécute, et rien d'autre.** Un
    // module libre se compilerait aussi, et l'appareil rendrait un chiffre plus
    // flatteur pour une forme qu'il ne lancera jamais.
    // **Le créneau, et pourquoi il diffère.** Les modules confinés posent leurs
    // blocs dans la table de l'hôte, à partir du créneau qu'on leur donne. Deux
    // modules au même créneau s'écrasent : le second instancié remplace les
    // entrées du premier, et le premier saute alors dans le code de l'autre.
    //
    // Ce n'est pas une hypothèse. Les deux ont d'abord été émis au créneau 0, et
    // le module de registres a cessé d'exécuter quoi que ce soit dès que celui
    // de la mémoire était instancié à côté — sans rien piéger, sans rien dire :
    // `run` rendait la main aussitôt. Chaque boucle fait un bloc, relevé par
    // `Module::survey`, donc 0 et 1 suffisent.
    let modules = [
        (
            "moduleBase64",
            "confinée, registres",
            &BENCH_LOOP[..],
            Some(0),
        ),
        (
            "memoryModuleBase64",
            "confinée, mémoire",
            &BENCH_MEMORY_LOOP[..],
            Some(1),
        ),
        (
            "freeMemoryModuleBase64",
            "libre, mémoire",
            &BENCH_MEMORY_LOOP[..],
            None,
        ),
    ];

    eprintln!(
        "forme confinée, {} pages de RAM invitée, {} pages à allouer par l'hôte",
        BENCH_CONFINED_PAGES,
        host_pages(BENCH_CONFINED_PAGES)
    );

    for (name, what, code, slot) in modules {
        let built = match slot {
            Some(slot) => Module::resolving(code, BENCH_BASE, 0, slot, BENCH_CONFINED_PAGES),
            None => Module::region(code, BENCH_BASE, 0),
        };
        let Some(module) = built else {
            eprintln!("l'émetteur a refusé « {what} » — il n'y a rien à coller");
            std::process::exit(1);
        };
        let text = base64(&module);
        eprintln!(
            "{name} ({what}) : {} octets, {} caractères",
            module.len(),
            text.len()
        );
        println!("    public static let {name} =");
        let mut first = true;
        for chunk in text.as_bytes().chunks(112) {
            let line = std::str::from_utf8(chunk).unwrap();
            let lead = if first { "        " } else { "        + " };
            println!("{lead}\"{line}\"");
            first = false;
        }
        println!();
    }
}
