//! **Le module de la sonde WebKit ne peut pas dériver de l'émetteur.**
//!
//! `Sources/WisqCore/WebKitBench.swift` porte un module WebAssembly en base64,
//! parce qu'un iPhone ne peut pas appeler l'émetteur : il n'y a pas de FFI x86,
//! et le bureau local n'est pas encore branché. Une chaîne recopiée est une
//! promesse que rien ne tient — le fichier l'affirmait déjà, sur un module
//! **écrit à la main**, et l'appareil mesurait donc autre chose que ce que wisq
//! engendre.
//!
//! Ce test refait le module et le compare à la chaîne, octet pour octet, puis
//! vérifie les quatre nombres que l'hôte doit fournir pour l'instancier. Il
//! tourne sur Linux, à chaque commit, sans chaîne Swift.
use std::path::{Path, PathBuf};
use wisq_vm::x86_wasm::{
    host_pages, Module, BENCH_BASE, BENCH_CONFINED_PAGES, BENCH_LOOP,
    BENCH_MEMORY_ACCESSES_PER_TURN, BENCH_MEMORY_LOOP, BENCH_MEMORY_PER_TURN, BENCH_PER_TURN,
    GLOBAL_COUNT, GUEST_PAGES, RIP_SLOT,
};

fn probe() -> (PathBuf, String) {
    // CARGO_MANIFEST_DIR est crates/wisq-vm.
    let path = Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .and_then(Path::parent)
        .expect("racine de l'espace de travail")
        .join("Sources/WisqCore/WebKitBench.swift");
    let text = std::fs::read_to_string(&path).expect("la sonde WebKit doit être lisible");
    (path, text)
}

/// Le décodeur, écrit ici plutôt qu'emprunté : la caisse n'a **aucune
/// dépendance**, exprès. C'est aussi le sens de la marche qui compte — c'est
/// `Data(base64Encoded:)` que Swift exécutera sur cette chaîne.
fn decode(text: &str) -> Option<Vec<u8>> {
    let rank = |byte: u8| match byte {
        b'A'..=b'Z' => Some(byte - b'A'),
        b'a'..=b'z' => Some(byte - b'a' + 26),
        b'0'..=b'9' => Some(byte - b'0' + 52),
        b'+' => Some(62),
        b'/' => Some(63),
        _ => None,
    };
    let mut out = Vec::new();
    let mut word = 0u32;
    let mut held = 0;
    for byte in text.bytes() {
        if byte == b'=' {
            break;
        }
        let value = rank(byte)?;
        word = (word << 6) | u32::from(value);
        held += 6;
        if held >= 8 {
            held -= 8;
            out.push((word >> held) as u8);
        }
    }
    Some(out)
}

/// La chaîne Swift est une concaténation de littéraux ; on la recolle.
fn literal(text: &str, name: &str) -> String {
    let needle = format!("static let {name} =");
    let start = text
        .find(&needle)
        .unwrap_or_else(|| panic!("la sonde doit déclarer {name}"));
    let rest = &text[start..];
    let stop = rest.find("\n\n").unwrap_or(rest.len());
    rest[..stop]
        .split('"')
        .skip(1)
        .step_by(2)
        .collect::<String>()
}

/// La valeur d'une constante entière Swift, sans ses soulignements.
fn number(text: &str, name: &str) -> u64 {
    let needle = format!("static let {name}");
    let start = text
        .find(&needle)
        .unwrap_or_else(|| panic!("la sonde doit déclarer {name}"));
    let value = text[start..]
        .split('=')
        .nth(1)
        .expect("une constante a une valeur")
        .lines()
        .next()
        .expect("sur sa ligne")
        .trim()
        .replace('_', "");
    if let Some(hex) = value.strip_prefix("0x") {
        u64::from_str_radix(hex, 16).expect("un entier hexadécimal")
    } else {
        value.parse().expect("un entier décimal")
    }
}

/// **Les trois modules, chacun contre ce que l'émetteur produit.**
///
/// La sonde n'en portait qu'un, et sous la forme **libre** : l'application
/// n'exécute que `Module::resolving`, et la boucle de registres ne touche pas
/// la mémoire, où est tout le surcoût du confinement. Le chiffre de l'appareil
/// décrivait donc une forme qu'il ne lancera jamais, sur la seule boucle
/// incapable de le montrer.
#[test]
fn bench_module_matches_the_probe() {
    let attendus: [(&str, Vec<u8>); 3] = [
        (
            "moduleBase64",
            Module::resolving(&BENCH_LOOP, BENCH_BASE, 0, 0, BENCH_CONFINED_PAGES)
                .expect("la boucle de registres, confinée"),
        ),
        (
            "memoryModuleBase64",
            Module::resolving(&BENCH_MEMORY_LOOP, BENCH_BASE, 0, 1, BENCH_CONFINED_PAGES)
                .expect("la boucle mémoire, confinée"),
        ),
        (
            "freeMemoryModuleBase64",
            Module::region(&BENCH_MEMORY_LOOP, BENCH_BASE, 0).expect("la boucle mémoire, libre"),
        ),
    ];
    let (path, text) = probe();
    for (name, wanted) in attendus {
        let carried = decode(&literal(&text, name)).expect("du base64 lisible");
        assert_eq!(
            carried,
            wanted,
            "{name} de {} n'est plus celui que l'émetteur produit ({} octets contre {}). \
             Le réécrire : cargo run -p wisq-vm --release --example bench-module",
            path.display(),
            carried.len(),
            wanted.len()
        );
    }
}

/// **Les trois ne servent que sous la même forme et sur les mêmes boucles.**
///
/// Deux confinés et un libre : c'est cette dissymétrie qui rend le coût par
/// accès. Un jour où les trois deviendraient confinés, l'écart disparaîtrait
/// et la sonde rendrait « rien de mesurable » sans que rien ne le dise.
#[test]
fn the_probe_carries_two_confined_modules_and_one_free() {
    let (_, text) = probe();
    let libre = Module::region(&BENCH_MEMORY_LOOP, BENCH_BASE, 0).expect("la forme libre");
    let confine = Module::resolving(&BENCH_MEMORY_LOOP, BENCH_BASE, 0, 1, BENCH_CONFINED_PAGES)
        .expect("la forme confinée");
    assert_ne!(
        libre, confine,
        "les deux formes de la même boucle rendent les mêmes octets : \
         l'écart que la sonde mesure ne peut plus rien coûter"
    );
    let porte = |name: &str| decode(&literal(&text, name)).expect("du base64 lisible");
    assert_eq!(porte("memoryModuleBase64"), confine);
    assert_eq!(porte("freeMemoryModuleBase64"), libre);
}

/// **Deux modules confinés ne peuvent pas partager un créneau de table.**
///
/// Les blocs de toutes les régions vivent dans la même table, et un module y
/// pose les siens à partir de son créneau. Deux modules au même créneau
/// s'écrasent : le second instancié remplace les entrées du premier, qui saute
/// alors dans le code de l'autre — sans piège et sans message, `run` rend la
/// main aussitôt. C'est exactement ce qui est arrivé, et rien ne l'a dit avant
/// que la sonde entière ne soit exécutée sous Bun.
///
/// Ce test compare les blocs relevés au pas entre les deux créneaux : tant que
/// la boucle de registres tient dans un seul bloc, le créneau 1 est libre.
#[test]
fn the_two_confined_modules_do_not_share_a_table_slot() {
    let registres = Module::survey(&BENCH_LOOP, 0).expect("le relevé de la boucle de registres");
    assert!(
        registres.blocks <= 1,
        "la boucle de registres occupe {} blocs : le module mémoire, posé au créneau 1, \
         écraserait les siens",
        registres.blocks
    );
}

/// **Ce que l'hôte alloue ne se recalcule pas dans la sonde.**
///
/// La RAM, la correspondance adresse → indice et le tampon : trois nombres, une
/// seule addition, et elle vit dans la bibliothèque. Un pilote qui l'a refaite
/// lui-même a manqué la page du tampon, ne s'instanciait plus, et sortait avec
/// zéro — personne ne l'a vu pendant toute une série de tranches.
#[test]
fn the_probe_asks_for_what_host_pages_says() {
    let (_, text) = probe();
    assert_eq!(
        number(&text, "confinedPages"),
        u64::from(BENCH_CONFINED_PAGES)
    );
    assert_eq!(
        number(&text, "hostPages"),
        u64::from(host_pages(BENCH_CONFINED_PAGES))
    );
    assert_eq!(
        number(&text, "memoryInstructionsPerTurn"),
        BENCH_MEMORY_PER_TURN
    );
    assert_eq!(
        number(&text, "memoryAccessesPerTurn"),
        BENCH_MEMORY_ACCESSES_PER_TURN
    );
}

#[test]
fn the_probe_declares_what_the_module_imports() {
    let (_, text) = probe();
    // Un module qui importe vingt-neuf globales et qu'on instancie avec
    // vingt-huit ne démarre pas : la sonde rendrait « l'appareil a refusé » là
    // où c'est une dérive entre deux fichiers du dépôt.
    assert_eq!(number(&text, "globalCount"), GLOBAL_COUNT as u64);
    assert_eq!(number(&text, "ripSlot"), RIP_SLOT as u64);
    assert_eq!(number(&text, "benchBase"), BENCH_BASE);
    assert_eq!(number(&text, "instructionsPerTurn"), BENCH_PER_TURN);
}

/// **Ce qui traverse l'ABI est exactement ce que l'émetteur produit.**
///
/// Le programme C d'à côté vérifie la forme du module ; celui-ci vérifie qu'il
/// n'a pas changé en chemin. Une copie, une troncature ou un octet perdu entre
/// `Module::region` et le pointeur rendu à Swift ne donnerait pas un module
/// invalide — WebAssembly a des tailles de section — mais un module qui calcule
/// autre chose, et personne ne le verrait avant l'appareil.
#[test]
fn the_abi_hands_back_exactly_what_the_emitter_produced() {
    let wanted =
        Module::region(&BENCH_LOOP, BENCH_BASE, 0).expect("l'émetteur traduit la boucle du banc");

    let mut bytes: *mut u8 = std::ptr::null_mut();
    let mut len: usize = 0;
    // SAFETY: la région est valide pour `BENCH_LOOP.len()` octets, et les deux
    // sorties sont des locales adressables.
    let code = unsafe {
        let outcome = wisq_vm::ffi::wisq_x86_emit_region(
            BENCH_LOOP.as_ptr(),
            BENCH_LOOP.len(),
            BENCH_BASE,
            0,
            &mut bytes,
            &mut len,
        );
        assert_eq!(outcome, 0, "l'ABI accepte ce que l'émetteur accepte");
        assert!(!bytes.is_null());
        std::slice::from_raw_parts(bytes, len).to_vec()
    };
    // SAFETY: `bytes` et `len` sont exactement ce que l'appel vient de rendre.
    unsafe { wisq_vm::ffi::wisq_x86_free_module(bytes, len) };

    assert_eq!(code, wanted, "l'ABI ne rend pas les octets de l'émetteur");
}

/// Les quatre nombres que l'ABI exporte sont ceux de l'émetteur. Un hôte qui
/// crée vingt-huit globales pour un module qui en importe vingt-neuf n'obtient
/// pas un mauvais chiffre : il n'obtient rien.
#[test]
fn the_abi_describes_what_the_module_imports() {
    assert_eq!(wisq_vm::ffi::wisq_x86_guest_pages(), GUEST_PAGES);
    assert_eq!(wisq_vm::ffi::wisq_x86_global_count(), GLOBAL_COUNT);
    assert_eq!(wisq_vm::ffi::wisq_x86_rip_slot(), RIP_SLOT);
    assert_eq!(wisq_vm::ffi::wisq_x86_gs_slot(), wisq_vm::x86_wasm::GS_SLOT);
}
