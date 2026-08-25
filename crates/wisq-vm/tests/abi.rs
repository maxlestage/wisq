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
    let stdout = String::from_utf8_lossy(&ran.stdout);
    assert!(
        stdout.contains("ABI conforme"),
        "sortie inattendue :\n{stdout}"
    );

    // The throughput line, because it is the only performance figure the
    // repository takes from the Apple toolchain — scripts/test-ios.sh spawns
    // this same program inside a booted iPhone, and what it prints is what the
    // CI log carries. Nothing there would notice the line quietly disappearing,
    // or a clock that returns zero and makes the whole thing vanish behind its
    // guard, so it is checked here where a test can run.
    //
    // No *lower* threshold: a shared runner cannot hold one without flaking, and
    // the number this machine produces has no bearing on the number a phone
    // would. There is an upper one, and it is not decoration — sabotage moved
    // the stopwatch to after the run, which measures nothing, and a "greater
    // than zero" check waved through a throughput of 4 × 10¹⁶ instructions a
    // second. A stopwatch that measures nothing produces an enormous number,
    // not a small one.
    //
    // Ten billion guest instructions a second is impossible by an order of
    // magnitude for any machine this could run on: a core retires perhaps 10¹⁰
    // of its *own* instructions a second at the very best, and an interpreter
    // spends many of those on each guest instruction. Anything above it is a
    // broken clock rather than a fast computer.
    const IMPOSSIBLE_MILLIONS_PER_SECOND: f64 = 10_000.0;
    let throughput = stdout
        .lines()
        .find_map(|line| line.strip_prefix("débit "))
        .and_then(|rest| rest.split(' ').next())
        .and_then(|number| number.parse::<f64>().ok())
        .unwrap_or_else(|| panic!("aucun débit mesuré :\n{stdout}"));
    assert!(
        throughput > 0.0 && throughput < IMPOSSIBLE_MILLIONS_PER_SECOND,
        "débit implausible ({throughput} M inst/s) : le chronomètre ne mesure \
         probablement pas l'exécution\n{stdout}"
    );
}
