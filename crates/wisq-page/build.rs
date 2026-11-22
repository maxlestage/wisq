//! **La table de fonctions du module de la page, exportée et extensible.**
//!
//! La boucle hôte en Rust (`src/hote.rs`) appelle des fonctions d'autres
//! instances — le module d'accès, puis les `run` des modules traduits — par
//! des indices de sa propre table de fonctions. La page doit donc pouvoir la
//! lire (`--export-table`, qui l'exporte sous `__indirect_function_table`) et
//! y ajouter des cases (`--growable-table`). Seulement pour wasm32 : en natif,
//! ces options ne veulent rien dire à l'éditeur de liens.
fn main() {
    println!("cargo:rerun-if-changed=build.rs");
    if std::env::var("CARGO_CFG_TARGET_ARCH").as_deref() == Ok("wasm32") {
        println!("cargo:rustc-link-arg-cdylib=--export-table");
        println!("cargo:rustc-link-arg-cdylib=--growable-table");
    }
}
