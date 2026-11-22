//! C ABI for the iPhone and Mac apps.
//!
//! Swift owns the interface and the platform integration; this owns the
//! interpreter. The boundary stays deliberately small, because every type that
//! crosses it is a type two languages have to agree about forever: the machine
//! side is one opaque pointer, and the translator below it is none.
//!
//! Threading contract, which the Swift side already satisfies: `run` blocks and
//! must be called from one thread at a time on a given machine. `send` and
//! `stop` take a separate handle and are safe from any thread.
//!
//! At the bottom sits the x86-to-WebAssembly translator, which adds no type at
//! all: bytes in, bytes out, and four numbers. It is not a machine, and the
//! comment above it says why that distinction matters.

use crate::desktop;
use crate::machine::{Handle, Machine, Outcome};
use crate::snapshot::SnapshotError;
use crate::x86_wasm::{Module, Refused, GLOBAL_COUNT, GS_SLOT, GUEST_PAGES, RIP_SLOT};
use std::os::raw::{c_char, c_int, c_void};
use std::os::unix::ffi::OsStrExt;

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

/// Gives the machine a disk read from a file, with a durable write overlay.
///
/// `base` is opened read-only and never changes; `writes` and `writes.map`
/// are created beside it if absent and hold every sector the guest writes,
/// durably, as it writes them. Nothing of the base is copied — this is the
/// door for an installer image of several gigabytes.
///
/// Returns 0, or -1 for a null argument, -2 when the base cannot be opened,
/// -3 when it is smaller than a sector, -4 when the overlay cannot be opened,
/// -5 when the overlay belongs to another disk, -6 when the overlay is
/// truncated.
///
/// # Safety
/// `vm` must come from `wisq_vm_new`; `base` and `writes` must be
/// NUL-terminated paths.
#[no_mangle]
pub unsafe extern "C" fn wisq_vm_attach_disk_file(
    vm: *mut WisqVM,
    base: *const c_char,
    writes: *const c_char,
) -> c_int {
    let Some(vm) = vm.as_mut() else { return -1 };
    if base.is_null() || writes.is_null() {
        return -1;
    }
    let base = std::path::Path::new(std::ffi::OsStr::from_bytes(
        std::ffi::CStr::from_ptr(base).to_bytes(),
    ));
    let writes = std::path::Path::new(std::ffi::OsStr::from_bytes(
        std::ffi::CStr::from_ptr(writes).to_bytes(),
    ));
    use crate::store::StoreError;
    match vm.machine.attach_disk_file(base, writes) {
        Ok(()) => 0,
        Err(StoreError::CannotOpenBase) => -2,
        Err(StoreError::NotADisk) => -3,
        Err(StoreError::CannotOpenOverlay) => -4,
        Err(StoreError::OverlayBelongsToAnotherDisk) => -5,
        Err(StoreError::OverlayIsTruncated) => -6,
    }
}

/// Pushes what the guest wrote to its disk down to durable storage. For the
/// trip to the background; every write is already on disk before this.
///
/// # Safety
/// `vm` must come from `wisq_vm_new`.
#[no_mangle]
pub unsafe extern "C" fn wisq_vm_flush_disk(vm: *const WisqVM) -> c_int {
    let Some(vm) = vm.as_ref() else { return -1 };
    vm.machine.flush_disk();
    0
}

/// How many bytes of disk the guest has changed: the overlay's size for a
/// file-backed disk, the whole image for a memory one.
///
/// # Safety
/// `vm` must come from `wisq_vm_new`, or be null.
#[no_mangle]
pub unsafe extern "C" fn wisq_vm_disk_bytes_written(vm: *const WisqVM) -> u64 {
    vm.as_ref().map_or(0, |vm| vm.machine.disk_bytes_written())
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

/// Le temps passé hors de la machine, en microsecondes — voir
/// `Machine::elapse`. Machine arrêtée seulement.
///
/// # Safety
/// `vm` must come from `wisq_vm_new` and must not have been freed.
#[no_mangle]
pub unsafe extern "C" fn wisq_vm_elapse(vm: *mut WisqVM, micros: u64) {
    if let Some(vm) = vm.as_mut() {
        vm.machine.elapse(micros);
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

// ---------------------------------------------------------------------------
// The x86-64 to WebAssembly translator.
//
// **Why this crosses the boundary, when so little else does.** iOS gives an
// App Store app no page that is both writable and executable, so the app's x86
// core interprets — 10,6 MIPS when it was last measured, before this file
// existed, and more than an hour to boot a desktop. That figure is an origin
// point, not a fact of today: **it cannot be re-run from a Linux runner**,
// since the Swift core needs the Apple toolchain. What carries the argument is
// the order, and the order has not moved — an interpreter alone does not boot a
// desktop in a usable time. WebKit
// is the one exception: a `WKWebView` may compile WebAssembly, which is data
// rather than code. The emitter that turns a region of guest instructions into
// such a module lives in Rust, beside the interpreter it was differentially
// tested against; the machine that would use it — paging, devices, the boot
// loader, the framebuffer — lives in Swift. Without these functions Swift
// cannot reach the emitter at all, and the whole of lot 8 stops here.
//
// **What this is not.** It is not a machine. `crate::x86` is a processor and a
// decoder: no paging, no devices, no kernel loader. Handing C an "x86 VM"
// would hand it something that cannot boot anything. What crosses here is a
// pure function from bytes to bytes, plus four integers describing what the
// resulting module imports. No new type, no lifetime, no opaque pointer — the
// cheapest thing that can cross a boundary two languages must agree about
// forever.

/// Translates a region of x86-64 code into a WebAssembly module.
///
/// `base` is the **guest** address the region is loaded at, and it is not
/// decorative: `call` pushes a return address and `ret` reads it back, so a
/// region compiled as if it lived at zero would push a number nothing in guest
/// memory designates. `entry` is the offset within `code` where translation
/// starts.
///
/// **Read that order twice.** `base` and `entry` are both 64 bits wide, so a
/// caller that swaps them compiles, links and runs — and no conformance test
/// can see it, because C keeps no parameter names at link time. It is the one
/// mistake at this boundary that review has to catch rather than a program.
///
/// Returns 0 and a freshly allocated module, or -1 when the emitter refuses
/// the region — which is a normal outcome, not a defect: the caller then
/// interprets. The buffer is released by `wisq_x86_free_module`, and by
/// nothing else.
///
/// # Safety
/// `code` must be valid for reading `len` bytes, and `out_bytes` and `out_len`
/// must be valid for writing.
#[no_mangle]
pub unsafe extern "C" fn wisq_x86_emit_region(
    code: *const u8,
    len: usize,
    base: u64,
    entry: usize,
    out_bytes: *mut *mut u8,
    out_len: *mut usize,
) -> c_int {
    if code.is_null() || out_bytes.is_null() || out_len.is_null() {
        return -1;
    }
    let region = std::slice::from_raw_parts(code, len);
    let Some(module) = Module::region(region, base, entry) else {
        return -1;
    };
    hand_back(module, out_bytes, out_len);
    0
}

/// **La forme que le bureau local a vraiment besoin de traduire.**
///
/// `wisq_x86_emit_region` rend la forme historique : une région seule, qui
/// rend la main dès qu'elle sort d'elle-même. Celle-ci est **liée** — ses blocs
/// se posent dans la table commune de l'hôte, à partir de `slot` — et
/// **confinée** : les adresses de l'invité sont repliées dans `pages` pages de
/// 64 Kio, ce qui met la correspondance adresse → indice juste au-dessus, hors
/// de sa portée. Le module la lit lui-même, et passe d'une région à l'autre
/// sans repasser par l'application.
///
/// `pages` doit être une **puissance de deux** : le repli se fait par un
/// masque, qui ne décrit un intervalle qu'à cette condition. Sinon, refus —
/// comme pour une région que l'émetteur ne sait pas traduire.
///
/// L'hôte doit fournir une mémoire d'au moins `pages + wisq_desktop_table_pages()`
/// `+ wisq_desktop_tlb_pages() + wisq_desktop_code_pages(pages)`
/// pages, et une table d'au moins `slot` plus les blocs de la région. Un module
/// à qui il en manque **ne démarre pas**, ce qui est bruyant ; s'il démarrait,
/// il piégerait au premier saut, et un piège WebAssembly est sans retour.
///
/// # Safety
/// `code` must be valid for reading `len` bytes, and `out_bytes` and `out_len`
/// must be valid for writing.
#[no_mangle]
pub unsafe extern "C" fn wisq_x86_emit_resolving(
    code: *const u8,
    len: usize,
    base: u64,
    entry: usize,
    slot: u32,
    pages: u32,
    out_bytes: *mut *mut u8,
    out_len: *mut usize,
) -> c_int {
    if code.is_null() || out_bytes.is_null() || out_len.is_null() {
        return -1;
    }
    let region = std::slice::from_raw_parts(code, len);
    match Module::resolving_or_why(region, base, entry, slot, pages) {
        Ok(module) => {
            hand_back(module, out_bytes, out_len);
            0
        }
        // **Le seul refus qui ne soit pas définitif.** La première instruction
        // de la fenêtre s'est arrêtée à moins de quinze octets du bord, et rien
        // de complet ne la précède : elle a pu être coupée. L'appelant
        // redemande alors la même région avec une fenêtre plus large, et **une
        // seule fois**. Une coupe plus loin n'arrive pas ici : la région se
        // traduit jusqu'à elle.
        Err(Refused::MayBeCut { .. }) => -2,
        Err(_) => -1,
    }
}

/// **La page que l'application charge dans sa vue.**
///
/// Elle porte la boucle hôte, le pont vers l'application et l'état de départ
/// de la machine. `channel` nomme le gestionnaire de messages que
/// l'application déclare ; il est **recollé dans du JavaScript**, donc seules
/// les lettres et les chiffres sont acceptés — la même précaution que pour un
/// identifiant de VM recollé dans une ligne de commande.
///
/// **Le cadre est facultatif, et `screen_width == 0` le dit.** Une machine sans
/// écran est un cas réel — un démarrage jugé sur ses registres n'a rien à
/// montrer — et un cadre qui déborderait de la RAM de l'invité est refusé ici,
/// parce qu'au-dessus vit la correspondance : il afficherait la table des blocs
/// tout en la détruisant.
///
/// Rend 0 et la page en UTF-8, ou -1 si la RAM n'est pas une puissance de deux,
/// si le nom du canal ne peut pas être recollé sans danger, ou si le cadre ne
/// tient pas. Le tampon se libère par `wisq_x86_free_module`, comme un module :
/// c'est la même allocation, et une seconde fonction identique ne serait que du
/// bruit.
///
/// # Safety
/// `channel` must be a NUL-terminated C string, and `out_bytes` and `out_len`
/// must be valid for writing.
#[no_mangle]
pub unsafe extern "C" fn wisq_desktop_page(
    pages: u32,
    entry: u64,
    channel: *const c_char,
    screen_base: u64,
    screen_width: u32,
    screen_height: u32,
    // **Où l'application a posé la page zéro, ou zéro quand elle n'en a pas.**
    // Un noyau entré sans `boot_params` s'arrête muet dans `extend_brk` ; un
    // programme jugé sur ses registres, lui, n'en a pas et n'en veut pas.
    boot_at: u64,
    out_bytes: *mut *mut u8,
    out_len: *mut usize,
) -> c_int {
    if channel.is_null() || out_bytes.is_null() || out_len.is_null() {
        return -1;
    }
    let Ok(name) = std::ffi::CStr::from_ptr(channel).to_str() else {
        return -1;
    };
    let screen = if screen_width == 0 && screen_height == 0 {
        None
    } else {
        Some(desktop::Screen {
            base: screen_base,
            width: screen_width,
            height: screen_height,
        })
    };
    let boot = if boot_at == 0 { None } else { Some(boot_at) };
    let Ok(page) = desktop::page(pages, entry, name, screen, boot) else {
        return -1;
    };
    hand_back(page.into_bytes(), out_bytes, out_len);
    0
}

/// **La page zéro que le bureau tend au noyau, ligne de commande comprise.**
///
/// Un noyau x86-64 entré sans `boot_params` n'a pas de carte e820 : il s'arrête
/// muet dans `extend_brk` à sa 1067ᵉ région. L'application pose ces quatre
/// kibioctets à `wisq_desktop_boot_page_at()` et passe cette adresse à
/// `wisq_desktop_page` comme `boot_at` ; le pilote met alors RSI dessus.
///
/// `command_line` peut être nul : la ligne mesurée par défaut est employée.
/// Rend 0 et quatre kibioctets, ou -1 si la RAM n'est pas une puissance de deux
/// ou si la ligne ne tient pas dans la page. Le tampon se libère par
/// `wisq_x86_free_module`.
///
/// # Safety
/// `command_line`, when non-null, must be a valid NUL-terminated string, and
/// `out_bytes` and `out_len` must be valid for writing.
#[no_mangle]
pub unsafe extern "C" fn wisq_desktop_boot_page(
    pages: u32,
    command_line: *const c_char,
    // **L'écran, et `screen_width == 0 && screen_height == 0` dit qu'il n'y en
    // a pas.** Un bureau qui en déclare un doit le dire au noyau *et* réserver
    // le cadre dans la carte e820 : sans l'entrée, l'allocateur distribue ces
    // pages, et le bureau se corrompt sous des causes sans rapport.
    screen_base: u64,
    screen_width: u32,
    screen_height: u32,
    out_bytes: *mut *mut u8,
    out_len: *mut usize,
) -> c_int {
    if out_bytes.is_null() || out_len.is_null() {
        return -1;
    }
    let line = if command_line.is_null() {
        desktop::COMMAND_LINE
    } else {
        match std::ffi::CStr::from_ptr(command_line).to_str() {
            Ok(text) => text,
            Err(_) => return -1,
        }
    };
    let screen = if screen_width == 0 && screen_height == 0 {
        None
    } else {
        Some(desktop::Screen {
            base: screen_base,
            width: screen_width,
            height: screen_height,
        })
    };
    let Ok(page) = desktop::boot_page_with_screen(pages, line, screen) else {
        return -1;
    };
    hand_back(page, out_bytes, out_len);
    0
}

/// Où la page zéro du bureau doit être posée dans la RAM de l'invité.
///
/// Écrit ici plutôt que du côté de l'application : le pilote y met RSI, et deux
/// copies du nombre divergeraient en silence.
#[no_mangle]
pub extern "C" fn wisq_desktop_boot_page_at() -> u64 {
    crate::kernel_image::ZERO_PAGE_AT
}

/// **Un fichier de la page de la machine de l'émetteur, par son nom** :
/// `host.js`, `carte.js`, `page-emitter.js`, `machine.js`, `machine.html`, et
/// `wisq_page.wasm` quand la construction l'a embarqué. Rend 0 et des octets
/// **statiques** — ils vivent autant que la bibliothèque, et ne se libèrent
/// pas —, ou -1 pour un nom inconnu ou un module absent.
///
/// # Safety
/// `name` must be a NUL-terminated C string, and `out_bytes` and `out_len`
/// must be valid for writing.
#[no_mangle]
pub unsafe extern "C" fn wisq_emitter_asset(
    name: *const c_char,
    out_bytes: *mut *const u8,
    out_len: *mut usize,
) -> c_int {
    if name.is_null() || out_bytes.is_null() || out_len.is_null() {
        return -1;
    }
    let Ok(name) = std::ffi::CStr::from_ptr(name).to_str() else {
        return -1;
    };
    let Some(bytes) = crate::emitter_machine::asset(name) else {
        return -1;
    };
    *out_bytes = bytes.as_ptr();
    *out_len = bytes.len();
    0
}

/// **La page zéro de la machine de l'émetteur** : la ligne du montage suivie
/// de `extra` (nul : rien de plus) telle quelle — voir
/// `emitter_machine::command_line` —, l'écran de la carte (`width == 0 &&
/// height == 0` : aucun), l'archive (`initramfs_bytes == 0` : aucune) posée
/// au-dessus de `floor`. Rend 0 et quatre kibioctets (à libérer par
/// `wisq_x86_free_module`), ou un refus nommé : 1 la RAM, 2 la ligne, 3
/// l'écran, 4 l'archive, -1 des arguments illisibles.
///
/// **Au refus 2, `out_len` reçoit la longueur de la ligne entière**, celle
/// du montage comprise : c'est elle que la borne de 2 047 octets juge, et
/// l'appelant ne la connaît pas — la part du montage dépend de la ligne de
/// l'image (`keep_bootcon` peut en partir). Sans ce nombre, la phrase de
/// l'écran ne pouvait parler que de la ligne de l'image, et mentait pour
/// toute ligne d'image de 2 008 à 2 047 octets.
///
/// # Safety
/// `extra`, when non-null, must be a NUL-terminated C string, and `out_bytes`
/// and `out_len` must be valid for writing.
#[no_mangle]
#[allow(clippy::too_many_arguments)]
pub unsafe extern "C" fn wisq_emitter_boot_page(
    pages: u32,
    extra: *const c_char,
    screen_width: u32,
    screen_height: u32,
    initramfs_at: u64,
    initramfs_bytes: u64,
    floor: u64,
    out_bytes: *mut *mut u8,
    out_len: *mut usize,
) -> c_int {
    use crate::emitter_machine::{boot_page, Refusal};
    if out_bytes.is_null() || out_len.is_null() {
        return -1;
    }
    let extra = if extra.is_null() {
        None
    } else {
        match std::ffi::CStr::from_ptr(extra).to_str() {
            Ok(text) => Some(text),
            Err(_) => return -1,
        }
    };
    let screen = if screen_width == 0 && screen_height == 0 {
        None
    } else {
        Some((screen_width, screen_height))
    };
    let initramfs = (initramfs_bytes != 0).then_some(crate::kernel_image::Ramdisk {
        at: initramfs_at,
        bytes: initramfs_bytes,
    });
    match boot_page(pages, extra, screen, initramfs, floor) {
        Ok(page) => {
            hand_back(page, out_bytes, out_len);
            0
        }
        Err(Refusal::RamIsNotAPowerOfTwo(_)) => 1,
        Err(Refusal::CommandLine(why)) => {
            *out_len = match why {
                crate::kernel_image::CommandLineRefusal::TooLong { bytes, .. } => bytes,
                _ => 0,
            };
            2
        }
        Err(Refusal::Screen(_)) => 3,
        Err(Refusal::Ramdisk(_)) => 4,
    }
}

/// **Cette RAM peut-elle porter ce noyau, sous l'émetteur ?** `entry` est le
/// point d'entrée physique de l'ELF, `top` le sommet de ses segments, BSS
/// compris. Rend 0, ou 1 aucune RAM, 2 pas une puissance de deux, 3 trop
/// petite, 4 le repli amène le texte virtuel ailleurs que sur lui-même —
/// `out_folded`, quand il n'est pas nul, reçoit alors où.
///
/// # Safety
/// `out_folded`, when non-null, must be valid for writing.
#[no_mangle]
pub unsafe extern "C" fn wisq_emitter_usable_ram(
    pages: u32,
    entry: u64,
    top: u64,
    out_folded: *mut u64,
) -> c_int {
    use crate::x86_wasm::RamRefusal;
    match crate::emitter_machine::usable(pages, entry, top) {
        Ok(()) => 0,
        Err(RamRefusal::Empty) => 1,
        Err(RamRefusal::NotAPowerOfTwo) => 2,
        Err(RamRefusal::TooSmall { .. }) => 3,
        Err(RamRefusal::FoldMisses { folded }) => {
            if !out_folded.is_null() {
                *out_folded = folded;
            }
            4
        }
    }
}

/// Où l'invité voit la mémoire vidéo de la carte, telle que la page zéro de
/// la machine de l'émetteur l'annonce.
#[no_mangle]
pub extern "C" fn wisq_emitter_screen_base() -> u64 {
    crate::emitter_machine::SCREEN_BASE
}

/// **Ce que l'application n'a pas le droit d'écrire dans la RAM de l'invité.**
///
/// Elle pose ses images par un seul chemin ; celui-ci dit, avant la première
/// écriture, si l'image tient et si elle laisse en paix les deux régions que la
/// machine se donne à elle-même : la page zéro que le noyau lit avant sa
/// première instruction, et le cadre que la vue repeint à chaque image.
///
/// `boots` dit si la page zéro existe : un programme jugé sur ses registres
/// n'en a pas, et lui interdire cette adresse serait un refus sans objet. Le
/// cadre est optionnel de la même façon que partout ailleurs ici —
/// `screen_width == 0 && screen_height == 0` dit qu'il n'y en a pas.
///
/// **Le verdict est un code, pas un booléen**, parce que l'appelant en dit
/// quelque chose à l'utilisateur : « l'image déborde » et « l'image tombe sur
/// la page zéro » ne se corrigent pas pareil. Les quatre nombres sont fixés par
/// l'en-tête et vérifiés depuis C :
///
/// - `0` : posable ;
/// - `1` : la RAM n'est pas une puissance de deux ;
/// - `2` : l'image déborde de la RAM ;
/// - `3` : elle écraserait la page zéro ;
/// - `4` : elle tombe dans le cadre ;
/// - `5` : elle tombe dans l'archive initramfs.
#[no_mangle]
pub extern "C" fn wisq_desktop_placement(
    pages: u32,
    screen_base: u64,
    screen_width: u32,
    screen_height: u32,
    // **L'archive, et `initramfs_bytes == 0` dit qu'il n'y en a pas.** C'est la
    // troisième région que la machine se donne à elle-même : le noyau la
    // déballe pour s'en faire une racine, et une image posée dessus la lui
    // donnerait corrompue.
    initramfs_at: u64,
    initramfs_bytes: u64,
    boots: c_int,
    at: u64,
    bytes: u64,
) -> c_int {
    let screen = if screen_width == 0 && screen_height == 0 {
        None
    } else {
        Some(desktop::Screen {
            base: screen_base,
            width: screen_width,
            height: screen_height,
        })
    };
    let initramfs = if initramfs_bytes == 0 {
        None
    } else {
        Some(crate::kernel_image::Ramdisk {
            at: initramfs_at,
            bytes: initramfs_bytes,
        })
    };
    match desktop::placement(pages, screen, initramfs, boots != 0, at, bytes) {
        Ok(()) => 0,
        Err(desktop::Refusal::RamIsNotAPowerOfTwo(_)) => 1,
        Err(desktop::Refusal::ImageDoesNotFit { .. }) => 2,
        Err(desktop::Refusal::ImageWouldOverwriteTheBootPage { .. }) => 3,
        Err(desktop::Refusal::ImageWouldOverwriteTheFrame { .. }) => 4,
        Err(desktop::Refusal::ImageWouldOverwriteTheArchive { .. }) => 5,
        // **Les autres refus ne peuvent pas venir d'ici**, et le dire par un
        // code à part vaut mieux que les ranger sous l'un des cinq : un
        // appelant qui verrait « déborde de la RAM » pour un nom de canal
        // chercherait au mauvais endroit.
        Err(_) => -1,
    }
}

/// **Dire au noyau du bureau où est sa racine.**
///
/// Sans les deux champs que cette fonction écrit — `ramdisk_image` à `0x218`,
/// `ramdisk_size` à `0x21c` — le noyau traverse tous ses `initcall`, arrive
/// dans `prepare_namespace`, et meurt sur « VFS: Unable to mount root fs on
/// unknown-block(0,0) ». L'application pose les octets de l'archive elle-même ;
/// ceci ne fait que les déclarer.
///
/// **La page est modifiée sur place, et pas rebâtie** : un chemin qui repartirait
/// de zéro perdrait la ligne de commande et la carte e820 que
/// `wisq_desktop_boot_page` y a mises.
///
/// Les deux bornes sont calculées ici : le sommet de la page zéro au-dessous, la
/// base du cadre (ou le bout de la RAM) au-dessus.
///
/// - `0` : déclarée ;
/// - `1` : la RAM n'est pas une puissance de deux ;
/// - `2` : une archive de zéro octet n'est pas une racine ;
/// - `3` : elle n'est pas là où le noyau pourrait la lire ;
/// - `-1` : la page est nulle ou plus courte que quatre kibioctets.
///
/// # Safety
/// `page` must be valid for reading and writing `page_len` bytes.
#[no_mangle]
pub unsafe extern "C" fn wisq_desktop_declare_initramfs(
    page: *mut u8,
    page_len: usize,
    pages: u32,
    screen_base: u64,
    screen_width: u32,
    screen_height: u32,
    at: u64,
    bytes: u64,
) -> c_int {
    if page.is_null() || page_len < 4096 {
        return -1;
    }
    let screen = if screen_width == 0 && screen_height == 0 {
        None
    } else {
        Some(desktop::Screen {
            base: screen_base,
            width: screen_width,
            height: screen_height,
        })
    };
    let page = std::slice::from_raw_parts_mut(page, page_len);
    match desktop::declare_initramfs(
        page,
        pages,
        screen,
        crate::kernel_image::Ramdisk { at, bytes },
    ) {
        Ok(()) => 0,
        Err(desktop::Refusal::RamIsNotAPowerOfTwo(_)) => 1,
        Err(desktop::Refusal::InitramfsHasNoBytes) => 2,
        Err(desktop::Refusal::InitramfsDoesNotFit { .. }) => 3,
        // Aucun autre refus ne peut venir d'ici ; le ranger sous l'un des trois
        // enverrait l'appelant chercher au mauvais endroit.
        Err(_) => -1,
    }
}

/// **Un segment `PT_LOAD`, tel que C le voit.**
///
/// Les cinq nombres sont ceux de `kernel_image::Load`, dans le même ordre, et
/// `repr(C)` le rend lisible de l'autre côté. Recopier la structure plutôt que
/// la partager serait deux copies à garder d'accord ; ne pas la recopier du
/// tout obligerait l'appelant à cinq appels par segment.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct WisqKernelLoad {
    pub offset: u64,
    pub virtual_address: u64,
    pub physical_address: u64,
    pub file_size: u64,
    pub memory_size: u64,
}

/// **Le point d'entrée et les segments chargeables d'un noyau ELF64.**
///
/// Sans ça l'application ne peut pas démarrer un vrai noyau : elle n'a aucun
/// moyen d'apprendre où poser l'image ni par où l'exécution commence, et les
/// deux — l'`entry` de `wisq_desktop_page` et les adresses auxquelles elle
/// pose — viennent d'ici. `kernel_image::loads` lit des ELF depuis #304 et le
/// montage de mesure s'en sert ; **le bureau ne pouvait pas**, parce que rien
/// ne l'exposait. C'est la même famille que #310, #311 et #313.
///
/// **Le lecteur n'est pas réécrit ici.** C'est `kernel_image::loads`, celui que
/// le montage emploie et que ses propres tests tiennent. En écrire un second
/// serait #289 par construction — et la distinction qui coûte cher, les deux
/// tailles d'un segment, est déjà prise là-bas.
///
/// **On demande deux fois** : une fois avec `capacity == 0` pour apprendre le
/// compte, puis avec un tableau de cette taille. Le premier appel n'est pas
/// perdu — l'entrée et le compte sont posés quand même.
///
/// - `0` : lu, et les `out_count` segments ont été écrits ;
/// - `1` : ce n'est pas un ELF64 que ce lecteur accepte, ou un pointeur nul ;
/// - `2` : lu, mais `capacity` était trop petit — rien n'a été écrit.
///
/// # Safety
/// `image` must be valid for reading `len` bytes, `out_entry` and `out_count`
/// valid for writing, and `out_loads`, when non-null, valid for writing
/// `capacity` elements.
#[no_mangle]
pub unsafe extern "C" fn wisq_kernel_loads(
    image: *const u8,
    len: usize,
    out_entry: *mut u64,
    out_loads: *mut WisqKernelLoad,
    capacity: usize,
    out_count: *mut usize,
) -> c_int {
    if image.is_null() || out_entry.is_null() || out_count.is_null() {
        return 1;
    }
    let bytes = std::slice::from_raw_parts(image, len);
    let Some((entry, segments)) = crate::kernel_image::loads(bytes) else {
        return 1;
    };
    // **L'entrée et le compte sont posés avant la question de la place.** C'est
    // ce qui rend le premier appel utile : l'appelant alloue en sachant, au
    // lieu de deviner puis réessayer.
    *out_entry = entry;
    *out_count = segments.len();
    if out_loads.is_null() || capacity < segments.len() {
        return 2;
    }
    for (index, segment) in segments.iter().enumerate() {
        *out_loads.add(index) = WisqKernelLoad {
            offset: segment.offset,
            virtual_address: segment.virtual_address,
            physical_address: segment.physical_address,
            file_size: segment.file_size,
            memory_size: segment.memory_size,
        };
    }
    0
}

/// Ce que la correspondance occupe **au-dessus** de la RAM de l'invité, en
/// pages. L'hôte doit l'ajouter à la taille de la mémoire qu'il crée.
#[no_mangle]
pub extern "C" fn wisq_desktop_table_pages() -> u32 {
    crate::x86_wasm::TABLE_PAGES
}

/// Ce que le **tampon de traduction** occupe, encore au-dessus de la
/// correspondance. À ajouter lui aussi : un module confiné le déclare dans son
/// minimum, et un hôte qui ne l'a pas posé ne démarre pas.
#[no_mangle]
pub extern "C" fn wisq_desktop_tlb_pages() -> u32 {
    crate::x86_wasm::TLB_PAGES
}

/// Ce que la **carte du code traduit** et son journal occupent, encore
/// au-dessus du tampon, pour une RAM de `pages` pages : un bit par ligne de
/// soixante-quatre octets, donc une taille qui suit celle de la RAM. À
/// ajouter aussi ; un module confiné le déclare dans son minimum.
#[no_mangle]
pub extern "C" fn wisq_desktop_code_pages(pages: u32) -> u32 {
    crate::x86_wasm::code_pages(pages)
}

/// Céder un tampon à l'appelant, à charge pour lui de le rendre par
/// `wisq_x86_free_module`. Les trois fonctions qui rendent des octets au
/// traducteur passent par ici — trois copies de la même cession finiraient par
/// ne plus se ressembler.
///
/// L'instantané de machine, lui, garde la sienne : il se libère par
/// `wisq_vm_free_snapshot`, et deux durées de vie différentes qui partagent un
/// chemin sont une invitation à se tromper de fonction de libération.
///
/// # Safety
/// `out_bytes` and `out_len` must be valid for writing.
unsafe fn hand_back(bytes: Vec<u8>, out_bytes: *mut *mut u8, out_len: *mut usize) {
    let mut bytes = bytes.into_boxed_slice();
    let (pointer, len) = (bytes.as_mut_ptr(), bytes.len());
    std::mem::forget(bytes);
    *out_bytes = pointer;
    *out_len = len;
}

/// Releases a module from `wisq_x86_emit_region`.
///
/// The null check is deliberate and **no test in this repository can observe
/// it**: `Box::from_raw` on a null pointer is undefined behaviour even for a
/// zero-length slice, but nothing crashes, so removing the guard leaves every
/// test green. It stays for the same reason `wisq_vm_free_snapshot` has one —
/// a caller that cannot tell whether the emitter refused should be able to
/// free unconditionally.
///
/// # Safety
/// `bytes` and `len` must be exactly what `wisq_x86_emit_region` produced, and
/// the buffer must not have been freed already.
#[no_mangle]
pub unsafe extern "C" fn wisq_x86_free_module(bytes: *mut u8, len: usize) {
    if !bytes.is_null() {
        drop(Box::from_raw(std::ptr::slice_from_raw_parts_mut(
            bytes, len,
        )));
    }
}

/// Pages of guest RAM the module imports. The host creates the memory.
///
/// These four are functions rather than constants in the header for one
/// reason: a header carries no arithmetic, so a literal there would be a
/// second declaration of a number the emitter already owns — and a module that
/// imports twenty-nine globals, instantiated with twenty-eight, does not run
/// at all.
#[no_mangle]
pub extern "C" fn wisq_x86_guest_pages() -> u32 {
    GUEST_PAGES
}

/// Mutable `i64` globals the module imports, named `g0`..`g<count-1>` in the
/// `env` namespace: the sixteen registers, RFLAGS, RIP, the GS base, then the
/// translator's scratch.
#[no_mangle]
pub extern "C" fn wisq_x86_global_count() -> usize {
    GLOBAL_COUNT
}

/// Where execution stopped. A region does not run to the end of the program:
/// it hands back when a jump leaves what it knows, or when the budget is
/// spent. Without this the host would know it stopped but not where to resume.
#[no_mangle]
pub extern "C" fn wisq_x86_rip_slot() -> usize {
    RIP_SLOT
}

/// The GS segment base, which the host sets and the module reads. A kernel
/// installs it once per core, very early — but "very early" is already after
/// the first region was translated, so it cannot be frozen into the code.
#[no_mangle]
pub extern "C" fn wisq_x86_gs_slot() -> usize {
    GS_SLOT
}

// **Pourquoi lire une image de disque optique traverse la frontière.**
//
// Quelqu'un arrive avec une image d'installation et veut la faire tourner. Le
// noyau est dedans, sous `/boot`, avec son initramfs et la recette qui dit
// comment les démarrer. Le lecteur vit en Rust, à côté du reconnaisseur de
// noyaux qui juge ce qu'on en sort ; l'application, la bibliothèque et le
// chargeur vivent en Swift. Sans ces deux fonctions, l'application ne peut que
// refuser.
//
// **Ce qui ne traverse pas** : l'image elle-même. Elle pèse des gibioctets,
// et un téléphone n'en a pas. Ce qui passe ici, ce sont deux chemins et un
// verdict.

/// La recette de démarrage d'une image, ou -1.
///
/// Le tampon rendu porte **quatre chaînes**, terminées chacune par un octet
/// nul, dans cet ordre : le fichier d'où la recette vient, le chemin du noyau,
/// celui de l'initramfs, la ligne de commande. L'initramfs peut être vide —
/// une recette n'en cite pas toujours — les trois autres ne le sont jamais
/// quand la fonction rend zéro.
///
/// **Quatre chaînes nulles plutôt qu'un format à séparateur.** Une ligne de
/// commande porte des espaces, des égales et des virgules ; un chemin porte
/// tout sauf l'octet nul. C'est le seul séparateur qu'aucun des deux ne peut
/// contenir, donc le seul qui n'ait pas besoin d'échappement — et un
/// échappement, des deux côtés d'une frontière, est une convention de plus à
/// tenir pour toujours.
///
/// Le tampon est rendu par `wisq_x86_free_module`, et par rien d'autre.
///
/// # Safety
/// `path` must be a NUL-terminated C string, and `out_bytes` and `out_len`
/// must be valid for writing.
#[no_mangle]
pub unsafe extern "C" fn wisq_iso_recipe(
    path: *const c_char,
    out_bytes: *mut *mut u8,
    out_len: *mut usize,
) -> c_int {
    if path.is_null() || out_bytes.is_null() || out_len.is_null() {
        return -1;
    }
    let Some(path) = borrowed_path(path) else {
        return -1;
    };
    let Some(source) = crate::iso9660::OnDisk::open(&path) else {
        return -1;
    };
    let Some(iso) = crate::iso9660::Iso::open(source) else {
        return -1;
    };
    let Some(recipe) = crate::iso9660::Recipe::of(&iso) else {
        return -1;
    };
    let mut out = Vec::new();
    for field in [
        recipe.from.as_str(),
        recipe.kernel.as_str(),
        recipe.initrd.as_deref().unwrap_or(""),
        recipe.command_line.as_str(),
    ] {
        // Un champ qui porterait un octet nul casserait le découpage côté
        // Swift ; aucun n'en porte, puisqu'ils viennent d'un `str`, mais le
        // dire ici évite qu'un champ futur l'introduise en silence.
        debug_assert!(!field.as_bytes().contains(&0));
        out.extend_from_slice(field.as_bytes());
        out.push(0);
    }
    hand_back(out, out_bytes, out_len);
    0
}

/// Écrit un membre de l'image dans un fichier. Rend 0, ou -1.
///
/// `ceiling` est ce que l'appelant accepte d'écrire. Au-delà, refus **avant**
/// d'avoir écrit quoi que ce soit : un noyau à moitié extrait se charge, et
/// meurt dans une instruction qui n'a rien à voir.
///
/// Le contenu passe par tranches de soixante-quatre kibioctets. Rien de
/// l'image n'est tenu en entier, ni ici ni chez l'appelant.
///
/// **Si la copie échoue en chemin, le fichier de destination est laissé
/// incomplet** et cette fonction rend -1 : c'est à l'appelant de l'effacer.
/// L'effacer ici demanderait de décider à sa place ce qu'il advient d'un
/// fichier qu'il a nommé.
///
/// # Safety
/// `path`, `inside` and `into` must be NUL-terminated C strings.
#[no_mangle]
pub unsafe extern "C" fn wisq_iso_extract(
    path: *const c_char,
    inside: *const c_char,
    into: *const c_char,
    ceiling: u64,
) -> c_int {
    if path.is_null() || inside.is_null() || into.is_null() {
        return -1;
    }
    let (Some(path), Some(inside), Some(into)) = (
        borrowed_path(path),
        borrowed_str(inside),
        borrowed_path(into),
    ) else {
        return -1;
    };
    let Some(source) = crate::iso9660::OnDisk::open(&path) else {
        return -1;
    };
    let Some(iso) = crate::iso9660::Iso::open(source) else {
        return -1;
    };
    let Some(entry) = iso.find(&inside) else {
        return -1;
    };
    if u64::from(entry.size) > ceiling {
        return -1;
    }
    let Ok(file) = std::fs::File::create(&into) else {
        return -1;
    };
    let mut sink = std::io::BufWriter::new(file);
    if !iso.copy(&entry, &mut sink, ceiling) {
        return -1;
    }
    // **Le vidage du tampon est une écriture comme une autre**, et la dernière.
    // Sans ce contrôle, un disque plein rendrait zéro sur un fichier tronqué.
    use std::io::Write;
    if sink.flush().is_err() {
        return -1;
    }
    0
}

/// Un chemin emprunté à C. Rend `None` sur des octets qui ne sont pas de
/// l'UTF-8 : le reste de ce code travaille en `str`, et un chemin qu'on ne
/// sait pas nommer ne se retrouvera de toute façon pas dans l'image.
unsafe fn borrowed_str(text: *const c_char) -> Option<String> {
    std::ffi::CStr::from_ptr(text)
        .to_str()
        .ok()
        .map(str::to_string)
}

unsafe fn borrowed_path(text: *const c_char) -> Option<std::path::PathBuf> {
    borrowed_str(text).map(std::path::PathBuf::from)
}

// ---------------------------------------------------------------------------
// La machine PC native (`pc::Poste`).
//
// **Le même contrat de fils que la machine RISC-V**, écrit fonction par
// fonction dans l'en-tête : `wisq_pc_run` bloque, et ce qui touche la machine
// elle-même (charger, brancher, courir, sauver, reprendre, lire le compteur)
// se fait d'un seul fil à la fois, course arrêtée. Arrêter, taper, toucher,
// lire l'écran et l'avancement se font de n'importe quel fil, pendant la
// course : ces fonctions-là ne passent que par `commandes`, un champ à part,
// atteint par `addr_of!` — elles ne forment jamais de référence sur le poste
// qu'un autre fil tient en `&mut`.
//
// **Aucune panique ne traverse la frontière.** Chaque fonction vérifie ses
// arguments et rend un code ; ce qui reste d'imprévu passe par `garder`, qui
// rend le code `WISQ_PC_PANIC` dans une construction qui déroule (les tests).
// La bibliothèque de l'application est construite avec `panic = "abort"` :
// une panique y arrête le processus, sans jamais dérouler dans l'appelant C.

use crate::pc::instantane::{self, RefusDInstantane};
use crate::pc::poste::{frappes_du_jeu_1, Commandes, Fin, Poste, RefusDeBranchement, VueDeLEcran};
use std::sync::Arc;
use wisq_carte::fichier::{DisqueFichier, Lecteur, Refus as RefusDuDisque};
use wisq_carte::pc::{horloge_du_systeme, ArriereMemoire, Disque};

/// Opaque à C : le poste, et ses commandes pour les autres fils.
pub struct WisqPC {
    /// Touché par le seul fil de la course.
    poste: Poste,
    /// Touché de n'importe quel fil.
    commandes: Arc<Commandes>,
    sortie: Option<OutputCallback>,
    contexte: usize,
    /// Le nom de la dernière faute de `wisq_pc_run`.
    faute: String,
}

/// L'écran, tel que C le lit (`WisqPCDisplay`).
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct WisqPCDisplay {
    pub memory: *const u8,
    pub memory_size: usize,
    pub width: u32,
    pub height: u32,
    pub bytes_per_row: u32,
    pub reserved: u32,
    pub start: u64,
    pub revision: u64,
}

impl From<VueDeLEcran> for WisqPCDisplay {
    fn from(vue: VueDeLEcran) -> Self {
        Self {
            memory: vue.memoire,
            memory_size: vue.taille,
            width: vue.largeur,
            height: vue.hauteur,
            bytes_per_row: vue.octets_par_ligne,
            reserved: 0,
            start: vue.debut,
            revision: vue.revision,
        }
    }
}

/// Ce que rend une fonction quand une panique a été rattrapée.
const WISQ_PC_PANIC: c_int = -99;

/// Le filet : une panique devient `defaut` là où elle se rattrape.
fn garder<R>(defaut: R, travail: impl FnOnce() -> R) -> R {
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(travail)).unwrap_or(defaut)
}

/// Le poste, pour le fil de la course.
unsafe fn poste<'a>(pc: *mut WisqPC) -> Option<&'a mut Poste> {
    if pc.is_null() {
        return None;
    }
    Some(&mut *std::ptr::addr_of_mut!((*pc).poste))
}

/// Le poste en lecture, pour le fil de la course.
unsafe fn poste_lu<'a>(pc: *const WisqPC) -> Option<&'a Poste> {
    if pc.is_null() {
        return None;
    }
    Some(&*std::ptr::addr_of!((*pc).poste))
}

/// Les commandes, pour n'importe quel fil.
unsafe fn commandes<'a>(pc: *const WisqPC) -> Option<&'a Commandes> {
    if pc.is_null() {
        return None;
    }
    Some(&**std::ptr::addr_of!((*pc).commandes))
}

/// Un chemin C, en chemin.
unsafe fn chemin<'a>(texte: *const c_char) -> &'a std::path::Path {
    std::path::Path::new(std::ffi::OsStr::from_bytes(
        std::ffi::CStr::from_ptr(texte).to_bytes(),
    ))
}

/// # Safety
/// `context` est rendu tel quel à `on_output` (qui peut être nul : la console
/// est alors jetée) ; l'appelant le garde en vie jusqu'à `wisq_pc_free`.
#[no_mangle]
pub unsafe extern "C" fn wisq_pc_new(
    ram_bytes: u64,
    on_output: Option<OutputCallback>,
    context: *mut c_void,
) -> *mut WisqPC {
    garder(std::ptr::null_mut(), || {
        let Some(mut poste) = Poste::essayer(ram_bytes) else {
            return std::ptr::null_mut();
        };
        poste.horloge(horloge_du_systeme);
        let maintenant = horloge_du_systeme().max(0) as u64 / 1000;
        poste.machine.herites.cmos.regler(maintenant);
        let commandes = poste.commandes().clone();
        Box::into_raw(Box::new(WisqPC {
            poste,
            commandes,
            sortie: on_output,
            contexte: context as usize,
            faute: String::new(),
        }))
    })
}

/// # Safety
/// `pc` vient de `wisq_pc_new`, course arrêtée.
#[no_mangle]
pub unsafe extern "C" fn wisq_pc_set_time(pc: *mut WisqPC, unix_seconds: i64) -> c_int {
    let Some(poste) = poste(pc) else { return -1 };
    garder(WISQ_PC_PANIC, || {
        poste.regler_l_heure(unix_seconds);
        0
    })
}

/// # Safety
/// `pc` vient de `wisq_pc_new`, course arrêtée.
#[no_mangle]
pub unsafe extern "C" fn wisq_pc_seed(pc: *mut WisqPC, seed: u64) -> c_int {
    let Some(poste) = poste(pc) else { return -1 };
    poste.semer(seed);
    0
}

fn code_de_branchement(refus: RefusDeBranchement) -> c_int {
    match refus {
        RefusDeBranchement::DejaDemarree => -2,
        RefusDeBranchement::EcranDejaLa => -3,
        RefusDeBranchement::EcranTropGrand => -4,
        RefusDeBranchement::ReseauDejaLa => -3,
    }
}

/// # Safety
/// `pc` vient de `wisq_pc_new`, course arrêtée.
#[no_mangle]
pub unsafe extern "C" fn wisq_pc_attach_display(pc: *mut WisqPC, width: u32, height: u32) -> c_int {
    let Some(poste) = poste(pc) else { return -1 };
    garder(WISQ_PC_PANIC, || {
        match poste.brancher_ecran(width, height) {
            Ok(()) => 0,
            Err(refus) => code_de_branchement(refus),
        }
    })
}

/// # Safety
/// `pc` vient de `wisq_pc_new`, course arrêtée ; `image` désigne `len`
/// octets lisibles.
#[no_mangle]
pub unsafe extern "C" fn wisq_pc_attach_disk(
    pc: *mut WisqPC,
    image: *const u8,
    len: usize,
) -> c_int {
    let Some(poste) = poste(pc) else { return -1 };
    if image.is_null() {
        return -1;
    }
    let octets = std::slice::from_raw_parts(image, len).to_vec();
    garder(WISQ_PC_PANIC, || {
        if octets.len() < 512 {
            return -3;
        }
        match poste.brancher_disque(Disque::Premier, ArriereMemoire(octets)) {
            Ok(()) => 0,
            Err(refus) => code_de_branchement(refus),
        }
    })
}

unsafe fn brancher_un_fichier(
    pc: *mut WisqPC,
    quel: Disque,
    base: *const c_char,
    writes: *const c_char,
) -> c_int {
    let Some(poste) = poste(pc) else { return -1 };
    if base.is_null() || writes.is_null() {
        return -1;
    }
    let (base, writes) = (chemin(base), chemin(writes));
    garder(WISQ_PC_PANIC, || {
        if poste.pret() {
            return -7;
        }
        match DisqueFichier::ouvrir(base, writes) {
            Ok(fichier) => match poste.brancher_disque(quel, fichier) {
                Ok(()) => 0,
                Err(_) => -7,
            },
            Err(RefusDuDisque::BaseIllisible) => -2,
            Err(RefusDuDisque::PasUnDisque) => -3,
            Err(RefusDuDisque::CoucheIllisible) => -4,
            Err(RefusDuDisque::CoucheDUnAutreDisque) => -5,
            Err(RefusDuDisque::CoucheTronquee) => -6,
        }
    })
}

/// # Safety
/// `pc` vient de `wisq_pc_new`, course arrêtée ; deux chemins terminés par NUL.
#[no_mangle]
pub unsafe extern "C" fn wisq_pc_attach_disk_file(
    pc: *mut WisqPC,
    base: *const c_char,
    writes: *const c_char,
) -> c_int {
    brancher_un_fichier(pc, Disque::Premier, base, writes)
}

/// # Safety
/// Comme `wisq_pc_attach_disk_file`.
#[no_mangle]
pub unsafe extern "C" fn wisq_pc_attach_second_disk_file(
    pc: *mut WisqPC,
    base: *const c_char,
    writes: *const c_char,
) -> c_int {
    brancher_un_fichier(pc, Disque::Second, base, writes)
}

/// **Lire un morceau de la base** d'un disque que l'appelant traduit
/// (`WisqPCDiskRead`) : remplir `length` octets à `buffer` depuis l'octet
/// `offset` du disque ; 1 s'ils y sont tous, 0 sinon.
pub type DiskReadCallback = Option<
    unsafe extern "C" fn(
        context: *mut c_void,
        offset: u64,
        buffer: *mut u8,
        length: usize,
    ) -> c_int,
>;
/// **Lâcher le lecteur** (`WisqPCDiskRelease`), une fois et une seule.
pub type DiskReleaseCallback = Option<unsafe extern "C" fn(context: *mut c_void)>;

/// **Le lecteur de l'appelant**, vu par la carte : un qcow2, un VMDK… que le
/// cœur Swift traduit (`VirtualDiskImages`). Il est lâché quand le disque
/// s'en va, ou tout de suite si le branchement est refusé.
struct LecteurC {
    taille: u64,
    lire: unsafe extern "C" fn(*mut c_void, u64, *mut u8, usize) -> c_int,
    lacher: DiskReleaseCallback,
    contexte: *mut c_void,
}

// SAFETY : le contrat de l'en-tête — `read` est appelé du fil qui fait
// tourner la machine, jamais deux fois à la fois (la carte est sous son
// verrou), et `release` d'un seul fil, une fois. Le contexte appartient au
// lecteur jusque-là.
unsafe impl Send for LecteurC {}

impl Lecteur for LecteurC {
    fn taille(&self) -> u64 {
        self.taille
    }

    fn lire(&mut self, decalage: u64, vers: &mut [u8]) -> bool {
        // SAFETY : `vers` est à nous, `vers.len()` octets inscriptibles ; le
        // disque ne demande jamais rien au-delà de `taille`.
        unsafe { (self.lire)(self.contexte, decalage, vers.as_mut_ptr(), vers.len()) == 1 }
    }
}

impl Drop for LecteurC {
    fn drop(&mut self) {
        if let Some(lacher) = self.lacher.take() {
            // SAFETY : une fois, le contexte que l'appelant a donné.
            unsafe { lacher(self.contexte) }
        }
    }
}

/// # Safety
/// `pc` vient de `wisq_pc_new`, course arrêtée ; `writes` est une chaîne
/// terminée par NUL ; `read` et `release` suivent le contrat de l'en-tête.
#[no_mangle]
pub unsafe extern "C" fn wisq_pc_attach_disk_reader(
    pc: *mut WisqPC,
    which: u32,
    size: u64,
    read: DiskReadCallback,
    release: DiskReleaseCallback,
    context: *mut c_void,
    writes: *const c_char,
) -> c_int {
    // Le lecteur d'abord : quoi qu'il arrive ensuite, `release` passe une
    // fois — au refus, en lâchant `lecteur` ; sinon avec le disque.
    let Some(lire) = read else {
        if let Some(lacher) = release {
            lacher(context);
        }
        return -1;
    };
    let lecteur = LecteurC {
        taille: size,
        lire,
        lacher: release,
        contexte: context,
    };
    let Some(poste) = poste(pc) else { return -1 };
    let quel = match which {
        0 => Disque::Premier,
        1 => Disque::Second,
        _ => return -1,
    };
    if writes.is_null() {
        return -1;
    }
    let writes = chemin(writes);
    garder(WISQ_PC_PANIC, move || {
        if poste.pret() {
            return -7;
        }
        match DisqueFichier::ouvrir_sur(Box::new(lecteur), writes) {
            Ok(disque) => match poste.brancher_disque(quel, disque) {
                Ok(()) => 0,
                Err(_) => -7,
            },
            Err(RefusDuDisque::PasUnDisque) => -3,
            Err(RefusDuDisque::CoucheDUnAutreDisque) => -5,
            Err(RefusDuDisque::CoucheTronquee) => -6,
            Err(_) => -4,
        }
    })
}

/// # Safety
/// `pc` vient de `wisq_pc_new`, course arrêtée ; `kernel` désigne `len`
/// octets ; `command_line` est nul ou une chaîne terminée par NUL ;
/// `initrd` est nul ou désigne `initrd_len` octets.
#[no_mangle]
pub unsafe extern "C" fn wisq_pc_load(
    pc: *mut WisqPC,
    kernel: *const u8,
    len: usize,
    command_line: *const c_char,
    initrd: *const u8,
    initrd_len: usize,
) -> c_int {
    let Some(poste) = poste(pc) else { return -1 };
    if kernel.is_null() {
        return -1;
    }
    let noyau = std::slice::from_raw_parts(kernel, len);
    let ligne = if command_line.is_null() {
        None
    } else {
        match std::ffi::CStr::from_ptr(command_line).to_str() {
            Ok(texte) => Some(texte),
            Err(_) => return -2,
        }
    };
    let initramfs = (!initrd.is_null()).then(|| std::slice::from_raw_parts(initrd, initrd_len));
    garder(WISQ_PC_PANIC, || {
        if poste.pret() {
            return -8;
        }
        use crate::pc::Refus;
        match poste.charger(noyau, ligne, initramfs) {
            Ok(_) => 0,
            Err(Refus::PasUnNoyau) => -3,
            Err(Refus::PasDEntree64Bits) => -4,
            Err(Refus::ProtocoleTropAncien(_)) => -5,
            Err(Refus::MemoireInsuffisante { .. }) => -6,
            Err(Refus::Tronque) => -7,
        }
    })
}

/// # Safety
/// `pc` vient de `wisq_pc_new` ; un seul fil à la fois.
#[no_mangle]
pub unsafe extern "C" fn wisq_pc_run(pc: *mut WisqPC, budget: u64) -> c_int {
    if pc.is_null() {
        return -1;
    }
    let sortie = (*pc).sortie;
    let contexte = (*pc).contexte;
    let Some(poste) = poste(pc) else { return -1 };
    if !poste.pret() {
        return -2;
    }
    let fin = garder(Fin::Faute("une panique dans la machine".into()), || {
        poste.courir(budget, &mut |octets: &[u8]| {
            if let Some(sortie) = sortie {
                sortie(contexte as *mut c_void, octets.as_ptr(), octets.len());
            }
        })
    });
    match fin {
        Fin::Budget => 0,
        Fin::Arretee => 1,
        Fin::Eteinte => 2,
        Fin::Remise => 3,
        Fin::Faute(pourquoi) => {
            *std::ptr::addr_of_mut!((*pc).faute) = pourquoi;
            4
        }
    }
}

/// # Safety
/// `pc` vient de `wisq_pc_new`, course arrêtée ; `buffer` est nul ou désigne
/// `capacity` octets inscriptibles.
#[no_mangle]
pub unsafe extern "C" fn wisq_pc_fault(
    pc: *const WisqPC,
    buffer: *mut c_char,
    capacity: usize,
) -> usize {
    if pc.is_null() {
        return 0;
    }
    let faute = &*std::ptr::addr_of!((*pc).faute);
    let octets = faute.as_bytes();
    if !buffer.is_null() && capacity > 0 {
        let copies = octets.len().min(capacity - 1);
        std::ptr::copy_nonoverlapping(octets.as_ptr(), buffer.cast::<u8>(), copies);
        *buffer.add(copies) = 0;
    }
    octets.len()
}

/// # Safety
/// `pc` vient de `wisq_pc_new` ; `bytes` désigne `len` octets. Tout fil.
#[no_mangle]
pub unsafe extern "C" fn wisq_pc_send(pc: *mut WisqPC, bytes: *const u8, len: usize) {
    let Some(commandes) = commandes(pc) else {
        return;
    };
    if bytes.is_null() || len == 0 {
        return;
    }
    let octets = std::slice::from_raw_parts(bytes, len);
    garder((), || commandes.envoyer(octets));
}

/// # Safety
/// `pc` vient de `wisq_pc_new` ; `codes` désigne `len` octets. Tout fil.
#[no_mangle]
pub unsafe extern "C" fn wisq_pc_keys(pc: *mut WisqPC, codes: *const u8, len: usize) -> c_int {
    let Some(commandes) = commandes(pc) else {
        return -1;
    };
    if codes.is_null() && len > 0 {
        return -1;
    }
    let octets = if len == 0 {
        &[][..]
    } else {
        std::slice::from_raw_parts(codes, len)
    };
    garder(WISQ_PC_PANIC, || match frappes_du_jeu_1(octets) {
        Ok(frappes) => c_int::from(commandes.frapper(&frappes)),
        Err(_) => -2,
    })
}

/// # Safety
/// `pc` vient de `wisq_pc_new`. Tout fil.
#[no_mangle]
pub unsafe extern "C" fn wisq_pc_keys_pending(pc: *const WisqPC) -> usize {
    commandes(pc).map_or(0, |commandes| garder(0, || commandes.frappes_en_attente()))
}

/// # Safety
/// `pc` vient de `wisq_pc_new`. Tout fil.
#[no_mangle]
pub unsafe extern "C" fn wisq_pc_keys_abandon(pc: *mut WisqPC) {
    if let Some(commandes) = commandes(pc) {
        garder((), || commandes.abandonner_la_frappe());
    }
}

/// # Safety
/// `pc` vient de `wisq_pc_new`. Tout fil.
#[no_mangle]
pub unsafe extern "C" fn wisq_pc_mouse(pc: *mut WisqPC, dx: i32, dy: i32, buttons: u8) {
    if let Some(commandes) = commandes(pc) {
        garder((), || commandes.souris(dx, dy, buttons));
    }
}

/// # Safety
/// `pc` vient de `wisq_pc_new`. Tout fil.
#[no_mangle]
pub unsafe extern "C" fn wisq_pc_touch(pc: *mut WisqPC, x: f64, y: f64, buttons: u8) -> c_int {
    let Some(commandes) = commandes(pc) else {
        return -1;
    };
    garder(WISQ_PC_PANIC, || {
        c_int::from(commandes.toucher(x, y, buttons))
    })
}

/// # Safety
/// `pc` vient de `wisq_pc_new`. Tout fil.
#[no_mangle]
pub unsafe extern "C" fn wisq_pc_scroll(pc: *mut WisqPC, notches: i32) -> c_int {
    let Some(commandes) = commandes(pc) else {
        return -1;
    };
    garder(WISQ_PC_PANIC, || c_int::from(commandes.defiler(notches)))
}

/// # Safety
/// `pc` vient de `wisq_pc_new` ; `out` est inscriptible. Tout fil.
#[no_mangle]
pub unsafe extern "C" fn wisq_pc_display(pc: *const WisqPC, out: *mut WisqPCDisplay) -> c_int {
    let Some(commandes) = commandes(pc) else {
        return -1;
    };
    if out.is_null() {
        return -1;
    }
    match garder(None, || commandes.ecran()) {
        Some(vue) => {
            *out = vue.into();
            0
        }
        None => -2,
    }
}

/// # Safety
/// `pc` vient de `wisq_pc_new` ; `pixels` désigne `capacity` octets
/// inscriptibles ; `out` est nul ou inscriptible. Tout fil.
#[no_mangle]
pub unsafe extern "C" fn wisq_pc_display_copy(
    pc: *const WisqPC,
    pixels: *mut u8,
    capacity: usize,
    out: *mut WisqPCDisplay,
) -> c_int {
    let Some(commandes) = commandes(pc) else {
        return -1;
    };
    if pixels.is_null() && capacity > 0 {
        return -1;
    }
    let vers = if capacity == 0 {
        &mut [][..]
    } else {
        std::slice::from_raw_parts_mut(pixels, capacity)
    };
    let (code, vue) = match garder(None, || commandes.copier_l_image(vers)) {
        None => return -2,
        Some(Ok(vue)) => (0, vue),
        Some(Err(vue)) => (-3, vue),
    };
    if !out.is_null() {
        *out = vue.into();
    }
    code
}

/// # Safety
/// `pc` vient de `wisq_pc_new` et n'a pas été libéré. Tout fil.
#[no_mangle]
pub unsafe extern "C" fn wisq_pc_stop(pc: *mut WisqPC) {
    if let Some(commandes) = commandes(pc) {
        commandes.arreter();
    }
}

/// # Safety
/// `pc` vient de `wisq_pc_new`, course arrêtée.
#[no_mangle]
pub unsafe extern "C" fn wisq_pc_retired(pc: *const WisqPC) -> u64 {
    poste_lu(pc).map_or(0, |poste| poste.machine.retirees)
}

/// # Safety
/// `pc` vient de `wisq_pc_new` ; `retired` et `rip` sont inscriptibles. Tout
/// fil.
#[no_mangle]
pub unsafe extern "C" fn wisq_pc_progress(
    pc: *const WisqPC,
    retired: *mut u64,
    rip: *mut u64,
) -> c_int {
    let Some(commandes) = commandes(pc) else {
        return -1;
    };
    if retired.is_null() || rip.is_null() {
        return -1;
    }
    match commandes.avancement() {
        Some((retirees, ici)) => {
            *retired = retirees;
            *rip = ici;
            1
        }
        None => 0,
    }
}

/// # Safety
/// `pc` vient de `wisq_pc_new` ; `slices` et `same_page` sont inscriptibles.
/// Tout fil.
#[no_mangle]
pub unsafe extern "C" fn wisq_pc_progress_pages(
    pc: *const WisqPC,
    slices: *mut u64,
    same_page: *mut u64,
) -> c_int {
    let Some(commandes) = commandes(pc) else {
        return -1;
    };
    if slices.is_null() || same_page.is_null() {
        return -1;
    }
    let (publiees, restees) = commandes.sejour();
    *slices = publiees;
    *same_page = restees;
    c_int::from(publiees > 0)
}

/// # Safety
/// `pc` vient de `wisq_pc_new`, course arrêtée.
#[no_mangle]
pub unsafe extern "C" fn wisq_pc_guest_time(pc: *const WisqPC) -> u64 {
    poste_lu(pc).map_or(0, |poste| poste.temps())
}

/// # Safety
/// `pc` vient de `wisq_pc_new`, course arrêtée.
#[no_mangle]
pub unsafe extern "C" fn wisq_pc_guest_hertz(pc: *const WisqPC) -> u64 {
    poste_lu(pc).map_or(0, |poste| poste.hertz())
}

/// # Safety
/// `pc` vient de `wisq_pc_new`, course arrêtée.
#[no_mangle]
pub unsafe extern "C" fn wisq_pc_halted(pc: *const WisqPC) -> c_int {
    poste_lu(pc).map_or(0, |poste| c_int::from(poste.machine.arretee))
}

/// # Safety
/// `pc` vient de `wisq_pc_new`, course arrêtée.
#[no_mangle]
pub unsafe extern "C" fn wisq_pc_elapse(pc: *mut WisqPC, seconds: f64) {
    if let Some(poste) = poste(pc) {
        poste.rattraper(seconds);
    }
}

/// # Safety
/// `pc` vient de `wisq_pc_new`, course arrêtée ; `out_bytes` et `out_len`
/// sont inscriptibles.
#[no_mangle]
pub unsafe extern "C" fn wisq_pc_snapshot(
    pc: *const WisqPC,
    out_bytes: *mut *mut u8,
    out_len: *mut usize,
) -> c_int {
    let Some(poste) = poste_lu(pc) else { return -1 };
    if out_bytes.is_null() || out_len.is_null() {
        return -1;
    }
    if !poste.pret() {
        return -2;
    }
    let sauve = match garder(None, || Some(instantane::sauver(poste))) {
        None => return WISQ_PC_PANIC,
        Some(Err(_)) => return -3,
        Some(Ok(sauve)) => sauve,
    };
    let mut sauve = sauve.into_boxed_slice();
    let (pointeur, longueur) = (sauve.as_mut_ptr(), sauve.len());
    std::mem::forget(sauve);
    *out_bytes = pointeur;
    *out_len = longueur;
    0
}

/// # Safety
/// `bytes` et `len` sont exactement ce que `wisq_pc_snapshot` a rendu, pas
/// encore libéré.
#[no_mangle]
pub unsafe extern "C" fn wisq_pc_free_snapshot(bytes: *mut u8, len: usize) {
    if !bytes.is_null() {
        drop(Box::from_raw(std::ptr::slice_from_raw_parts_mut(
            bytes, len,
        )));
    }
}

/// # Safety
/// `pc` vient de `wisq_pc_new`, course arrêtée ; `bytes` désigne `len` octets.
#[no_mangle]
pub unsafe extern "C" fn wisq_pc_restore(pc: *mut WisqPC, bytes: *const u8, len: usize) -> c_int {
    let Some(poste) = poste(pc) else { return -1 };
    if bytes.is_null() {
        return -1;
    }
    let octets = std::slice::from_raw_parts(bytes, len);
    garder(WISQ_PC_PANIC, || {
        match instantane::reprendre(poste, octets) {
            Ok(()) => 0,
            Err(RefusDInstantane::PasUnInstantane) => -2,
            Err(RefusDInstantane::VersionInconnue(_)) => -3,
            Err(RefusDInstantane::Abime) => -4,
            Err(RefusDInstantane::AutreMemoire { .. }) => -5,
            Err(RefusDInstantane::AutreEcran) => -6,
            Err(RefusDInstantane::Perime(_)) => -7,
            Err(RefusDInstantane::AutresDisques) => -8,
        }
    })
}

/// # Safety
/// `pc` vient de `wisq_pc_new`. Tout fil.
#[no_mangle]
pub unsafe extern "C" fn wisq_pc_flush_disks(pc: *mut WisqPC) -> c_int {
    let Some(commandes) = commandes(pc) else {
        return -1;
    };
    garder(WISQ_PC_PANIC, || {
        if commandes.vider_les_disques() {
            0
        } else {
            -2
        }
    })
}

/// # Safety
/// `pc` vient de `wisq_pc_new`. Tout fil.
#[no_mangle]
pub unsafe extern "C" fn wisq_pc_disk_bytes_written(pc: *const WisqPC) -> u64 {
    commandes(pc).map_or(0, |commandes| garder(0, || commandes.octets_ecrits()))
}

/// # Safety
/// `pc` vient de `wisq_pc_new` ; `served` et `refused` sont inscriptibles.
/// Tout fil.
#[no_mangle]
pub unsafe extern "C" fn wisq_pc_disk_activity(
    pc: *const WisqPC,
    served: *mut u64,
    refused: *mut u64,
) -> c_int {
    let Some(commandes) = commandes(pc) else {
        return -1;
    };
    if served.is_null() || refused.is_null() {
        return -1;
    }
    match garder(None, || commandes.activite_du_disque()) {
        Some((servies, refusees)) => {
            *served = servies;
            *refused = refusees;
            1
        }
        None => 0,
    }
}

/// Les compteurs du réseau, tels que C les lit (`WisqPCNetwork`).
#[repr(C)]
#[derive(Debug, Clone, Copy, Default)]
pub struct WisqPCNetwork {
    pub transmitted: u64,
    pub delivered: u64,
    pub dropped: u64,
    pub refused: u64,
    pub lost: u64,
    pub incoming: u64,
    pub outgoing: u64,
}

/// # Safety
/// `pc` vient de `wisq_pc_new`, course arrêtée ; `mac` est nul ou désigne six
/// octets.
#[no_mangle]
pub unsafe extern "C" fn wisq_pc_attach_network(pc: *mut WisqPC, mac: *const u8) -> c_int {
    let Some(poste) = poste(pc) else { return -1 };
    let mut adresse = wisq_carte::pc::MAC_PAR_DEFAUT;
    if !mac.is_null() {
        adresse.copy_from_slice(std::slice::from_raw_parts(mac, 6));
    }
    garder(WISQ_PC_PANIC, || match poste.brancher_reseau(adresse) {
        Ok(()) => 0,
        Err(refus) => code_de_branchement(refus),
    })
}

/// # Safety
/// `pc` vient de `wisq_pc_new` ; `frame` est nul ou désigne `capacity` octets
/// inscriptibles. Tout fil.
#[no_mangle]
pub unsafe extern "C" fn wisq_pc_net_take(
    pc: *mut WisqPC,
    frame: *mut u8,
    capacity: usize,
) -> usize {
    let Some(commandes) = commandes(pc) else {
        return 0;
    };
    let vers: &mut [u8] = if frame.is_null() {
        &mut []
    } else {
        std::slice::from_raw_parts_mut(frame, capacity)
    };
    garder(0, || commandes.prendre_trame(vers).unwrap_or(0))
}

/// # Safety
/// `pc` vient de `wisq_pc_new` ; `frame` désigne `len` octets. Tout fil.
#[no_mangle]
pub unsafe extern "C" fn wisq_pc_net_give(pc: *mut WisqPC, frame: *const u8, len: usize) -> c_int {
    let Some(commandes) = commandes(pc) else {
        return -1;
    };
    if frame.is_null() {
        return -1;
    }
    let trame = std::slice::from_raw_parts(frame, len);
    use crate::pc::reseau::Remise;
    garder(WISQ_PC_PANIC, || match commandes.remettre_trame(trame) {
        Some(Remise::Prise) => 1,
        Some(Remise::Pleine) => 0,
        Some(Remise::PasUneTrame) => -2,
        None => -3,
    })
}

/// # Safety
/// `pc` vient de `wisq_pc_new` ; `out` est inscriptible. Tout fil.
#[no_mangle]
pub unsafe extern "C" fn wisq_pc_net_stats(pc: *const WisqPC, out: *mut WisqPCNetwork) -> c_int {
    let Some(commandes) = commandes(pc) else {
        return -1;
    };
    if out.is_null() {
        return -1;
    }
    match garder(None, || commandes.compteurs_du_reseau()) {
        Some(((emises, livrees, perdues), files)) => {
            *out = WisqPCNetwork {
                transmitted: emises,
                delivered: livrees,
                dropped: perdues,
                refused: files.refusees,
                lost: files.perdues,
                incoming: files.entrantes as u64,
                outgoing: files.sortantes as u64,
            };
            1
        }
        None => 0,
    }
}

/// # Safety
/// `pc` vient de `wisq_pc_new`, aucune course en cours, et n'est plus
/// employé ensuite.
#[no_mangle]
pub unsafe extern "C" fn wisq_pc_free(pc: *mut WisqPC) {
    if !pc.is_null() {
        drop(Box::from_raw(pc));
    }
}
