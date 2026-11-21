//! **Le module de la page, embarqué quand on le demande.**
//!
//! `WISQ_PAGE_WASM=<chemin de wisq_page.wasm>` le recopie dans la
//! bibliothèque (`emitter_machine::PAGE_MODULE`), pour l'application :
//! `scripts/build-xcframework.sh` le construit d'abord
//! (`scripts/build-page-emitter.sh`), puis pose la variable. Sans elle, rien
//! n'est embarqué, et c'est la construction de tous les jours — celle des
//! tests, des bancs et du cœur Linux. Un chemin donné qui ne désigne aucun
//! fichier arrête la construction : une application qui partirait sans le
//! module qu'on lui a demandé se tairait jusqu'au premier démarrage.
fn main() {
    println!("cargo::rustc-check-cfg=cfg(wisq_page_module)");
    println!("cargo:rerun-if-env-changed=WISQ_PAGE_WASM");
    let Ok(chemin) = std::env::var("WISQ_PAGE_WASM") else {
        return;
    };
    // **Jamais dans le module lui-même** : `wisq-page` compile ce crate pour
    // wasm32, et un module qui s'embarquerait se reconstruirait sans fin, sa
    // propre sortie changeant à chaque tour.
    if chemin.trim().is_empty() || std::env::var("CARGO_CFG_TARGET_ARCH").as_deref() == Ok("wasm32")
    {
        return;
    }
    let fichier = std::path::Path::new(&chemin);
    match std::fs::metadata(fichier) {
        Ok(meta) if meta.is_file() && meta.len() > 0 => {}
        _ => panic!("WISQ_PAGE_WASM={chemin} ne désigne pas un module : scripts/build-page-emitter.sh le construit"),
    }
    let absolu = fichier
        .canonicalize()
        .expect("le chemin du module de la page");
    println!("cargo:rerun-if-changed={}", absolu.display());
    println!("cargo:rustc-cfg=wisq_page_module");
    println!(
        "cargo:rustc-env=WISQ_PAGE_WASM_EMBARQUE={}",
        absolu.display()
    );
}
