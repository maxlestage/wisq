/*
 * The C ABI, exercised as a C caller actually uses it.
 *
 * This exists because `include/wisq_vm.h` is hand-written. A header that
 * drifts from src/ffi.rs is not a compile error on the Rust side and not a
 * compile error on the Swift side either — it is a wrong call at runtime,
 * on a phone, with no symptom until memory is already corrupt. Compiling
 * against the header and linking the real static library turns that class
 * of mistake back into a build or test failure.
 *
 * It is also the iOS proof: the same source, cross-compiled for the
 * simulator and run inside a booted iPhone, is what `scripts/test-ios.sh`
 * executes. If the interpreter boots a real Linux kernel there, the core
 * is ready for the app — which is the question the Rust switch has been
 * waiting on.
 *
 *   cc -I include tests/abi/main.c -L <libdir> -lwisq_vm -o abi && ./abi <image>
 */

#include "wisq_vm.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* What the guest printed, capped: a boot log is tens of kilobytes and this
 * only needs enough to recognise the banner. */
#define CONSOLE_CAPACITY (64 * 1024)

struct console {
    char text[CONSOLE_CAPACITY];
    size_t len;
};

static void on_output(void *context, const uint8_t *bytes, size_t len) {
    struct console *console = (struct console *)context;
    for (size_t index = 0; index < len; index++) {
        if (console->len + 1 >= CONSOLE_CAPACITY) return;
        console->text[console->len++] = (char)bytes[index];
    }
    console->text[console->len] = '\0';
}

static int fail(const char *what) {
    fprintf(stderr, "ABI: %s\n", what);
    return 1;
}

int main(int argc, char **argv) {
    if (argc < 2) return fail("usage: abi <image-noyau>");

    FILE *file = fopen(argv[1], "rb");
    if (!file) return fail("image de noyau illisible");
    fseek(file, 0, SEEK_END);
    long size = ftell(file);
    fseek(file, 0, SEEK_SET);
    if (size <= 0) { fclose(file); return fail("image vide"); }
    uint8_t *image = malloc((size_t)size);
    if (!image) { fclose(file); return fail("allocation impossible"); }
    if (fread(image, 1, (size_t)size, file) != (size_t)size) {
        fclose(file); free(image); return fail("lecture incomplète");
    }
    fclose(file);

    struct console console = {.len = 0};
    WisqVM *vm = wisq_vm_new(64 * 1024 * 1024, on_output, &console);
    if (!vm) { free(image); return fail("wisq_vm_new a renvoyé NULL"); }

    /* A refused load must say why rather than crash: the error codes in the
     * header are part of the contract too. */
    int empty = wisq_vm_load(vm, image, 0, NULL);
    if (empty != WISQ_VM_LOAD_IMAGE_EMPTY) {
        fprintf(stderr, "ABI: une image vide a renvoyé %d, attendu %d\n",
                empty, WISQ_VM_LOAD_IMAGE_EMPTY);
        wisq_vm_free(vm); free(image); return 1;
    }

    int loaded = wisq_vm_load(vm, image, (size_t)size, "console=ttyS0");
    if (loaded != WISQ_VM_LOAD_OK) {
        fprintf(stderr, "ABI: chargement refusé (%d)\n", loaded);
        wisq_vm_free(vm); free(image); return 1;
    }

    /* Enough to reach the banner, bounded so a broken core fails the test
     * instead of hanging a CI runner. */
    int outcome = wisq_vm_run(vm, 400ull * 1000 * 1000);
    uint64_t retired = wisq_vm_retired_instructions(vm);

    printf("sortie %d, %llu instructions retirées, %zu octets de console\n",
           outcome, (unsigned long long)retired, console.len);

    int ok = 1;
    if (retired == 0) { fprintf(stderr, "ABI: aucune instruction retirée\n"); ok = 0; }
    if (!strstr(console.text, "Linux version")) {
        fprintf(stderr, "ABI: la bannière Linux n'est pas apparue\n");
        fprintf(stderr, "--- console (%zu octets) ---\n%.600s\n", console.len, console.text);
        ok = 0;
    }

    /* stop() must be safe on a machine that is no longer running, which is
     * exactly what the app does when a view disappears mid-boot. */
    wisq_vm_stop(vm);
    wisq_vm_free(vm);
    free(image);

    if (ok) printf("ABI conforme : l'en-tête et la bibliothèque s'accordent\n");
    return ok ? 0 : 1;
}
