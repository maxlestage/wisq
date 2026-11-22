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
 * liability unless something checks it. Five C programs under `tests/abi/`
 * compile against this header and link the real static library: main.c boots
 * a kernel, x86.c translates a region, disk.c attaches a disk and queues
 * keystrokes, iso.c reads a disc image, pc.c drives the native PC machine.
 * A signature that drifts from src/ffi.rs fails one of them rather than
 * crashing on a phone.
 *
 * "Something checks it" was true of twenty of these declarations and false of
 * eleven — the disk family, the load that takes a tree, the keystroke queue —
 * and nothing said which. `every_declared_function_is_exercised_from_c` in
 * tests/abi.rs now names any declaration no C program calls, so a function
 * added here without a caller fails on the commit that adds it.
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

/* Le temps passé hors de la machine, en microsecondes, ajouté à mtime.
 * Machine arrêtée seulement. */
void wisq_vm_elapse(WisqVM *vm, uint64_t micros);

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
 * so the app's x86 core interprets — 10,6 MIPS when it was last measured,
 * before this header existed, and more than an hour to boot a desktop. That
 * figure is an origin point rather than a fact of today, and it cannot be
 * re-run from a Linux runner; what carries the argument is the order, which
 * has not moved. WebKit is the one exception: a WKWebView may compile
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
 * `+ wisq_desktop_tlb_pages() + wisq_desktop_code_pages(pages)`
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
/* La première instruction déborde du bord de ce qu'on lui a donné : à moins
   de quinze octets de la fin, le décodeur a lu au-delà, et une suite la
   rendrait lisible. Une instruction complète qu'il refuse, même tout près du
   bord, est WISQ_X86_REFUSED. Redemandez la même région avec une fenêtre plus
   large, une seule fois ; si la page d'après manque, c'est la faute de page
   que le silicium ferait. Sur un vrai noyau, 91 régions sur 10 116 tombaient
   là avec quatre kibioctets, et toutes se traduisaient au second essai. */
#define WISQ_X86_NEEDS_MORE  -2

/*
 * The page the application loads into its view: the host loop, the bridge to
 * the application, and the machine's starting state.
 *
 * `channel` names the message handler the application declares. It is *pasted
 * into JavaScript*, so only letters and digits are accepted — the same care as
 * for a VM identifier pasted into a command line.
 *
 * The frame is optional, and `screen_width == 0 && screen_height == 0` says so:
 * a machine judged on its registers has nothing to show. A frame that would
 * overflow the guest's RAM is refused — the correspondence lives just above it,
 * so such a frame would display the block table while destroying it.
 *
 * `boot_at` is where the application placed the zero page, or 0 when it has
 * none: the driver then points RSI at it, which is how a x86-64 kernel finds
 * its e820 map, its command line and its initramfs. A program judged on its
 * registers has no `boot_params` and wants none.
 *
 * Returns 0 and the page in UTF-8, or -1 when the RAM is not a power of two,
 * the channel name cannot be pasted safely, or the frame does not fit.
 */
int wisq_desktop_page(uint32_t pages, uint64_t entry, const char *channel,
                      uint64_t screen_base, uint32_t screen_width,
                      uint32_t screen_height, uint64_t boot_at,
                      uint8_t **out_bytes, size_t *out_len);

/*
 * The zero page the desktop hands the kernel, command line included.
 *
 * A x86-64 kernel entered without `boot_params` has no e820 map: it stops mute
 * in `extend_brk` at its 1067th region. The application places these four
 * kibibytes at `wisq_desktop_boot_page_at()` and passes that address to
 * `wisq_desktop_page` as `boot_at`; the driver then points RSI at it.
 *
 * `command_line` may be null, and the measured default is used.
 *
 * The frame is optional, and `screen_width == 0 && screen_height == 0` says so.
 * A desktop that declares one must tell the kernel about it *and* reserve it in
 * the e820 map: without that entry the allocator hands those pages out, and the
 * desktop corrupts itself under unrelated causes.
 *
 * Returns 0 and four kibibytes, or -1 when the RAM is not a power of two, the
 * line does not fit in the page, or the frame does not fit above it. The buffer
 * is freed by `wisq_x86_free_module`.
 */
int wisq_desktop_boot_page(uint32_t pages, const char *command_line,
                           uint64_t screen_base, uint32_t screen_width,
                           uint32_t screen_height, uint8_t **out_bytes,
                           size_t *out_len);

/*
 * Where the desktop's zero page must be placed in the guest's RAM. Written
 * here rather than in the application: the driver points RSI at it, and two
 * copies of the number would drift in silence.
 */
uint64_t wisq_desktop_boot_page_at(void);

/*
 * A file of the emitter machine's page, by name: `host.js`, `carte.js`,
 * `page-emitter.js`, `machine.js`, `machine.html`, and `wisq_page.wasm` when
 * the build embedded it (`WISQ_PAGE_WASM`). Returns 0 and **static** bytes —
 * they live as long as the library and are never freed — or -1 for an unknown
 * name or an absent module.
 */
int wisq_emitter_asset(const char *name, const uint8_t **out_bytes, size_t *out_len);

/*
 * The emitter machine's zero page: the montage's command line followed by
 * `extra` (null: nothing more), as it is — a leading `-` is a word of the
 * image's line, not a removal; `keep_bootcon` leaves the montage's part when
 * `extra` names `console=ttyS0`, since both together print every line
 * twice —, the card's screen (`width == 0 && height == 0`:
 * none), the archive (`initramfs_bytes == 0`: none) placed above `floor`.
 * Returns 0 and four kibibytes (freed with `wisq_x86_free_module`), or a named
 * refusal: 1 the RAM, 2 the line, 3 the screen, 4 the archive, -1 unreadable
 * arguments. On refusal 2, `out_len` receives the length of the whole line,
 * the montage's part included: that is what the 2047-byte bound judges, and
 * the caller cannot know it, since the montage's part depends on `extra`.
 */
int wisq_emitter_boot_page(uint32_t pages, const char *extra,
                           uint32_t screen_width, uint32_t screen_height,
                           uint64_t initramfs_at, uint64_t initramfs_bytes,
                           uint64_t floor, uint8_t **out_bytes, size_t *out_len);

/*
 * Whether this RAM can carry this kernel under the emitter. `entry` is the
 * ELF's physical entry point, `top` the top of its segments, BSS included.
 * Returns 0, or 1 no RAM, 2 not a power of two, 3 too small, 4 the fold takes
 * the virtual text somewhere other than onto itself — `out_folded`, when not
 * null, then receives where.
 */
int wisq_emitter_usable_ram(uint32_t pages, uint64_t entry, uint64_t top, uint64_t *out_folded);

/* Where the guest sees the card's video memory, as that zero page says. */
uint64_t wisq_emitter_screen_base(void);

/*
 * What the application may not write into the guest's RAM.
 *
 * It places its images through a single path; this says, before the first
 * write, whether the image fits and whether it leaves alone the two regions the
 * machine gives itself: the zero page the kernel reads before its first
 * instruction, and the frame the view repaints on every image.
 *
 * `boots` says whether the zero page exists: a program judged on its registers
 * has none, and forbidding it that address would be a refusal with no object.
 * The frame is optional as everywhere else here, and
 * `screen_width == 0 && screen_height == 0` says so.
 *
 * The verdict is a code rather than a boolean, because the caller tells the
 * user something about it: "the image spills" and "the image lands on the zero
 * page" are not fixed the same way.
 *
 *   0  placeable
 *   1  the RAM is not a power of two
 *   2  the image spills out of the RAM
 *   3  it would overwrite the zero page
 *   4  it lands in the frame
 *   5  it lands in the initramfs archive
 *
 * The archive is optional too, and `initramfs_bytes == 0` says so.
 */
int wisq_desktop_placement(uint32_t pages, uint64_t screen_base,
                           uint32_t screen_width, uint32_t screen_height,
                           uint64_t initramfs_at, uint64_t initramfs_bytes,
                           int boots, uint64_t at, uint64_t bytes);

/*
 * Tell the desktop's kernel where its root is.
 *
 * Without the two fields this writes — `ramdisk_image` at 0x218 and
 * `ramdisk_size` at 0x21c — the kernel walks every initcall, reaches
 * `prepare_namespace`, and dies on "VFS: Unable to mount root fs on
 * unknown-block(0,0)". The application places the archive's bytes itself; this
 * only declares them.
 *
 * The page is modified in place, not rebuilt: a path starting from scratch
 * would lose the command line and the e820 map `wisq_desktop_boot_page` put
 * there.
 *
 * Both bounds are computed here: the top of the zero page below, the frame's
 * base (or the end of the RAM) above.
 *
 *   0  declared
 *   1  the RAM is not a power of two
 *   2  an archive of zero bytes is not a root
 *   3  it is not where the kernel could read it
 *  -1  the page is null or shorter than four kibibytes
 */
int wisq_desktop_declare_initramfs(uint8_t *page, size_t page_len,
                                   uint32_t pages, uint64_t screen_base,
                                   uint32_t screen_width,
                                   uint32_t screen_height, uint64_t at,
                                   uint64_t bytes);

/*
 * A loadable segment of an ELF64 kernel: where it lives, and what it carries.
 *
 * The two sizes are not the same thing, and confusing them is expensive.
 * `file_size` is what the file carries; `memory_size` is what the segment
 * occupies once loaded. The difference is BSS — zeroes the kernel expects and
 * that no byte of the file describes. Alpine's vmlinux drags five mebibytes of
 * it.
 *
 * `physical_address` is where a loader places the segment; `virtual_address` is
 * where it was linked. For an x86-64 kernel's text the two differ by
 * `__START_KERNEL_map`, and the startup code moves from one to the other.
 */
typedef struct {
  uint64_t offset;
  uint64_t virtual_address;
  uint64_t physical_address;
  uint64_t file_size;
  uint64_t memory_size;
} wisq_kernel_load;

/*
 * An ELF64 kernel's entry point and its loadable segments.
 *
 * Without this the application cannot boot a real kernel at all: it has no way
 * to learn where the image goes or where execution starts, and both
 * `wisq_desktop_page`'s `entry` and the addresses the application places at
 * come from here. The measurement rig has read ELFs since #304; the desktop
 * could not.
 *
 * Ask twice: once with `capacity == 0` to learn the count, then with an array
 * of that size. `*out_entry` and `*out_count` are set whenever the image is
 * read, so the first call is not wasted.
 *
 *   0  read, and `out_count` segments were written to `out_loads`
 *   1  not an ELF64 this reader accepts, or a null pointer
 *   2  read, but `capacity` was too small — nothing was written to `out_loads`
 */
int wisq_kernel_loads(const uint8_t *image, size_t len, uint64_t *out_entry,
                      wisq_kernel_load *out_loads, size_t capacity,
                      size_t *out_count);

/*
 * What the correspondence occupies *above* the guest's RAM, in pages. The host
 * adds it to the size of the memory it creates.
 */
uint32_t wisq_desktop_table_pages(void);

/*
 * What the translation buffer takes, above the correspondence again. A
 * confined module declares it in its minimum: a host that has not laid it out
 * does not start.
 */
uint32_t wisq_desktop_tlb_pages(void);

/*
 * What the map of translated code and its log take, above the translation
 * buffer again, for a RAM of `pages` pages: one bit per 64-byte line, so a
 * size that follows the RAM's. To be added as well; a confined module
 * declares it in its minimum.
 */
uint32_t wisq_desktop_code_pages(uint32_t pages);

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

/*
 * Reading a bootable disc image.
 *
 * Someone arrives with an installation image and wants to run it. The kernel
 * is inside, under /boot, with its initramfs and the recipe that says how to
 * start them. The image itself never crosses this boundary — it weighs
 * gibibytes, and a phone does not have that. Two paths and a verdict cross.
 */

/*
 * The boot recipe of an image, or -1.
 *
 * The buffer holds FOUR NUL-terminated strings, in this order: the file the
 * recipe came from, the kernel's path, the initramfs' path, the command line.
 * The initramfs may be empty; the other three never are when this returns 0.
 *
 * Four NUL-terminated strings rather than one separated format: a command line
 * carries spaces, equals signs and commas, and a path carries everything but
 * the NUL byte. It is the one separator neither can contain, so the one that
 * needs no escaping — and an escaping convention, on both sides of a boundary,
 * is one more thing to hold forever.
 *
 * Released by wisq_x86_free_module, and by nothing else.
 */
int wisq_iso_recipe(const char *path, uint8_t **out_bytes, size_t *out_len);

/*
 * Writes a member of the image into a file. Returns 0, or -1.
 *
 * `ceiling` is what the caller accepts to write. Beyond it, refusal BEFORE
 * anything is written: a half-extracted kernel loads, and dies in an
 * instruction that has nothing to do with it.
 *
 * Content passes in 64 KiB slices; nothing of the image is held whole.
 *
 * If the copy fails partway the destination is left incomplete and this
 * returns -1: erasing it is the caller's, since the caller named it.
 */
int wisq_iso_extract(const char *path, const char *inside, const char *into,
                     uint64_t ceiling);

/* ------------------------------------------------------------------------
 * La machine PC native (x86-64), en Rust : `pc::Poste`.
 *
 * La même carte que le cœur Swift (X86Machine) : deux 8259, le 8253, le
 * 16550 sur 0x3F8 (ligne 4), l'horloge CMOS, et la carte des périphériques
 * toujours branchée (l'i8042, le pont PCI 440FX, les disques virtio en
 * 00:03.0 et 00:04.0, l'écran de Bochs en 00:02.0 et sa tablette en 00:07.0,
 * la carte réseau virtio en 00:05.0 : voir LE RÉSEAU).
 *
 * LES FILS. wisq_pc_run bloque. Les fonctions marquées « course arrêtée »
 * touchent la machine elle-même : un seul fil à la fois, et jamais pendant
 * un wisq_pc_run. Les fonctions marquées « tout fil » peuvent être appelées
 * de n'importe quel fil, pendant la course comme hors d'elle : elles ne
 * passent que par une moitié partagée, sous verrou ou atomique.
 *
 * LES PANIQUES. Aucune ne traverse cette frontière : chaque fonction vérifie
 * ses arguments et rend un code. Dans une construction qui déroule, une
 * panique imprévue est rattrapée et rend WISQ_PC_PANIC ; la bibliothèque de
 * l'application est construite avec panic = "abort", et une panique y arrête
 * le processus sans dérouler dans l'appelant.
 *
 * Les codes négatifs sont des refus ; -1 est toujours un argument nul.
 * ------------------------------------------------------------------------ */

/* Opaque : la machine, et la moitié que les autres fils atteignent. */
typedef struct WisqPC WisqPC;

/* Les issues de wisq_pc_run. */
#define WISQ_PC_BUDGET     0 /* le budget est épuisé ; la machine tourne ou dort encore */
#define WISQ_PC_STOPPED    1 /* wisq_pc_stop l'a demandé */
#define WISQ_PC_POWER_OFF  2 /* l'attente est épuisée : un hlt que rien ne réveillera */
#define WISQ_PC_REBOOT     3 /* l'invité a tiré la ligne de remise à zéro (i8042) */
#define WISQ_PC_FAULT      4 /* le cœur a refusé quelque chose : wisq_pc_fault le nomme */
#define WISQ_PC_NOT_READY -2 /* ni noyau chargé, ni machine reprise */
#define WISQ_PC_PANIC    -99 /* une panique rattrapée (construction qui déroule) */

/*
 * Une machine de `ram_bytes` octets de RAM (au moins 128 Mio : en dessous,
 * le plancher), sa carte branchée, l'horloge CMOS sur celle de l'hôte, le
 * générateur de rdrand sur la graine du cœur Swift. NULL quand l'hôte ne
 * peut pas donner la mémoire. Au-delà de 3 Gio, la RAM continue au-dessus
 * de 4 Gio (le trou des périphériques). Course arrêtée.
 *
 * `on_output` reçoit, après chaque tranche, ce que l'invité a écrit sur son
 * port série ; il peut être NULL (la console est jetée). Les octets sont
 * prêtés le temps de l'appel. `context` lui est rendu tel quel, et
 * l'appelant le garde en vie jusqu'à wisq_pc_free.
 */
WisqPC *wisq_pc_new(uint64_t ram_bytes, wisq_vm_output_callback on_output, void *context);

/*
 * Fige l'heure de l'horloge CMOS, en secondes depuis 1970 : deux courses du
 * même noyau retirent alors les mêmes instructions. L'heure est bornée là où
 * l'invité la lit (la CMOS de la carte) : une heure d'avant 1970 s'y lit le
 * 1er janvier 1970 à 00:00:00, une heure d'après l'an 9999 le 31 décembre
 * 9999 à 23:59:59. Course arrêtée. 0.
 */
int wisq_pc_set_time(WisqPC *pc, int64_t unix_seconds);

/* La graine de rdrand et rdseed : la même graine, les mêmes nombres. Une
 * application qui démarre des copies d'un même bureau en donne une neuve.
 * Course arrêtée. 0. */
int wisq_pc_seed(WisqPC *pc, uint64_t seed);

/*
 * Branche l'écran (la carte de Bochs, seize mébioctets de mémoire vidéo à
 * 0xE0000000) et sa tablette, annoncés au noyau par la page zéro ; la ligne
 * de commande reçoit alors `console=tty0` devant elle. Avant wisq_pc_load,
 * une seule fois : la mémoire vidéo ne bouge plus ensuite, et son adresse
 * (wisq_pc_display) reste valable jusqu'à wisq_pc_free. Course arrêtée.
 *
 * 0 ; -2 déjà chargée ; -3 un écran est déjà branché ; -4 une dimension
 * nulle, ou un cadre qui ne tient pas dans la mémoire vidéo.
 */
int wisq_pc_attach_display(WisqPC *pc, uint32_t width, uint32_t height);

/*
 * Un disque en mémoire, en premier disque (vda, 00:03.0, ligne 5) ; l'image
 * est copiée. Avant wisq_pc_load. Course arrêtée.
 * 0 ; -2 déjà chargée ; -3 moins d'un secteur.
 */
int wisq_pc_attach_disk(WisqPC *pc, const uint8_t *image, size_t len);

/*
 * Un disque lu sur place, en premier disque (vda) ou en second (vdb,
 * 00:04.0, ligne 6). `base` n'est jamais écrit ; `writes` et `writes.map`
 * sont créés s'ils manquent et portent chaque secteur que l'invité écrit —
 * le format de FileDiskStore. Avant wisq_pc_load. Course arrêtée.
 *
 * 0 ; -2 la base ne s'ouvre pas ; -3 moins d'un secteur ; -4 la couche ne
 * s'ouvre pas ; -5 la couche est celle d'un autre disque ; -6 la couche est
 * tronquée ; -7 déjà chargée (rien n'est alors ouvert ni créé).
 */
int wisq_pc_attach_disk_file(WisqPC *pc, const char *base, const char *writes);
int wisq_pc_attach_second_disk_file(WisqPC *pc, const char *base, const char *writes);

/*
 * Charge un bzImage x86-64 (protocole 2.06 au moins, entrée 64 bits) et met
 * le processeur dans l'état du protocole de démarrage 64 bits. `command_line`
 * peut être NULL (la ligne par défaut, la console sur ttyS0) ; `initrd` peut
 * être NULL. Une fois. Course arrêtée.
 *
 * 0 ; -2 la ligne n'est pas de l'UTF-8 ; -3 pas un noyau pour PC ; -4 pas
 * d'entrée 64 bits ; -5 protocole trop ancien ; -6 la RAM ne suffit pas ;
 * -7 le fichier est plus court que son en-tête ; -8 déjà chargée.
 */
int wisq_pc_load(WisqPC *pc, const uint8_t *kernel, size_t len, const char *command_line,
                 const uint8_t *initrd, size_t initrd_len);

/*
 * Fait tourner l'invité jusqu'à `budget` instructions de son temps (ce qu'il
 * retire et ce qu'il dort sur hlt ; le temps rattrapé par wisq_pc_elapse ne
 * compte pas), par tranches de deux cent mille au plus, entre lesquelles il
 * regarde wisq_pc_stop, wisq_pc_send et les frappes. Un wisq_pc_stop demandé
 * avant la course la fait rendre tout de suite. Un fil à la fois.
 *
 * Une des issues WISQ_PC_BUDGET, _STOPPED, _POWER_OFF, _REBOOT, _FAULT, ou
 * WISQ_PC_NOT_READY, -1.
 */
int wisq_pc_run(WisqPC *pc, uint64_t budget);

/*
 * Le nom de la dernière faute (WISQ_PC_FAULT), terminé par NUL et coupé à
 * `capacity` ; rend sa longueur entière, sans le NUL (0 : aucune faute).
 * `buffer` peut être NULL pour demander la longueur. Course arrêtée.
 */
size_t wisq_pc_fault(const WisqPC *pc, char *buffer, size_t capacity);

/* Des octets tapés au port série de l'invité. Tout fil. */
void wisq_pc_send(WisqPC *pc, const uint8_t *bytes, size_t len);

/*
 * Des frappes au clavier PS/2, en codes du jeu 1 : un octet par touche,
 * | 0x80 pour le relâchement, E0 devant une touche étendue (E0 48 enfonce
 * la flèche du haut, E0 C8 la relâche). Admises toutes ou aucune, et jouées
 * au rythme d'une main ; la file en tient 8192. Au-delà, un groupe qui ne
 * fait que relâcher entre quand même pour les touches que la file laisse
 * enfoncées. Tout fil.
 *
 * 1 admises ; 0 la file est pleine ; -2 un E0 seul, E1 (Pause), ou un code
 * nul.
 */
int wisq_pc_keys(WisqPC *pc, const uint8_t *codes, size_t len);

/* Les frappes que l'invité n'a pas encore reçues. Tout fil. */
size_t wisq_pc_keys_pending(const WisqPC *pc);

/*
 * Annule la frappe en cours : ce qui attend est jeté, les touches que la
 * file laissait enfoncées sont relâchées, et ce qu'on tape ensuite part
 * derrière au plus trente-deux frappes déjà remises à l'i8042. Tout fil.
 */
void wisq_pc_keys_abandon(WisqPC *pc);

/* Un mouvement de la souris PS/2, en pixels, Y vers le bas ; boutons :
 * 1 gauche, 2 droit, 4 milieu. Tout fil. */
void wisq_pc_mouse(WisqPC *pc, int32_t dx, int32_t dy, uint8_t buttons);

/*
 * Un toucher de la tablette : la position rapportée à l'écran (0 à 1), et
 * les boutons. 1 parti ; 0 l'invité n'a pas pris la tablette (ou pas
 * d'écran, ou une coordonnée qui n'est pas un nombre). Tout fil.
 */
int wisq_pc_touch(WisqPC *pc, double x, double y, uint8_t buttons);

/* La molette, en crans, positifs vers le haut. 1 parti ; 0 non (la tablette
 * n'est pas prise, ou zéro cran). Tout fil. */
int wisq_pc_scroll(WisqPC *pc, int32_t notches);

/*
 * L'écran. `memory` est la mémoire vidéo entière (`memory_size` octets,
 * XRGB8888 petit-boutien) ; le rectangle montré commence à `start` octets
 * et fait `height` lignes de `width` pixels, `bytes_per_row` octets de l'une
 * à l'autre. `revision` change à chaque écriture de l'invité et à chaque
 * changement de mode : égale à celle de la dernière image, rien à repeindre.
 * Lire `memory` pendant la course, c'est lire ce que l'invité écrit en même
 * temps : wisq_pc_display_copy copie sous le verrou de la carte.
 */
typedef struct {
    const uint8_t *memory;
    size_t memory_size;
    uint32_t width;
    uint32_t height;
    uint32_t bytes_per_row;
    uint32_t reserved;
    uint64_t start;
    uint64_t revision;
} WisqPCDisplay;

/* L'écran dans `out`. 0 ; -2 aucun écran branché. Tout fil. */
int wisq_pc_display(const WisqPC *pc, WisqPCDisplay *out);

/*
 * L'image montrée, copiée dans `pixels` ligne à ligne sans remplissage
 * (width × height × 4 octets), sous le verrou de la carte : le mode, les
 * pixels et la révision rendus dans `out` (qui peut être NULL) vont ensemble.
 * 0 ; -2 aucun écran ; -3 `capacity` trop court — rien n'est copié, et `out`
 * dit la taille qu'il faut. Tout fil.
 */
int wisq_pc_display_copy(const WisqPC *pc, uint8_t *pixels, size_t capacity,
                         WisqPCDisplay *out);

/* Demande à wisq_pc_run de rendre la main, à la fin de sa tranche. Tout fil. */
void wisq_pc_stop(WisqPC *pc);

/* Les instructions que l'invité a retirées (pas le temps passé sur hlt).
 * Course arrêtée. */
uint64_t wisq_pc_retired(const WisqPC *pc);

/*
 * Où en est la course, publié à la fin de chaque tranche : les instructions
 * retirées et RIP. En retard, jamais faux. 1 ; 0 rien n'a encore tourné.
 * Tout fil.
 */
int wisq_pc_progress(const WisqPC *pc, uint64_t *retired, uint64_t *rip);

/*
 * Le temps de l'invité, en instructions (retirées et dormies, sans le temps
 * rattrapé), et combien d'instructions valent une de ses secondes : de quoi
 * caler un invité qui dort sur l'horloge murale. Course arrêtée.
 */
uint64_t wisq_pc_guest_time(const WisqPC *pc);
uint64_t wisq_pc_guest_hertz(const WisqPC *pc);

/* Non nul quand le processeur est arrêté sur hlt. Course arrêtée. */
int wisq_pc_halted(const WisqPC *pc);

/*
 * Le temps passé hors de la machine, en secondes : il est payé ensuite, par
 * pas de dix secondes au plus, pendant que l'invité dort sur hlt. Un écart
 * négatif, nul ou qui n'est pas un nombre ne fait rien ; au-delà de dix ans,
 * il est borné. Course arrêtée.
 */
void wisq_pc_elapse(WisqPC *pc, double seconds);

/*
 * L'instantané de la machine, dans un tampon alloué ici, libéré par
 * wisq_pc_free_snapshot. Course arrêtée.
 *
 * Le format est à cette machine, versionné (« WISQPC\r\n », version 1). Il
 * porte : la RAM (les pages non nulles), le processeur entier (registres,
 * drapeaux, contrôle, EFER, XMM et MXCSR, x87), le système (GDT, IDT, tâche,
 * MSR), les 8259, le 8253, le 16550 et l'horloge CMOS de la machine, ses
 * compteurs, l'ombre de `sti`, l'état du générateur à graine (wisq_pc_seed),
 * l'écran annoncé, le temps encore à rattraper et le temps déjà rattrapé
 * (qui entre dans wisq_pc_guest_time). Il ne porte PAS la carte des
 * périphériques (i8042, PCI, disques virtio, écran de Bochs et sa mémoire
 * vidéo, tablette) : un invité qui s'en est servi ne se reprend pas
 * fidèlement.
 *
 * 0 ; -2 ni noyau chargé ni machine reprise.
 */
int wisq_pc_snapshot(const WisqPC *pc, uint8_t **out_bytes, size_t *out_len);
void wisq_pc_free_snapshot(uint8_t *bytes, size_t len);

/*
 * Reprend un instantané : tout est lu et vérifié avant que rien ne soit
 * reposé. Une machine qui a déjà tourné le reprend aussi : sa RAM est
 * effacée avant que les pages de l'instantané y soient posées, et les
 * traductions qu'elle gardait de ses propres tables sont oubliées, comme ses
 * témoins de faute. Le bit LMA d'EFER est recalculé de LME et de la
 * pagination, comme sur le silicium. Course arrêtée.
 * 0 ; -2 pas un instantané de cette machine ; -3 une version que ce code ne
 * lit pas ; -4 tronqué ou abîmé ; -5 une autre RAM ; -6 un autre écran (ou
 * un écran d'un côté seulement).
 */
int wisq_pc_restore(WisqPC *pc, const uint8_t *bytes, size_t len);

/* Pousse les écritures des disques jusqu'au stockage durable. 0 ; -2 un
 * disque l'a refusé. Tout fil. */
int wisq_pc_flush_disks(WisqPC *pc);

/* Les octets que l'invité a changés, sur les deux disques. Tout fil. */
uint64_t wisq_pc_disk_bytes_written(const WisqPC *pc);

/*
 * Ce que le premier disque a vu : les requêtes servies et refusées. 1 ; 0
 * aucun disque. Zéro et zéro dit un noyau sans pilote bloc. Tout fil.
 */
int wisq_pc_disk_activity(const WisqPC *pc, uint64_t *served, uint64_t *refused);

/*
 * LE RÉSEAU. La carte virtio-net du cœur Swift (00:05.0, ligne 3, la seule
 * fonction VIRTIO_NET_F_MAC), branchée avant wisq_pc_load. Ce qui fait un
 * réseau (DHCP, DNS, TCP vers l'hôte : UserNetwork) est de l'autre côté,
 * chez l'appelant. Les trames passent par DEUX FILES, sans rappel : rien de
 * l'appelant ne s'exécute sous un verrou de la machine. L'appelant vide ce
 * que l'invité émet (wisq_pc_net_take) et remet ce qui arrive pour lui
 * (wisq_pc_net_give), de n'importe quel fil, quand il veut — entre deux
 * wisq_pc_run, par exemple. La carte interroge la file entrante au tour du
 * matériel : toutes les 1 024 instructions quand l'invité travaille, à
 * chaque tour quand il dort, comme le cœur Swift.
 *
 * Une trame est une trame Ethernet sans l'en-tête virtio, d'un à
 * WISQ_PC_FRAME_MAX octets. Chaque file en tient WISQ_PC_FRAME_QUEUE au plus.
 * Pleine, la file entrante refuse la trame remise (0, compté dans
 * `refused`) ; pleine, la file sortante perd la trame que l'invité émet
 * (comptée dans `lost`).
 */
#define WISQ_PC_FRAME_MAX   1514
#define WISQ_PC_FRAME_QUEUE 512

/*
 * Branche la carte réseau, d'adresse `mac` (six octets ; NULL : celle du cœur
 * Swift, 02:77:69:73:71:01). 0 ; -2 machine déjà chargée ou reprise ; -3 une
 * carte déjà branchée. Avant wisq_pc_load. Course arrêtée.
 */
int wisq_pc_attach_network(WisqPC *pc, const uint8_t *mac);

/*
 * La prochaine trame que l'invité a émise, dans son ordre. Rend sa longueur ;
 * si `frame` n'est pas NULL et que `capacity` la tient, elle y est copiée et
 * retirée de la file — sinon elle reste, et la longueur dit le tampon qu'il
 * faut (WISQ_PC_FRAME_MAX suffit toujours). 0 : rien n'attend, ou pas de
 * carte. Tout fil.
 */
size_t wisq_pc_net_take(WisqPC *pc, uint8_t *frame, size_t capacity);

/*
 * Remet une trame à l'invité : copiée, elle attend que la carte la prenne,
 * puis un tampon de l'invité. 1 prise ; 0 la file entrante est pleine (la
 * trame n'est pas prise ; le refus est compté) ; -2 ce n'est pas une trame
 * (vide, ou plus de WISQ_PC_FRAME_MAX octets) ; -3 pas de carte. Tout fil.
 */
int wisq_pc_net_give(WisqPC *pc, const uint8_t *frame, size_t len);

/* Les compteurs du réseau. */
typedef struct {
    uint64_t transmitted; /* émises par l'invité et données à la file sortante */
    uint64_t delivered;   /* rangées dans les tampons de l'invité */
    uint64_t dropped;     /* perdues par la carte : sans tampon assez grand, attente pleine… */
    uint64_t refused;     /* refusées à l'entrée, file pleine */
    uint64_t lost;        /* perdues à la sortie, file pleine */
    uint64_t incoming;    /* attendent dans la file entrante */
    uint64_t outgoing;    /* attendent dans la file sortante */
} WisqPCNetwork;

/* 1 ; 0 pas de carte. Tout fil. */
int wisq_pc_net_stats(const WisqPC *pc, WisqPCNetwork *out);

/* Libère la machine. Aucune course en cours ; plus rien ne l'emploie après. */
void wisq_pc_free(WisqPC *pc);


#ifdef __cplusplus
}
#endif

#endif /* WISQ_VM_H */
