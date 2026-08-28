//! A snapshot is only worth taking if the machine that comes back is the one
//! that was saved.
//!
//! "It boots afterwards" is the weak claim, and the one a broken snapshot
//! passes easily: a machine restored with a stale timer or a lost register
//! carries on and looks fine, then diverges somewhere nobody is watching. So
//! the test here is stricter — run a machine, save it, keep running the
//! original, and separately restore and run the copy the same distance. The
//! two futures must be identical, instruction count and console bytes alike.
//!
//! The kernel image is not committed; the tests skip loudly without it.

use std::sync::{Arc, Mutex};
use wisq_vm::{Machine, DEFAULT_RAM_SIZE};

fn image() -> Option<Vec<u8>> {
    let path = std::env::var("WISQ_LINUX_IMAGE")
        .unwrap_or_else(|_| "/tmp/wisq-test-linux-image/Image".to_string());
    std::fs::read(path).ok()
}

/// A machine plus the console it has written so far.
struct Recorded {
    machine: Machine,
    console: Arc<Mutex<Vec<u8>>>,
}

fn machine() -> Recorded {
    let console = Arc::new(Mutex::new(Vec::new()));
    let sink = Arc::clone(&console);
    let machine = Machine::new(
        DEFAULT_RAM_SIZE,
        Box::new(move |bytes: &[u8]| sink.lock().unwrap().extend_from_slice(bytes)),
    );
    Recorded { machine, console }
}

/// Runs `machine` in slices until `console` grows past `was`, and reports the
/// budget it took. Returns None if the guest stayed silent for the whole cap.
///
/// The alternative — a hard-coded instruction count — makes the test a
/// property of one kernel image. This one is silent for its first 24 million
/// instructions and then writes 2 777 bytes at once, so a window picked by
/// hand lands in a quiet stretch and the comparison passes on two empty
/// strings. Finding the point instead means the test keeps its teeth when the
/// image changes.
fn run_until_console_grows(
    machine: &mut Machine,
    console: &Arc<Mutex<Vec<u8>>>,
    was: usize,
    cap: u64,
) -> Option<u64> {
    const SLICE: u64 = 2_000_000;
    let mut spent = 0;
    while spent < cap {
        machine.run(SLICE);
        spent += SLICE;
        if console.lock().unwrap().len() > was {
            return Some(spent);
        }
    }
    None
}

#[test]
fn a_restored_machine_continues_the_same_future() {
    let Some(image) = image() else {
        eprintln!("image Linux absente : définissez WISQ_LINUX_IMAGE pour ce test");
        return;
    };

    let mut original = machine();
    original
        .machine
        .load(&image, Some("console=ttyS0"))
        .unwrap();

    // Snapshot once the guest has actually said something: a machine that has
    // not reached its first write yet proves very little about restoring one.
    let Some(_) = run_until_console_grows(&mut original.machine, &original.console, 0, 60_000_000)
    else {
        panic!("l'invité n'a rien écrit : image inattendue, le test ne peut rien comparer");
    };

    let saved = original.machine.snapshot();
    let retired_at_snapshot = original.machine.retired_instructions();
    let console_at_snapshot = original.console.lock().unwrap().clone();
    assert!(
        String::from_utf8_lossy(&console_at_snapshot).contains("Linux version"),
        "l'instantané doit être pris sur un vrai démarrage"
    );

    // Carry the original on to the guest's next write, and remember what that
    // cost so the copy can be given exactly the same budget.
    let after = run_until_console_grows(
        &mut original.machine,
        &original.console,
        console_at_snapshot.len(),
        60_000_000,
    )
    .expect("l'invité doit réécrire après l'instantané");
    let original_retired = original.machine.retired_instructions();
    let original_console = original.console.lock().unwrap().clone();

    // The copy starts from the snapshot, with a console of its own.
    let mut copy = machine();
    copy.machine.restore(&saved).expect("restauration");
    assert_eq!(
        copy.machine.retired_instructions(),
        retired_at_snapshot,
        "le compteur d'instructions doit revenir tel quel"
    );
    copy.machine.run(after);

    assert_eq!(
        copy.machine.retired_instructions(),
        original_retired,
        "la copie restaurée doit retirer exactement les mêmes instructions"
    );

    let copy_console = copy.console.lock().unwrap().clone();
    assert!(
        !copy_console.is_empty(),
        "la copie doit avoir réellement écrit après restauration"
    );
    let mut expected = console_at_snapshot;
    expected.extend_from_slice(&copy_console);
    assert_eq!(
        String::from_utf8_lossy(&expected),
        String::from_utf8_lossy(&original_console),
        "la console d'après restauration doit prolonger celle d'avant, octet pour octet"
    );
}

#[test]
fn a_snapshot_of_a_booted_machine_is_far_smaller_than_its_ram() {
    let Some(image) = image() else {
        eprintln!("image Linux absente : définissez WISQ_LINUX_IMAGE pour ce test");
        return;
    };
    let mut booted = machine();
    booted.machine.load(&image, Some("console=ttyS0")).unwrap();
    booted.machine.run(8_000_000);

    let saved = booted.machine.snapshot();
    // The point of folding zero runs: a phone has to be able to write this on
    // every backgrounding. Untouched RAM must not be paid for.
    assert!(
        saved.len() < DEFAULT_RAM_SIZE / 4,
        "instantané de {} octets pour {} de RAM — le repli des zéros ne fait pas son travail",
        saved.len(),
        DEFAULT_RAM_SIZE
    );
    eprintln!(
        "instantané : {:.1} Mio pour {} Mio de RAM",
        saved.len() as f64 / (1024.0 * 1024.0),
        DEFAULT_RAM_SIZE / (1024 * 1024)
    );
}

#[test]
fn restoring_rubbish_leaves_the_machine_alone() {
    let mut m = machine();
    m.machine
        .load(&[0x13, 0x00, 0x00, 0x00], Some("console=ttyS0"))
        .unwrap();
    m.machine.run(1000);
    let before = m.machine.snapshot();

    for rubbish in [
        b"".to_vec(),
        b"pas un instantane".to_vec(),
        before[..before.len() / 2].to_vec(),
        {
            let mut extra = before.clone();
            extra.push(0);
            extra
        },
    ] {
        assert!(
            m.machine.restore(&rubbish).is_err(),
            "entrée acceptée à tort"
        );
        assert_eq!(
            m.machine.snapshot(),
            before,
            "une restauration refusée ne doit rien avoir changé"
        );
    }
}

#[test]
fn a_snapshot_from_another_ram_size_is_refused_by_name() {
    let mut small = Machine::new(1 << 20, Box::new(|_: &[u8]| {}));
    small.load(&[0x13, 0x00, 0x00, 0x00], None).unwrap();
    let saved = small.snapshot();

    let mut big = Machine::new(2 << 20, Box::new(|_: &[u8]| {}));
    match big.restore(&saved) {
        Err(wisq_vm::SnapshotError::RamSizeMismatch { saved, expected }) => {
            assert_eq!(saved, 1 << 20);
            assert_eq!(expected, 2 << 20);
        }
        other => panic!("attendu un refus nommé, obtenu {other:?}"),
    }
}

/// Input queued but not yet consumed is machine state: dropping it loses a
/// keystroke the user has already typed.
#[test]
fn queued_keystrokes_survive() {
    let mut m = Machine::new(1 << 20, Box::new(|_: &[u8]| {}));
    m.load(&[0x13, 0x00, 0x00, 0x00], None).unwrap();
    m.handle().send(b"echo bonjour\n");

    let saved = m.snapshot();
    let mut back = Machine::new(1 << 20, Box::new(|_: &[u8]| {}));
    back.restore(&saved).expect("restauration");
    assert_eq!(
        back.snapshot(),
        saved,
        "la file d'entrée doit revenir telle quelle"
    );
}

/// Output produced and not yet handed over is machine state too, and it is the
/// half nobody thinks of: the bytes have left the guest's UART and have not
/// reached the terminal, so losing them loses a line the guest believes it
/// printed.
///
/// Measured, and it is the one gap the two cores had in common. Each of the
/// fifty-one assignments in `restore` was removed in turn and this suite run
/// against it: fifty of the fifty-one were noticed, and this was the one that
/// was not. The Swift core was swept the same way and came out at thirty-five
/// unheld out of fifty-one — the same format, the same claim, very different
/// amounts of proof — and `pending_output` was unheld on both sides.
///
/// The snapshot is built by editing a real one rather than assembled from
/// scratch: the RAM section is run-length encoded, and a hand-written encoder
/// in a test would be a second implementation of the thing under test. The
/// pending-output blob is the last section, so replacing it is the whole edit.
#[test]
fn console_bytes_not_yet_flushed_survive() {
    let mut m = Machine::new(1 << 20, Box::new(|_: &[u8]| {}));
    m.load(&[0x13, 0x00, 0x00, 0x00], None).unwrap();
    let base = m.snapshot();
    assert_eq!(
        &base[base.len() - 8..],
        &[0u8; 8],
        "l'instantané d'une machine qui n'a pas tourné doit finir sur un blob vide"
    );

    let pending = [0xF0u8, 0x0D, 0xBA, 0xBE];
    let mut edited = base[..base.len() - 8].to_vec();
    edited.extend_from_slice(&(pending.len() as u64).to_le_bytes());
    edited.extend_from_slice(&pending);

    let mut back = Machine::new(1 << 20, Box::new(|_: &[u8]| {}));
    back.restore(&edited).expect("restauration");
    assert_eq!(
        back.snapshot(),
        edited,
        "les octets en attente pour la console doivent survivre à la restauration"
    );
}

/// The same six instructions the app-layer tests use: write one line to the
/// UART, then spin quietly. Small enough to need no kernel image, so this runs
/// on every commit rather than only where one has been downloaded.
const TINY_GUEST: [u32; 6] = [
    0x1000_00B7, // lui  x1, 0x10000   — the UART
    0x0410_0113, // addi x2, x0, 65    — 'A'
    0x0020_8023, // sb   x2, 0(x1)
    0x00A0_0113, // addi x2, x0, 10    — newline
    0x0020_8023, // sb   x2, 0(x1)
    0x0000_0063, // beq  x0, x0, 0     — then spin
];

fn tiny_guest_image() -> Vec<u8> {
    TINY_GUEST.iter().flat_map(|w| w.to_le_bytes()).collect()
}

/// A stop that arrives while the machine is resuming must survive the resume.
///
/// `restore` used to clear the stop flag along with everything else, on the
/// reasoning that it restores the machine's whole state. That flag is not part
/// of the machine's state — it is the owner asking this machine to come back —
/// and clearing it threw the request away. The app restores on a background
/// thread and can be told to stop from the main one before that finishes, which
/// is what leaving the screen the instant it opens does; the machine then ran
/// with nothing able to end it, on a phone, until the process died.
///
/// The assertion is on retired instructions, not on the outcome: `Stopped` is
/// also what an exhausted budget returns, so the outcome alone cannot tell the
/// two apart. The bounded budget is what keeps a regression a failing test
/// rather than a hanging one.
#[test]
fn a_stop_asked_for_while_resuming_is_not_lost() {
    let mut machine = Machine::new(DEFAULT_RAM_SIZE, Box::new(|_: &[u8]| {}));
    machine.load(&tiny_guest_image(), None).unwrap();
    machine.run(10_000);
    let saved = machine.snapshot();

    let mut resumed = Machine::new(DEFAULT_RAM_SIZE, Box::new(|_: &[u8]| {}));
    resumed.handle().stop();
    resumed.restore(&saved).unwrap();

    let before = resumed.retired_instructions();
    resumed.run(1_000_000);
    assert_eq!(
        resumed.retired_instructions(),
        before,
        "un arrêt demandé avant la reprise doit être honoré : rien ne doit s'exécuter"
    );
}
