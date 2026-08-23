//! C ABI for the iPhone and Mac apps.
//!
//! Swift owns the interface and the platform integration; this owns the
//! interpreter. The boundary is deliberately tiny — six functions and one
//! opaque pointer — because every type that crosses it is a type two languages
//! have to agree about forever.
//!
//! Threading contract, which the Swift side already satisfies: `run` blocks and
//! must be called from one thread at a time on a given machine. `send` and
//! `stop` take a separate handle and are safe from any thread.

use crate::machine::{Handle, Machine, Outcome};
use std::os::raw::{c_char, c_int, c_void};

/// Opaque to C: a machine plus the handle other threads use to reach it.
pub struct WisqVM {
    machine: Machine,
    handle: Handle,
}

/// Called with each batch of console bytes the guest writes.
pub type OutputCallback = extern "C" fn(context: *mut c_void, bytes: *const u8, len: usize);

/// A machine with `ram_size` bytes of guest RAM.
///
/// `context` is passed back to `on_output` untouched; the caller owns whatever
/// it points at and must keep it alive until `wisq_vm_free`.
///
/// # Safety
/// `on_output` must be a valid function pointer, and `context` must remain
/// valid for the lifetime of the returned machine.
#[no_mangle]
pub unsafe extern "C" fn wisq_vm_new(
    ram_size: usize,
    on_output: OutputCallback,
    context: *mut c_void,
) -> *mut WisqVM {
    // The callback context crosses into a boxed closure that Rust will move to
    // whichever thread runs the machine; the caller's contract above is what
    // makes that sound.
    let address = context as usize;
    let machine = Machine::new(
        ram_size,
        Box::new(move |bytes: &[u8]| {
            on_output(address as *mut c_void, bytes.as_ptr(), bytes.len());
        }),
    );
    let handle = machine.handle();
    Box::into_raw(Box::new(WisqVM { machine, handle }))
}

/// Loads a kernel image. Returns 0 on success, negative on failure.
///
/// `command_line` may be null. It is read as a NUL-terminated UTF-8 string.
///
/// # Safety
/// `vm` must come from `wisq_vm_new`; `image` must point at `len` readable
/// bytes; `command_line`, when non-null, must be a valid NUL-terminated string.
#[no_mangle]
pub unsafe extern "C" fn wisq_vm_load(
    vm: *mut WisqVM,
    image: *const u8,
    len: usize,
    command_line: *const c_char,
) -> c_int {
    let Some(vm) = vm.as_mut() else { return -1 };
    if image.is_null() {
        return -1;
    }
    let bytes = std::slice::from_raw_parts(image, len);

    let line = if command_line.is_null() {
        None
    } else {
        match std::ffi::CStr::from_ptr(command_line).to_str() {
            Ok(text) => Some(text),
            Err(_) => return -2,
        }
    };

    match vm.machine.load(bytes, line) {
        Ok(()) => 0,
        Err(crate::machine::LoadError::ImageEmpty) => -3,
        Err(crate::machine::LoadError::ImageTooLarge) => -4,
        Err(crate::machine::LoadError::CommandLineTooLong) => -5,
    }
}

/// Runs until shutdown, reboot, stop, or the budget is spent.
///
/// Returns 0 for power off, 1 for reboot, 2 for stopped. Blocks the calling
/// thread; that is the point, the caller owns a thread for it.
///
/// # Safety
/// `vm` must come from `wisq_vm_new` and must not be running on another thread.
#[no_mangle]
pub unsafe extern "C" fn wisq_vm_run(vm: *mut WisqVM, instruction_budget: u64) -> c_int {
    let Some(vm) = vm.as_mut() else { return -1 };
    match vm.machine.run(instruction_budget) {
        Outcome::PowerOff => 0,
        Outcome::Reboot => 1,
        Outcome::Stopped => 2,
    }
}

/// Queues keyboard bytes for the guest's UART. Safe from any thread.
///
/// # Safety
/// `vm` must come from `wisq_vm_new`; `bytes` must point at `len` readable
/// bytes.
#[no_mangle]
pub unsafe extern "C" fn wisq_vm_send(vm: *mut WisqVM, bytes: *const u8, len: usize) {
    let Some(vm) = vm.as_ref() else { return };
    if bytes.is_null() || len == 0 {
        return;
    }
    vm.handle.send(std::slice::from_raw_parts(bytes, len));
}

/// Asks a running `wisq_vm_run` to return. Safe from any thread.
///
/// # Safety
/// `vm` must come from `wisq_vm_new` and must not have been freed.
#[no_mangle]
pub unsafe extern "C" fn wisq_vm_stop(vm: *mut WisqVM) {
    if let Some(vm) = vm.as_ref() {
        vm.handle.stop();
    }
}

/// Instructions the guest has actually retired.
///
/// # Safety
/// `vm` must come from `wisq_vm_new` and must not have been freed.
#[no_mangle]
pub unsafe extern "C" fn wisq_vm_retired_instructions(vm: *const WisqVM) -> u64 {
    match vm.as_ref() {
        Some(vm) => vm.machine.retired_instructions(),
        None => 0,
    }
}

/// Frees a machine. Must not be called while `wisq_vm_run` is in progress.
///
/// # Safety
/// `vm` must come from `wisq_vm_new` and must not be used afterwards.
#[no_mangle]
pub unsafe extern "C" fn wisq_vm_free(vm: *mut WisqVM) {
    if !vm.is_null() {
        drop(Box::from_raw(vm));
    }
}
