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
// core interprets — 10,6 MIPS, and more than an hour to boot a desktop. WebKit
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
        // **Le seul refus qui ne soit pas définitif.** L'émetteur s'est arrêté
        // à moins de quinze octets du bord des octets fournis : l'instruction
        // qui l'a bloqué a pu être coupée. L'appelant redemande alors la même
        // région avec une fenêtre plus large, et **une seule fois**.
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
    let Ok(page) = desktop::page(pages, entry, name, screen) else {
        return -1;
    };
    hand_back(page.into_bytes(), out_bytes, out_len);
    0
}

/// Ce que la correspondance occupe **au-dessus** de la RAM de l'invité, en
/// pages. L'hôte doit l'ajouter à la taille de la mémoire qu'il crée.
#[no_mangle]
pub extern "C" fn wisq_desktop_table_pages() -> u32 {
    crate::x86_wasm::TABLE_PAGES
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
