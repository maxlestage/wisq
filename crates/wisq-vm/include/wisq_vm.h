/*
 * wisq-vm: an interpreted rv32ima machine, as C sees it.
 *
 * Swift owns the interface and the platform integration; this owns the
 * interpreter. The boundary is seven functions and one opaque pointer,
 * because every type crossing it is a type two languages have to agree
 * about forever.
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

/* Frees a machine. Must not be called while wisq_vm_run is in progress. */
void wisq_vm_free(WisqVM *vm);

#ifdef __cplusplus
}
#endif

#endif /* WISQ_VM_H */
