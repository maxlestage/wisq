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
use crate::snapshot::SnapshotError;
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
        Err(crate::machine::LoadError::RamSizeUnsupported) => -6,
    }
}

/// Gives the machine a disk, seen by the guest on `/dev/vda`.
///
/// Call before loading: it is the tree that makes the device findable, and the
/// tree arrives from the caller. A tree without the node describes a machine
/// with no disk, and the guest will never probe the window.
///
/// The image is copied. The device holds it whole and writes into it — that is
/// what lets the guest's writes survive a suspension — so it cannot borrow the
/// caller's buffer.
///
/// # Safety
/// `vm` must come from `wisq_vm_new`; `image` must point at `len` readable
/// bytes.
#[no_mangle]
pub unsafe extern "C" fn wisq_vm_attach_disk(
    vm: *mut WisqVM,
    image: *const u8,
    len: usize,
) -> c_int {
    let Some(vm) = vm.as_mut() else { return -1 };
    if image.is_null() {
        return -1;
    }
    vm.machine
        .attach_disk(std::slice::from_raw_parts(image, len));
    0
}

/// Takes the disk away, and drops the interrupt line with it.
///
/// # Safety
/// `vm` must come from `wisq_vm_new`.
#[no_mangle]
pub unsafe extern "C" fn wisq_vm_detach_disk(vm: *mut WisqVM) -> c_int {
    let Some(vm) = vm.as_mut() else { return -1 };
    vm.machine.detach_disk();
    0
}

/// How many requests the disk has served, and how many it refused.
///
/// A device that refuses everything and a device nobody calls read the same
/// without both numbers — which is exactly what the app needs to tell someone
/// their kernel has no block driver.
///
/// # Safety
/// `vm` must come from `wisq_vm_new`.
#[no_mangle]
pub unsafe extern "C" fn wisq_vm_disk_served(vm: *const WisqVM) -> u64 {
    vm.as_ref().map_or(0, |vm| vm.machine.disk_served())
}

/// # Safety
/// `vm` must come from `wisq_vm_new`.
#[no_mangle]
pub unsafe extern "C" fn wisq_vm_disk_refused(vm: *const WisqVM) -> u64 {
    vm.as_ref().map_or(0, |vm| vm.machine.disk_refused())
}

/// Non-zero while a disk is attached.
///
/// # Safety
/// `vm` must come from `wisq_vm_new`.
#[no_mangle]
pub unsafe extern "C" fn wisq_vm_has_disk(vm: *const WisqVM) -> c_int {
    c_int::from(vm.as_ref().is_some_and(|vm| vm.machine.has_disk()))
}

/// Loads a kernel image with the device tree supplied by the caller.
///
/// The tree is what the firmware tells the kernel about the board, and wisq
/// runs two interpreters on the same board: one producer keeps them describing
/// the same machine, and lets the app declare a device without teaching two
/// codebases about it. `wisq_vm_load` remains for a caller with no tree.
///
/// # Safety
/// `vm` must come from `wisq_vm_new`; `image` must point at `len` readable
/// bytes; `tree` must point at `tree_len` readable bytes.
#[no_mangle]
pub unsafe extern "C" fn wisq_vm_load_with_tree(
    vm: *mut WisqVM,
    image: *const u8,
    len: usize,
    tree: *const u8,
    tree_len: usize,
) -> c_int {
    let Some(vm) = vm.as_mut() else { return -1 };
    if image.is_null() || tree.is_null() {
        return -1;
    }
    let bytes = std::slice::from_raw_parts(image, len);
    let tree = std::slice::from_raw_parts(tree, tree_len);

    match vm.machine.load_with_tree(bytes, tree) {
        Ok(()) => 0,
        Err(crate::machine::LoadError::ImageEmpty) => -3,
        Err(crate::machine::LoadError::ImageTooLarge) => -4,
        Err(crate::machine::LoadError::CommandLineTooLong) => -5,
        Err(crate::machine::LoadError::RamSizeUnsupported) => -6,
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

/// Saves the whole machine into a freshly allocated buffer.
///
/// The buffer is handed to C by leaking a boxed slice; `wisq_vm_free_snapshot`
/// is what reconstitutes and drops it. Returning an allocation rather than
/// filling a caller's buffer avoids the two-call size-then-write dance, which
/// for a 9 MB snapshot would mean building it twice.
///
/// # Safety
/// `vm` must come from `wisq_vm_new` and must not be running; `out_bytes` and
/// `out_len` must be valid for writing.
#[no_mangle]
pub unsafe extern "C" fn wisq_vm_snapshot(
    vm: *const WisqVM,
    out_bytes: *mut *mut u8,
    out_len: *mut usize,
) -> c_int {
    let (Some(vm), false, false) = (vm.as_ref(), out_bytes.is_null(), out_len.is_null()) else {
        return -1;
    };
    let mut saved = vm.machine.snapshot().into_boxed_slice();
    let (pointer, len) = (saved.as_mut_ptr(), saved.len());
    std::mem::forget(saved);
    *out_bytes = pointer;
    *out_len = len;
    0
}

/// Releases a buffer from `wisq_vm_snapshot`.
///
/// # Safety
/// `bytes` and `len` must be exactly what `wisq_vm_snapshot` produced, and the
/// buffer must not have been freed already.
#[no_mangle]
pub unsafe extern "C" fn wisq_vm_free_snapshot(bytes: *mut u8, len: usize) {
    if !bytes.is_null() {
        // `slice_from_raw_parts_mut` rather than `from_raw_parts_mut`: building
        // the fat pointer directly avoids materialising a `&mut [u8]` over memory
        // we are about to drop.
        drop(Box::from_raw(std::ptr::slice_from_raw_parts_mut(
            bytes, len,
        )));
    }
}

/// Puts a saved machine back. Returns 0, or a negative code.
///
/// # Safety
/// `vm` must come from `wisq_vm_new` and must not be running; `bytes` must
/// point at `len` readable bytes.
#[no_mangle]
pub unsafe extern "C" fn wisq_vm_restore(vm: *mut WisqVM, bytes: *const u8, len: usize) -> c_int {
    let Some(vm) = vm.as_mut() else { return -1 };
    if bytes.is_null() {
        return -1;
    }
    match vm.machine.restore(std::slice::from_raw_parts(bytes, len)) {
        Ok(()) => 0,
        Err(SnapshotError::NotASnapshot) => -2,
        Err(SnapshotError::Corrupt) => -3,
        Err(SnapshotError::RamSizeMismatch { .. }) => -4,
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
