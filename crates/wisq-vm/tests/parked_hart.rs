//! A guest that parks itself with nothing to wait for.
//!
//! `WFI` sleeps the hart until an interrupt arrives, and on this machine the
//! timer is the only interrupt there is — a parked hart executes nothing, so it
//! cannot poll the UART either. Run `WFI` without arming `mtimecmp` and nothing
//! will ever wake it.
//!
//! The budget cannot end that wait. It counts instructions the guest *retired*,
//! deliberately, so an idle guest cannot spend a budget by doing nothing — and a
//! parked hart retires nothing at all. Before the guard in `machine.rs`, this
//! guest retired one instruction and then spun at full speed for ever.
//!
//! The Swift core has the same guard and `Tests/WisqVMTests/ParkedHartTests` the
//! same three cases, because the two interpreters have to answer this the same
//! way or a saved machine stops resuming.

use std::sync::mpsc;
use std::thread;
use std::time::Duration;
use wisq_vm::{Machine, Outcome, DEFAULT_RAM_SIZE};

/// `wfi ; beq x0, x0, 0` — parks with no timer armed.
const PARKS_IMMEDIATELY: [u32; 2] = [0x1050_0073, 0x0000_0063];

/// `lui x1, 0x11004 ; addi x2, x0, 2047 ; sw x2, 0(x1) ; wfi ; beq x0, x0, 0` —
/// arms the CLINT's `mtimecmp` first, so the wait is one that ends.
const ARMS_A_TIMER_THEN_PARKS: [u32; 5] = [
    0x1100_40B7,
    0x7FF0_0113,
    0x0020_A023,
    0x1050_0073,
    0x0000_0063,
];

fn image(program: &[u32]) -> Vec<u8> {
    program.iter().flat_map(|w| w.to_le_bytes()).collect()
}

/// Bounded on the wall clock, not on the machine: a regression here does not
/// make the test fail slowly, it makes it never return. The channel is what
/// turns "hangs" into "red".
fn run_bounded(program: &[u32], budget: u64) -> Option<(Outcome, u64)> {
    let bytes = image(program);
    let (sender, receiver) = mpsc::channel();
    thread::spawn(move || {
        let mut machine = Machine::new(DEFAULT_RAM_SIZE, Box::new(|_: &[u8]| {}));
        machine.load(&bytes, None).expect("le programme se charge");
        let outcome = machine.run(budget);
        let _ = sender.send((outcome, machine.retired_instructions()));
    });
    receiver.recv_timeout(Duration::from_secs(10)).ok()
}

#[test]
fn a_hart_parked_with_no_timer_armed_stops_instead_of_spinning() {
    let result = run_bounded(&PARKS_IMMEDIATELY, 10_000);
    let (outcome, retired) = result.expect("run doit rendre la main, pas tourner en rond");
    assert_eq!(outcome, Outcome::Stopped);
    assert_eq!(
        retired, 1,
        "une seule instruction retirée : le WFI lui-même"
    );
}

/// The same guest with no budget to exhaust, which is how the app runs it.
#[test]
fn the_same_hart_stops_even_with_no_budget_to_exhaust() {
    let (outcome, _) = run_bounded(&PARKS_IMMEDIATELY, u64::MAX).expect("run doit rendre la main");
    assert_eq!(outcome, Outcome::Stopped);
}

/// **The half that must not change.** A hart parked with a timer armed is
/// waiting for something that will arrive, and must go on waiting — a guard
/// that returned on every `WFI` would turn every idle Linux guest into a
/// stopped one.
#[test]
fn a_hart_parked_with_a_timer_armed_keeps_going() {
    let (outcome, retired) =
        run_bounded(&ARMS_A_TIMER_THEN_PARKS, 4096).expect("run doit rendre la main");
    assert_eq!(outcome, Outcome::Stopped, "le budget s'épuise normalement");
    assert!(
        retired >= 4096,
        "le minuteur a réveillé le hart, qui a dépensé tout son budget : {retired}"
    );
}
