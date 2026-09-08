/*
 * Ce que C voit du lecteur d'image de disque optique.
 *
 * L'en-tête est écrit à la main, et c'est une dette tant que rien ne le
 * vérifie : ce programme se compile contre lui, se lie à la vraie
 * bibliothèque, et lit une image que le harnais Rust vient de graver. Une
 * signature qui dérive de `src/ffi.rs` échoue ici plutôt que sur un téléphone.
 *
 * L'image lui est passée en argument : la fabriquer ici demanderait un
 * troisième constructeur d'ISO — après celui des tests Rust — et trois copies
 * d'un même gréement finissent par ne plus décrire la même chose.
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "wisq_vm.h"

static int failures = 0;

static void check(int condition, const char *what) {
    if (!condition) {
        printf("ÉCHEC : %s\n", what);
        failures++;
    }
}

/* La n-ième chaîne du tampon, ou NULL s'il n'y en a pas tant. */
static const char *field(const uint8_t *bytes, size_t len, size_t wanted) {
    const char *at = (const char *)bytes;
    const char *end = at + len;
    for (size_t rank = 0; at < end; rank++) {
        if (rank == wanted) { return at; }
        at += strlen(at) + 1;
    }
    return NULL;
}

int main(int argc, char **argv) {
    if (argc < 3) {
        printf("usage : iso <image.iso> <destination>\n");
        return 2;
    }
    const char *image = argv[1];
    const char *destination = argv[2];

    /* La recette, telle que l'en-tête la promet : quatre chaînes nulles. */
    uint8_t *bytes = NULL;
    size_t len = 0;
    check(wisq_iso_recipe(image, &bytes, &len) == 0, "la recette se lit");
    if (bytes != NULL) {
        check(field(bytes, len, 0) != NULL && strcmp(field(bytes, len, 0),
                                                     "/boot/syslinux/syslinux.cfg") == 0,
              "le premier champ nomme le fichier d'où elle vient");
        check(field(bytes, len, 1) != NULL && strcmp(field(bytes, len, 1),
                                                     "/boot/vmlinuz-virt") == 0,
              "le deuxième nomme le noyau");
        check(field(bytes, len, 2) != NULL && strcmp(field(bytes, len, 2),
                                                     "/boot/initramfs-virt") == 0,
              "le troisième nomme l'initramfs");
        check(field(bytes, len, 3) != NULL && strcmp(field(bytes, len, 3),
                                                     "modules=loop,squashfs quiet") == 0,
              "le quatrième porte la ligne de commande");
        /* Quatre chaînes, et pas une de plus : le tampon finit sur le nul de
         * la dernière. */
        check(field(bytes, len, 4) == NULL, "il y a exactement quatre champs");
        wisq_x86_free_module(bytes, len);
    }

    /* Ce qui n'est pas une image se refuse, plutôt que de rendre du hasard. */
    uint8_t *refused = NULL;
    size_t refused_len = 0;
    check(wisq_iso_recipe(argv[0], &refused, &refused_len) == -1,
          "un exécutable n'est pas une image");
    check(wisq_iso_recipe(NULL, &refused, &refused_len) == -1, "ni un chemin nul");
    check(wisq_iso_recipe(image, NULL, &refused_len) == -1, "ni une sortie nulle");

    /* L'extraction, et son plafond. */
    check(wisq_iso_extract(image, "/boot/vmlinuz-virt", destination, 1 << 20) == 0,
          "le noyau s'extrait");
    FILE *file = fopen(destination, "rb");
    check(file != NULL, "le fichier extrait existe");
    if (file != NULL) {
        check(fseek(file, 0, SEEK_END) == 0, "il se parcourt");
        long size = ftell(file);
        check(size == 3000, "et il fait la taille du membre, pas celle d'un secteur");
        /* Le premier octet du motif que le harnais a gravé : `n % 251`. */
        check(fseek(file, 0, SEEK_SET) == 0, "il se rembobine");
        int first = fgetc(file);
        int second = fgetc(file);
        check(first == 0 && second == 1, "et ce sont bien ses octets");
        fclose(file);
    }

    /* **Sous le plafond, refus — et refus AVANT d'écrire.** Rendre un début de
     * noyau serait pire que rien : il se charge, et meurt ailleurs. */
    const char *unwritten = "/tmp/wisq-abi-iso-jamais-ecrit";
    remove(unwritten);
    check(wisq_iso_extract(image, "/boot/vmlinuz-virt", unwritten, 2999) == -1,
          "un membre plus gros que le plafond est refusé");
    FILE *never = fopen(unwritten, "rb");
    check(never == NULL, "et rien n'a été écrit");
    if (never != NULL) { fclose(never); remove(unwritten); }

    check(wisq_iso_extract(image, "/boot/ceci-nexiste-pas", destination, 1 << 20) == -1,
          "un membre absent est refusé");
    check(wisq_iso_extract(NULL, "/boot/vmlinuz-virt", destination, 1 << 20) == -1,
          "un chemin nul aussi");

    if (failures > 0) {
        printf("%d vérification(s) en échec\n", failures);
        return 1;
    }
    printf("l'en-tête décrit bien le lecteur d'image\n");
    return 0;
}
