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
    Module, BENCH_BASE, BENCH_LOOP, BENCH_PER_TURN, GLOBAL_COUNT, GUEST_PAGES, RIP_SLOT,
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

#[test]
fn bench_module_matches_the_probe() {
    let wanted =
        Module::region(&BENCH_LOOP, BENCH_BASE, 0).expect("l'émetteur traduit la boucle du banc");
    let (path, text) = probe();
    let carried = decode(&literal(&text, "moduleBase64")).expect("du base64 lisible");
    assert_eq!(
        carried,
        wanted,
        "le module de {} n'est plus celui que l'émetteur produit ({} octets contre {}). \
         Le réécrire : cargo run -p wisq-vm --release --example bench-module",
        path.display(),
        carried.len(),
        wanted.len()
    );
}

#[test]
fn the_probe_declares_what_the_module_imports() {
    let (_, text) = probe();
    // Un module qui importe vingt-neuf globales et qu'on instancie avec
    // vingt-huit ne démarre pas : la sonde rendrait « l'appareil a refusé » là
    // où c'est une dérive entre deux fichiers du dépôt.
    assert_eq!(number(&text, "guestPages"), u64::from(GUEST_PAGES));
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
