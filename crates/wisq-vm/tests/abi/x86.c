/*
 * The x86-to-WebAssembly translator, exercised as a C caller actually uses it.
 *
 * `include/wisq_vm.h` is hand-written, so a signature that drifts from
 * src/ffi.rs is not a Rust error and not a Swift error either — it is a wrong
 * call at runtime, on a phone. This is the same argument as tests/abi/main.c
 * makes for the machine, applied to the five functions the local desktop needs.
 *
 * It is deliberately separate from main.c, and it needs no kernel image: the
 * machine's conformance test skips itself when the image is missing, and the
 * translator has no reason to be skipped with it.
 *
 *   cc -I include tests/abi/x86.c -L <libdir> -lwisq_vm -o x86 && ./x86
 */

#include "wisq_vm.h"

#include <stdio.h>
#include <string.h>

/* A region that loops on itself: addq %rax, %rdx ; jnz back.
 *
 * Any region the emitter accepts would do — what is under test here is the
 * boundary, not the translation, which the Rust tests compare against real
 * silicon. Two instructions keep the expectations about *shape* rather than
 * about a byte string that would then exist in two places. */
static const uint8_t LOOP[] = {0x48, 0x01, 0xc2, 0x75, 0xfb};

/* 0x06 is `push es`, which does not exist in 64-bit mode. The emitter refuses
 * what it cannot decode, and a refusal is a normal outcome: the caller
 * interprets instead. A translator that returned a module here would be worse
 * than one that refuses. */
static const uint8_t INVALID[] = {0x06};

#define GUEST_BASE 0x30000000ull

static int failures = 0;

static void check(int condition, const char *what) {
    if (!condition) {
        printf("ÉCHEC   %s\n", what);
        failures++;
    }
}

/* Does `haystack` contain `needle`? memmem is a GNU extension, and this has to
 * build on Apple's toolchain too. */
static int contains(const uint8_t *haystack, size_t haystack_len,
                    const uint8_t *needle, size_t needle_len) {
    if (needle_len > haystack_len) return 0;
    for (size_t at = 0; at + needle_len <= haystack_len; at++) {
        if (memcmp(haystack + at, needle, needle_len) == 0) return 1;
    }
    return 0;
}

/* WebAssembly's variable-length unsigned integer. */
static size_t leb128(uint64_t value, uint8_t *out) {
    size_t written = 0;
    do {
        uint8_t byte = (uint8_t)(value & 0x7f);
        value >>= 7;
        if (value != 0) byte |= 0x80;
        out[written++] = byte;
    } while (value != 0);
    return written;
}

/* The import entry for one global: "env", its name, then a mutable i64. */
static size_t global_entry(size_t slot, uint8_t *out) {
    char name[24];
    int name_len = snprintf(name, sizeof name, "g%zu", slot);
    if (name_len < 0 || (size_t)name_len >= sizeof name) return 0;
    size_t at = 0;
    out[at++] = 3;
    memcpy(out + at, "env", 3);
    at += 3;
    out[at++] = (uint8_t)name_len;
    memcpy(out + at, name, (size_t)name_len);
    at += (size_t)name_len;
    out[at++] = 0x03;
    out[at++] = 0x7e;
    out[at++] = 0x01;
    return at;
}

int main(void) {
    uint8_t *module = NULL;
    size_t len = 0;

    check(wisq_x86_emit_region(LOOP, sizeof LOOP, GUEST_BASE, 0, &module, &len) == 0,
          "l'émetteur traduit une région qu'il accepte");
    check(module != NULL && len > 0, "et rend un module, pas un pointeur nul");
    if (module == NULL) {
        printf("rien à vérifier sans module\n");
        return 1;
    }

    check(len >= 8 && memcmp(module, "\0asm\1\0\0\0", 8) == 0,
          "le module porte l'en-tête WebAssembly et sa version");

    /* The four numbers describe *this* module. A host that creates one global
     * too few does not get a bad figure, it gets nothing: the instantiation
     * fails. Tying them to the bytes is the whole point of exporting them. */
    size_t globals = wisq_x86_global_count();
    check(globals > 16, "les seize registres, au moins, sont importés");
    check(wisq_x86_rip_slot() < globals, "RIP désigne une globale qui existe");
    check(wisq_x86_gs_slot() < globals, "la base de GS aussi");
    check(wisq_x86_rip_slot() != wisq_x86_gs_slot(), "et ce n'est pas la même");

    uint8_t entry[32];
    size_t entry_len = global_entry(globals - 1, entry);
    check(contains(module, len, entry, entry_len),
          "la dernière globale annoncée est bien importée par le module");
    entry_len = global_entry(globals, entry);
    check(!contains(module, len, entry, entry_len),
          "et il n'en importe pas une de plus que ce qui est annoncé");

    uint8_t memory[32];
    size_t at = 0;
    memory[at++] = 3;
    memcpy(memory + at, "env", 3);
    at += 3;
    memory[at++] = 3;
    memcpy(memory + at, "mem", 3);
    at += 3;
    memory[at++] = 0x02;
    memory[at++] = 0x00;
    at += leb128(wisq_x86_guest_pages(), memory + at);
    /* Redundant with the Rust assertion next door, on purpose: that one holds
     * the number, this one holds the tie between the number and the bytes, as
     * a C caller sees them through the header. Removing this check breaks no
     * test — the Rust side catches the same mutation — and it is kept because
     * the header, not the crate, is what Swift reads. */
    check(contains(module, len, memory, at),
          "et il importe exactement le nombre de pages annoncé");

    check(contains(module, len, (const uint8_t *)"run", 3),
          "le module exporte « run », ce que l'hôte appelle");

    /* `entry` is not decoration either: it says where translation starts, and
     * a translator that ignored it would hand the host the wrong block and
     * nothing would say so — the module would be valid, and wrong. Starting at
     * the jump alone gives a different module. */
    uint8_t *from_jump = NULL;
    size_t from_jump_len = 0;
    check(wisq_x86_emit_region(LOOP, sizeof LOOP, GUEST_BASE, 3,
                               &from_jump, &from_jump_len) == 0,
          "l'émetteur traduit aussi depuis une entrée non nulle");
    if (from_jump != NULL) {
        check(from_jump_len != len
                  || memcmp(from_jump, module, len) != 0,
              "et une entrée différente ne rend pas le même module");
        wisq_x86_free_module(from_jump, from_jump_len);
    }

    wisq_x86_free_module(module, len);

    /* A refusal is an outcome, and it must not hand back a buffer to free. */
    uint8_t *refused = (uint8_t *)1;
    size_t refused_len = 1;
    check(wisq_x86_emit_region(INVALID, sizeof INVALID, GUEST_BASE, 0,
                               &refused, &refused_len) == -1,
          "une région indécodable est refusée");
    check(refused == (uint8_t *)1 && refused_len == 1,
          "et un refus ne touche pas aux sorties de l'appelant");

    check(wisq_x86_emit_region(NULL, 4, GUEST_BASE, 0, &refused, &refused_len) == -1,
          "un pointeur nul est refusé plutôt que déréférencé");
    check(wisq_x86_emit_region(LOOP, sizeof LOOP, GUEST_BASE, 0, NULL, &refused_len) == -1,
          "une sortie nulle aussi");

    /* Freeing nothing is not a crash: the caller may not know which of the two
     * happened, and the machine side already promises this for snapshots. */
    wisq_x86_free_module(NULL, 0);

    if (failures == 0) {
        printf("traducteur x86 : l'en-tête décrit la bibliothèque qu'il déclare\n");
        return 0;
    }
    printf("%d vérification(s) en échec\n", failures);
    return 1;
}
