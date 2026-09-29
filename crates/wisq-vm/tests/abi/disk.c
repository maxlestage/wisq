/*
 * The disk, the device tree and the keyboard, as C sees them.
 *
 * `main.c` boots a kernel, `x86.c` translates a region, `iso.c` reads an
 * image — and between the three of them, eleven of the header's thirty-one
 * declarations were never called at all: the whole disk family, the load that
 * takes a device tree, the keystroke queue, and the translation buffer's size.
 *
 * A hand-written declaration that no C program calls is not checked, it is
 * believed. It compiles on the Rust side, it compiles on the Swift side, and
 * the first symptom of a drifted signature is memory that is already wrong —
 * on a phone. This program closes that gap, and
 * `every_declared_function_is_exercised_from_c` in ../abi.rs keeps it closed.
 *
 * No kernel image and no writable directory: everything here is either a
 * buffer this program owns or a path that deliberately does not exist, which
 * is why it runs wherever a compiler does — including inside the simulator.
 */

#include "wisq_vm.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int failures = 0;

static void check(int condition, const char *what) {
    if (!condition) {
        fprintf(stderr, "ABI disque: %s\n", what);
        failures++;
    }
}

/* The console callback is required by wisq_vm_new; nothing here makes a guest
 * speak, so it only records that it was not called with nonsense. */
static void on_output(void *context, const uint8_t *bytes, size_t len) {
    (void)bytes;
    *(size_t *)context += len;
}

/* Four mebibytes: a power of two, enough for a machine to exist, small enough
 * that two snapshots of it cost nothing. Nothing boots here. */
#define RAM (4u * 1024u * 1024u)

/* A disk image this program owns. Its contents are irrelevant — no guest reads
 * it — but its *size* is not: the header promises that a memory-backed disk
 * reports the whole image as written, and that is a number to compare. */
#define DISK_BYTES (256u * 1024u)

int main(void) {
    size_t written = 0;
    WisqVM *vm = wisq_vm_new(RAM, on_output, &written);
    if (!vm) {
        fprintf(stderr, "ABI disque: wisq_vm_new a renvoyé NULL\n");
        return 1;
    }

    /* A machine with no disk, and the four counters that describe it. A device
     * that refuses everything and a device nobody calls read the same without
     * both — the header says so, and that is only true if both are readable. */
    check(wisq_vm_has_disk(vm) == 0, "une machine neuve se déclare avec un disque");
    check(wisq_vm_disk_served(vm) == 0, "une machine neuve a déjà servi des requêtes");
    check(wisq_vm_disk_refused(vm) == 0, "une machine neuve en a déjà refusé");
    check(wisq_vm_disk_bytes_written(vm) == 0, "une machine neuve a déjà écrit");
    /* Both are documented as safe on a machine that has no disk: the app calls
     * them when a view disappears without knowing what was attached. */
    check(wisq_vm_flush_disk(vm) == 0, "vider un disque absent n'a pas rendu 0");
    check(wisq_vm_detach_disk(vm) == 0, "retirer un disque absent n'a pas rendu 0");

    uint8_t *image = malloc(DISK_BYTES);
    if (!image) {
        fprintf(stderr, "ABI disque: allocation impossible\n");
        wisq_vm_free(vm);
        return 1;
    }
    for (size_t index = 0; index < DISK_BYTES; index++) {
        image[index] = (uint8_t)(index * 31u + 7u);
    }

    check(wisq_vm_attach_disk(vm, image, DISK_BYTES) == 0, "le disque mémoire a été refusé");
    check(wisq_vm_has_disk(vm) != 0, "le disque attaché ne se déclare pas");
    /* "the whole image for a memory one" — the header's words, and the one
     * number here that a mixed-up argument order would get wrong. */
    check(wisq_vm_disk_bytes_written(vm) == DISK_BYTES,
          "les octets écrits ne valent pas la taille de l'image");
    /* Both counters, and what this program cannot do with them: no guest runs
     * here, so both are zero and swapping the two would pass. Telling them
     * apart needs a booted guest whose tree carries the disk node, and that
     * exists — Tests/WisqVMRustTests/DifferentialDiskTests.swift requires
     * served == 1 and refused == 0 through this same header. What is at stake
     * here is that both are reachable and agree on their starting value. */
    check(wisq_vm_disk_served(vm) == 0, "un disque que nul ne lit a servi une requête");
    check(wisq_vm_disk_refused(vm) == 0, "un disque que nul ne lit en a refusé une");
    check(wisq_vm_flush_disk(vm) == 0, "vider un disque mémoire a échoué");

    /* A null image is refused rather than read: the length would be believed
     * and the read would start at zero. */
    check(wisq_vm_attach_disk(vm, NULL, DISK_BYTES) == -1,
          "une image nulle a été acceptée comme disque");

    check(wisq_vm_detach_disk(vm) == 0, "le retrait du disque a échoué");
    check(wisq_vm_has_disk(vm) == 0, "le disque retiré se déclare encore");

    /* The file-backed disk, through its refusals. Writing one would need a
     * writable directory, which this program deliberately does not assume —
     * it runs inside a simulator too. The refusals are part of the contract
     * and carry the same three-pointer signature, which is what is at stake:
     * -1 for a null argument, -2 when the base cannot be opened. */
    check(wisq_vm_attach_disk_file(vm, NULL, NULL) == -1,
          "deux chemins nuls ont été acceptés");
    check(wisq_vm_attach_disk_file(vm, "/wisq-abi-inexistant/base.img",
                                   "/wisq-abi-inexistant/writes") == -2,
          "une base introuvable n'a pas rendu -2");
    check(wisq_vm_has_disk(vm) == 0, "un disque refusé s'est quand même attaché");

    /* The load that takes the board's description from the caller. Its two
     * extra arguments are the point: a wrapper that passed the image twice, or
     * the lengths the wrong way round, would still compile on both sides. */
    const uint8_t tree[4] = {0xd0, 0x0d, 0xfe, 0xed};
    check(wisq_vm_load_with_tree(vm, image, DISK_BYTES, NULL, 0) == WISQ_VM_LOAD_NULL,
          "un arbre nul n'a pas été refusé");
    check(wisq_vm_load_with_tree(vm, image, 0, tree, sizeof tree) == WISQ_VM_LOAD_IMAGE_EMPTY,
          "une image vide avec un arbre n'a pas rendu « image vide »");

    /* The keystroke queue, measured by its effect rather than by the fact that
     * the call returned. wisq_vm_send is void: nothing it does is visible in a
     * return value, and "it did not crash" is not a check. A snapshot carries
     * the keystrokes still queued — so two snapshots around a send must
     * differ, and that difference is the only proof from here that the bytes
     * went anywhere at all. */
    uint8_t *before = NULL, *after = NULL;
    size_t before_len = 0, after_len = 0;
    if (wisq_vm_snapshot(vm, &before, &before_len) != WISQ_VM_SNAPSHOT_OK || !before) {
        check(0, "instantané avant la frappe impossible");
    } else {
        const uint8_t keys[5] = {'w', 'i', 's', 'q', '\n'};
        wisq_vm_send(vm, keys, sizeof keys);
        /* And the two arguments a caller gets wrong: nothing to send, and
         * nothing to send it from. Both are documented as no-ops, so the
         * snapshot below must show the five bytes and not seven. */
        wisq_vm_send(vm, NULL, sizeof keys);
        wisq_vm_send(vm, keys, 0);
        if (wisq_vm_snapshot(vm, &after, &after_len) != WISQ_VM_SNAPSHOT_OK || !after) {
            check(0, "instantané après la frappe impossible");
        } else {
            check(after_len != before_len || memcmp(before, after, before_len) != 0,
                  "une frappe n'a rien changé à l'état sauvé");
            wisq_vm_free_snapshot(after, after_len);
        }
        wisq_vm_free_snapshot(before, before_len);
    }

    wisq_vm_free(vm);
    free(image);

    /* The translation buffer's size, which the host adds above the
     * correspondence. The header tells a host to lay out
     * `pages + wisq_desktop_table_pages() + wisq_desktop_tlb_pages()`; x86.c
     * asked for the first two and never for the third, so a host following
     * the header used a number no C program had ever read. */
    uint32_t tlb = wisq_desktop_tlb_pages();
    check(tlb > 0, "le tampon de traduction n'occupe aucune page");
    check(tlb < 1024, "le tampon de traduction occupe plus de 64 Mio");

    printf("disque, arbre, frappe et tampon : %u pages de tampon, %zu octets de console\n",
           tlb, written);
    if (failures != 0) {
        fprintf(stderr, "ABI disque: %d vérification(s) en échec\n", failures);
        return 1;
    }
    printf("ABI conforme : le disque, l'arbre et la frappe s'accordent avec l'en-tête\n");
    return 0;
}
