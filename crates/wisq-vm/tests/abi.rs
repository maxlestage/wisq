//! Compiles the C conformance program against the header and runs it.
//!
//! `include/wisq_vm.h` is hand-written, and a hand-written header is a
//! promise nothing enforces: a signature that drifts from `src/ffi.rs` is
//! not a Rust error, not a Swift error, and not a crash until memory is
//! already wrong — on a phone. This runs the same program that
//! `scripts/test-ios.sh` runs inside a simulator, so the ABI is checked on
//! every commit on Linux rather than only on the macOS job.
//!
//! It skips loudly when a C compiler or the kernel image is missing, which
//! is the same posture as the boot test beside it.

use std::path::{Path, PathBuf};
use std::process::Command;

fn workspace_root() -> PathBuf {
    // CARGO_MANIFEST_DIR is crates/wisq-vm.
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .and_then(Path::parent)
        .expect("racine de l'espace de travail")
        .to_path_buf()
}

fn kernel_image() -> Option<PathBuf> {
    let candidates = [
        std::env::var("WISQ_LINUX_IMAGE").ok(),
        Some("/tmp/wisq-test-linux-image/Image".to_string()),
    ];
    candidates
        .into_iter()
        .flatten()
        .map(PathBuf::from)
        .find(|path| path.is_file())
}

/// The static library the C program links. `cargo test` builds the rlib but
/// not necessarily the staticlib for this profile, so it is built explicitly.
fn static_library(root: &Path) -> Option<PathBuf> {
    let built = Command::new(env!("CARGO"))
        .args(["build", "--release", "-p", "wisq-vm"])
        .current_dir(root)
        .status()
        .ok()?;
    if !built.success() {
        return None;
    }
    let path = root.join("target/release/libwisq_vm.a");
    path.is_file().then_some(path)
}

#[test]
fn the_c_header_matches_the_library_it_describes() {
    let root = workspace_root();

    let Some(image) = kernel_image() else {
        eprintln!("image Linux absente : définissez WISQ_LINUX_IMAGE pour ce test");
        return;
    };
    let compiler = std::env::var("CC").unwrap_or_else(|_| "cc".to_string());
    if Command::new(&compiler).arg("--version").output().is_err() {
        eprintln!("aucun compilateur C ({compiler}) : test d'ABI ignoré");
        return;
    }
    let Some(library) = static_library(&root) else {
        eprintln!("libwisq_vm.a introuvable : test d'ABI ignoré");
        return;
    };

    let out = std::env::temp_dir().join(format!("wisq-abi-{}", std::process::id()));
    let compiled = Command::new(&compiler)
        .args(["-O2", "-Wall", "-Wextra", "-Werror"])
        .arg("-I")
        .arg(root.join("crates/wisq-vm/include"))
        .arg(root.join("crates/wisq-vm/tests/abi/main.c"))
        .arg("-L")
        .arg(library.parent().expect("dossier de la bibliothèque"))
        .args(["-lwisq_vm", "-lpthread", "-ldl", "-lm", "-o"])
        .arg(&out)
        .output()
        .expect("compilation du programme d'ABI");
    assert!(
        compiled.status.success(),
        "l'en-tête ne compile pas contre la bibliothèque :\n{}",
        String::from_utf8_lossy(&compiled.stderr)
    );

    let ran = Command::new(&out)
        .arg(&image)
        .output()
        .expect("exécution du programme d'ABI");
    let _ = std::fs::remove_file(&out);
    assert!(
        ran.status.success(),
        "le programme d'ABI a échoué :\n{}\n{}",
        String::from_utf8_lossy(&ran.stdout),
        String::from_utf8_lossy(&ran.stderr)
    );
    assert!(
        String::from_utf8_lossy(&ran.stdout).contains("ABI conforme"),
        "sortie inattendue :\n{}",
        String::from_utf8_lossy(&ran.stdout)
    );
}
