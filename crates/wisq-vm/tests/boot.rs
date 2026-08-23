//! Boots a real Linux kernel — the same rv32 nommu image the reference emulator
//! runs — and reads its console. There is no better test of an emulator than
//! the guest it was built for.
//!
//! The image is not committed (3.4 MB of GPL binary does not belong in the
//! repo); this looks for it at `WISQ_LINUX_IMAGE` or a well-known local path
//! and skips, loudly, when absent.

use std::sync::{Arc, Mutex};
use wisq_vm::{Machine, Outcome, DEFAULT_RAM_SIZE};

fn image() -> Option<Vec<u8>> {
    let candidates = [
        std::env::var("WISQ_LINUX_IMAGE").ok(),
        Some("/tmp/wisq-test-linux-image/Image".to_string()),
    ];
    for path in candidates.into_iter().flatten() {
        if let Ok(bytes) = std::fs::read(&path) {
            return Some(bytes);
        }
    }
    eprintln!("image Linux absente : définissez WISQ_LINUX_IMAGE pour ce test");
    None
}

fn boot(budget: u64) -> Option<(String, Outcome, u64)> {
    let image = image()?;
    let console = Arc::new(Mutex::new(String::new()));
    let sink = Arc::clone(&console);
    let mut machine = Machine::new(
        DEFAULT_RAM_SIZE,
        Box::new(move |bytes: &[u8]| {
            sink.lock()
                .unwrap()
                .push_str(&String::from_utf8_lossy(bytes));
        }),
    );
    machine
        .load(&image, None)
        .expect("le noyau doit se charger");
    let outcome = machine.run(budget);
    let text = console.lock().unwrap().clone();
    Some((text, outcome, machine.retired_instructions()))
}

#[test]
fn boots_a_real_kernel_to_its_banner() {
    let Some((output, outcome, retired)) = boot(60_000_000) else {
        return;
    };
    assert!(
        output.contains("Linux version"),
        "la bannière du noyau doit apparaître ; sortie : {}",
        &output[..output.len().min(400)]
    );
    assert!(
        output.contains("rv32ima") || output.contains("riscv"),
        "le noyau doit se reconnaître sur du RISC-V"
    );
    assert_eq!(
        outcome,
        Outcome::Stopped,
        "le budget doit expirer, pas la machine planter"
    );
    assert!(
        retired > 1_000_000,
        "le budget doit avoir été réellement consommé"
    );
}

/// The boot is driven by instruction count, not wall time, so two runs of the
/// same image must reach the same place. A boot that is not deterministic is one
/// where a failure cannot be reproduced.
#[test]
fn the_same_image_boots_the_same_way_twice() {
    let Some((first, _, first_retired)) = boot(20_000_000) else {
        return;
    };
    let Some((second, _, second_retired)) = boot(20_000_000) else {
        return;
    };
    assert_eq!(first_retired, second_retired);
    assert_eq!(first, second);
}

#[test]
fn a_command_line_longer_than_the_device_tree_slot_is_refused() {
    let mut machine = Machine::new(DEFAULT_RAM_SIZE, Box::new(|_: &[u8]| {}));
    let result = machine.load(&[0x13, 0x00, 0x00, 0x00], Some(&"x".repeat(100)));
    assert_eq!(result, Err(wisq_vm::LoadError::CommandLineTooLong));
}

#[test]
fn an_empty_image_is_refused() {
    let mut machine = Machine::new(DEFAULT_RAM_SIZE, Box::new(|_: &[u8]| {}));
    assert_eq!(machine.load(&[], None), Err(wisq_vm::LoadError::ImageEmpty));
}
