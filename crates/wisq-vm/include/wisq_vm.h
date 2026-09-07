/*
 * wisq-vm: an interpreted rv32ima machine, as C sees it.
 *
 * Swift owns the interface and the platform integration; this owns the
 * interpreter. The boundary stays small on purpose, because every type
 * crossing it is a type two languages have to agree about forever. The
 * machine side is one opaque pointer; the x86 translator at the bottom adds
 * no type at all — bytes in, bytes out, and four numbers.
 *
 * This header is hand-written rather than generated, and that is a
 * liability unless something checks it: `tests/abi.c` compiles against
 * this header, links the real static library and boots a kernel through
 * it. A signature that drifts from src/ffi.rs fails that test rather
 * than crashing on a phone.
 *
 * Threading contract: `wisq_vm_run` blocks and must be called from one
 * thread at a time for a given machine. `wisq_vm_send` and `wisq_vm_stop`
 * are safe from any thread while it runs.
 */

#ifndef WISQ_VM_H
#define WISQ_VM_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Opaque: a machine plus the handle other threads reach it through. */
typedef struct WisqVM WisqVM;

/* Called with each batch of console bytes the guest writes. The bytes are
 * borrowed for the duration of the call — copy anything you keep. */
typedef void (*wisq_vm_output_callback)(void *context, const uint8_t *bytes, size_t len);

/* Outcomes of wisq_vm_run. Negative values are errors. */
#define WISQ_VM_POWER_OFF 0
#define WISQ_VM_REBOOT    1
#define WISQ_VM_STOPPED   2

/* Failures of wisq_vm_load. */
#define WISQ_VM_LOAD_OK                  0
#define WISQ_VM_LOAD_NULL               -1
#define WISQ_VM_LOAD_COMMAND_LINE_UTF8  -2
#define WISQ_VM_LOAD_IMAGE_EMPTY        -3
#define WISQ_VM_LOAD_IMAGE_TOO_LARGE    -4
#define WISQ_VM_LOAD_COMMAND_LINE_LONG  -5
/* More RAM than a 32-bit hart can address: guest memory starts at 0x80000000,
   so two gibibytes is the last byte it can own. See MAXIMUM_RAM_SIZE. */
#define WISQ_VM_LOAD_RAM_UNSUPPORTED    -6

/* wisq_vm_restore. */
#define WISQ_VM_SNAPSHOT_OK              0
#define WISQ_VM_SNAPSHOT_NULL           -1
#define WISQ_VM_SNAPSHOT_NOT_A_SNAPSHOT -2
#define WISQ_VM_SNAPSHOT_CORRUPT        -3
#define WISQ_VM_SNAPSHOT_RAM_MISMATCH   -4

/*
 * A machine with `ram_size` bytes of guest RAM.
 *
 * `context` is handed back to `on_output` untouched; the caller owns
 * whatever it points at and must keep it alive until wisq_vm_free.
 */
WisqVM *wisq_vm_new(size_t ram_size, wisq_vm_output_callback on_output, void *context);

/*
 * Loads a kernel image. `command_line` may be NULL; when it is not, it is
 * read as a NUL-terminated UTF-8 string. Returns one of WISQ_VM_LOAD_*.
 */
int wisq_vm_load(WisqVM *vm, const uint8_t *image, size_t len, const char *command_line);

/*
 * The same, with the device tree supplied by the caller.
 *
 * The tree is what the firmware tells the kernel about the board, and wisq
 * runs two interpreters on the same board: one producer keeps them describing
 * the same machine, and lets the app declare a device without teaching two
 * codebases about it. wisq_vm_load stays for a caller with no tree of its own.
 */
int wisq_vm_load_with_tree(WisqVM *vm, const uint8_t *image, size_t len,
                           const uint8_t *tree, size_t tree_len);

/*
 * Gives the machine a disk, seen by the guest on /dev/vda.
 *
 * Call before loading: it is the tree that makes the device findable, and the
 * tree arrives from the caller. A tree without the node describes a machine
 * with no disk, and the guest never probes the window.
 *
 * The image is copied — the device holds it whole and writes into it, which is
 * what lets the guest's writes survive a suspension.
 */
int wisq_vm_attach_disk(WisqVM *vm, const uint8_t *image, size_t len);

/*
 * Gives the machine a disk read from a file, with a durable write overlay.
 *
 * base is opened read-only and never changes; writes and writes.map are
 * created beside it if absent and hold every sector the guest writes, as it
 * writes them. Nothing of the base is copied.
 *
 * Returns 0, or -1 for a null argument, -2 when the base cannot be opened,
 * -3 when it is smaller than a sector, -4 when the overlay cannot be opened,
 * -5 when the overlay belongs to another disk, -6 when the overlay is
 * truncated.
 */
int wisq_vm_attach_disk_file(WisqVM *vm, const char *base, const char *writes);

/* Pushes what the guest wrote to its disk down to durable storage. */
int wisq_vm_flush_disk(const WisqVM *vm);

/*
 * How many bytes of disk the guest changed: the overlay's size for a
 * file-backed disk, the whole image for a memory one.
 */
uint64_t wisq_vm_disk_bytes_written(const WisqVM *vm);

/* Takes the disk away, and drops the interrupt line with it. */
int wisq_vm_detach_disk(WisqVM *vm);

/*
 * How many requests the disk served, and how many it refused. A device that
 * refuses everything and a device nobody calls read the same without both.
 */
uint64_t wisq_vm_disk_served(const WisqVM *vm);
uint64_t wisq_vm_disk_refused(const WisqVM *vm);

/* Non-zero while a disk is attached. */
int wisq_vm_has_disk(const WisqVM *vm);

/*
 * Runs until shutdown, reboot, stop, or the instruction budget is spent.
 * Returns one of WISQ_VM_POWER_OFF / REBOOT / STOPPED. Blocks the calling
 * thread — that is the point; the caller owns a thread for it.
 */
int wisq_vm_run(WisqVM *vm, uint64_t instruction_budget);

/* Queues keyboard bytes for the guest's UART. Safe from any thread. */
void wisq_vm_send(WisqVM *vm, const uint8_t *bytes, size_t len);

/* Asks a running wisq_vm_run to return. Safe from any thread. */
void wisq_vm_stop(WisqVM *vm);

/* Instructions the guest has actually retired — retired, not offered. */
uint64_t wisq_vm_retired_instructions(const WisqVM *vm);

/*
 * Saves the whole machine: RAM, the hart, and the keystrokes still queued.
 *
 * On success writes a buffer and its length through the out-parameters and
 * returns WISQ_VM_SNAPSHOT_OK; the caller owns the buffer and must hand it
 * back to wisq_vm_free_snapshot, not to free(). Not the console output — that
 * has already been delivered to the callback and belongs to whoever draws the
 * terminal.
 *
 * A booted 64 MB machine saves in roughly 9 MB: runs of untouched memory are
 * folded rather than written.
 *
 * Must not be called while wisq_vm_run is in progress on this machine.
 */
int wisq_vm_snapshot(const WisqVM *vm, uint8_t **out_bytes, size_t *out_len);

/* Releases a buffer from wisq_vm_snapshot. Both arguments must be as returned. */
void wisq_vm_free_snapshot(uint8_t *bytes, size_t len);

/*
 * Puts a saved machine back, replacing everything this one holds.
 *
 * Returns WISQ_VM_SNAPSHOT_OK, or a negative code. On any failure the machine
 * is left exactly as it was rather than half-written — a guest holding half of
 * yesterday's memory is worse than a refused restore.
 *
 * Must not be called while wisq_vm_run is in progress on this machine.
 */
int wisq_vm_restore(WisqVM *vm, const uint8_t *bytes, size_t len);

/* Frees a machine. Must not be called while wisq_vm_run is in progress. */
void wisq_vm_free(WisqVM *vm);

/*
 * The x86-64 to WebAssembly translator.
 *
 * iOS gives an App Store app no page that is both writable and executable,
 * so the app's x86 core interprets — 10,6 MIPS, more than an hour to boot a
 * desktop. WebKit is the one exception: a WKWebView may compile
 * WebAssembly, which is data rather than code. These five functions are how
 * Swift reaches the emitter that produces it.
 *
 * They are not a machine. wisq-vm's x86 side is a processor and a decoder:
 * no paging, no devices, no kernel loader. What crosses here is a pure
 * function from bytes to bytes, plus four numbers describing what the
 * resulting module imports. The machine stays in Swift.
 */

/*
 * Translates a region of x86-64 code into a WebAssembly module.
 *
 * `base` is the guest address the region is loaded at, and it is not
 * decorative: `call` pushes a return address and `ret` reads it back.
 * `entry` is the offset within `code` where translation starts.
 *
 * Returns 0 and a freshly allocated module, or -1 when the emitter refuses
 * the region. A refusal is a normal outcome, not a defect — the caller then
 * interprets. Release the buffer with wisq_x86_free_module and nothing else.
 */
int wisq_x86_emit_region(const uint8_t *code, size_t len, uint64_t base, size_t entry,
                         uint8_t **out_bytes, size_t *out_len);

/*
 * The form the local desktop actually needs.
 *
 * wisq_x86_emit_region returns the historical shape: a lone region that hands
 * control back the moment it leaves itself. This one is *linked* — its blocks
 * sit in the host's shared table from `slot` onwards — and *confined*: guest
 * addresses are folded into `pages` 64 KiB pages, which puts the address to
 * block-index correspondence just above them, out of the guest's reach. The
 * module reads it itself and moves between regions without going back through
 * the application.
 *
 * `pages` must be a power of two: the fold is a mask, and a mask only
 * describes an interval on a power of two. Otherwise, refusal — as for a
 * region the emitter cannot translate.
 *
 * The host must provide a memory of at least `pages + wisq_desktop_table_pages()`
 * pages, and a table of at least `slot` plus the region's blocks. A module
 * given less does not instantiate, which is loud; were it to instantiate, it
 * would trap on the first jump, and a WebAssembly trap has no return.
 *
 * Returns one of the three WISQ_X86_* codes below. Three and not two: a flat
 * refusal and a lack of bytes are not fixed the same way, and telling them
 * apart is what lets the view ask again exactly when it helps.
 */
int wisq_x86_emit_resolving(const uint8_t *code, size_t len, uint64_t base, size_t entry,
                            uint32_t slot, uint32_t pages,
                            uint8_t **out_bytes, size_t *out_len);

/* Ce que wisq_x86_emit_resolving répond. Trois issues et non deux : un refus
   franc et un manque d'octets ne se corrigent pas pareil. */
#define WISQ_X86_TRANSLATED   0
#define WISQ_X86_REFUSED     -1
/* L'émetteur s'est arrêté à moins de quinze octets du bord de ce qu'on lui a
   donné : l'instruction qui l'a bloqué a pu être coupée plutôt qu'être
   inconnue. Redemandez la même région avec une fenêtre plus large, une seule
   fois. Sur un vrai noyau, 91 régions sur 10 116 tombent là avec quatre
   kibioctets, et toutes se traduisent au second essai. */
#define WISQ_X86_NEEDS_MORE  -2

/*
 * The page the application loads into its view: the host loop, the bridge to
 * the application, and the machine's starting state.
 *
 * `channel` names the message handler the application declares. It is *pasted
 * into JavaScript*, so only letters and digits are accepted — the same care as
 * for a VM identifier pasted into a command line.
 *
 * Returns 0 and the page in UTF-8, or -1 when the RAM is not a power of two or
 * the channel name cannot be pasted safely.
 */
int wisq_desktop_page(uint32_t pages, uint64_t entry, const char *channel,
                      uint8_t **out_bytes, size_t *out_len);

/*
 * What the correspondence occupies *above* the guest's RAM, in pages. The host
 * adds it to the size of the memory it creates.
 */
uint32_t wisq_desktop_table_pages(void);

/*
 * Releases a buffer from wisq_x86_emit_region, wisq_x86_emit_resolving or
 * wisq_desktop_page. A machine snapshot is not one of these: it has its own
 * wisq_vm_free_snapshot.
 */
void wisq_x86_free_module(uint8_t *bytes, size_t len);

/*
 * What the host must provide to instantiate a module: a memory of this many
 * 64 KiB pages, imported as env.mem, and this many mutable i64 globals named
 * env.g0 .. env.g<count-1>.
 *
 * Functions rather than constants, because a header carries no arithmetic: a
 * literal here would be a second declaration of a number the emitter owns,
 * and a module importing twenty-nine globals instantiated with twenty-eight
 * does not run at all.
 */
uint32_t wisq_x86_guest_pages(void);
size_t wisq_x86_global_count(void);

/* Where execution stopped, so the host knows where to resume. */
size_t wisq_x86_rip_slot(void);

/* The GS segment base, which the host sets and the module reads. */
size_t wisq_x86_gs_slot(void);

#ifdef __cplusplus
}
#endif

#endif /* WISQ_VM_H */
