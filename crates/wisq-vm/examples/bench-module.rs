//! **Le module que la sonde de l'appareil chronomètre, engendré ici.**
//!
//! L'iPhone ne peut pas appeler l'émetteur : il n'y a pas de FFI x86, et le
//! bureau local n'est pas encore branché. La sonde porte donc le module en
//! base64, et ce programme est ce qui l'écrit — pas une main.
//!
//!     cargo run -p wisq-vm --release --example bench-module
//!
//! Le texte imprimé se colle tel quel dans `Sources/WisqCore/WebKitBench.swift`.
//! Le test `bench_module_matches_the_probe` refuse de passer tant que les deux
//! ne coïncident pas à l'octet près, donc l'oubli de coller se voit en CI.
use wisq_vm::x86_wasm::{Module, BENCH_BASE, BENCH_LOOP};

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
    let Some(module) = Module::region(&BENCH_LOOP, BENCH_BASE, 0) else {
        eprintln!("l'émetteur a refusé la boucle du banc — il n'y a rien à coller");
        std::process::exit(1);
    };
    let text = base64(&module);
    eprintln!("{} octets, {} caractères", module.len(), text.len());
    let mut first = true;
    for chunk in text.as_bytes().chunks(112) {
        let line = std::str::from_utf8(chunk).unwrap();
        let lead = if first { "        " } else { "        + " };
        println!("{lead}\"{line}\"");
        first = false;
    }
}
