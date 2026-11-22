/*
 * La machine PC native, telle qu'un appelant C la mène.
 *
 * `include/wisq_vm.h` est écrit à la main : une signature qui dériverait de
 * src/ffi.rs ne serait ni une erreur Rust ni une erreur Swift, mais un appel
 * faux à l'exécution. Ce programme appelle chaque fonction `wisq_pc_*`, juge
 * ce qu'elle rend, et le dit en français.
 *
 * Il reçoit six petits noyaux, gravés par tests/abi.rs : le noyau factice
 * (sa bannière, sa ligne, cinq battements, « FIN »), une boucle sans fin, un
 * `ud2` sans IDT, l'impulsion de remise à zéro de l'i8042, le pilote réseau
 * minimal (une trame émise, une trame reçue sur son propre code) et le
 * pilote disque minimal (1 024 octets lus à partir du secteur 7, écrits au
 * port série, puis le statut) ; puis un dossier où poser un disque.
 *
 *   cc -I include tests/abi/pc.c -L <libdir> -lwisq_vm -lpthread -o pc
 *   ./pc factice.bin boucle.bin faute.bin remise.bin reseau.bin disque.bin <dossier>
 */

#include "wisq_vm.h"

#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <math.h>

static int failures = 0;

static void check(int condition, const char *what) {
    if (!condition) {
        fprintf(stderr, "ABI pc : %s\n", what);
        failures++;
    }
}

/* La console de l'invité, recueillie. */
typedef struct {
    char bytes[65536];
    size_t len;
} Console;

static void on_output(void *context, const uint8_t *bytes, size_t len) {
    Console *console = context;
    size_t room = sizeof(console->bytes) - 1 - console->len;
    if (len > room) len = room;
    memcpy(console->bytes + console->len, bytes, len);
    console->len += len;
    console->bytes[console->len] = 0;
}

typedef struct {
    uint8_t *bytes;
    size_t len;
} File;

static File read_file(const char *path) {
    File file = {NULL, 0};
    FILE *handle = fopen(path, "rb");
    if (!handle) return file;
    fseek(handle, 0, SEEK_END);
    long size = ftell(handle);
    fseek(handle, 0, SEEK_SET);
    file.bytes = malloc((size_t)size);
    file.len = fread(file.bytes, 1, (size_t)size, handle);
    fclose(handle);
    return file;
}

#define RAM (128ull << 20)

/* Une machine sans écran, l'heure figée, son noyau chargé. */
static WisqPC *booted(const File *kernel, const char *line, Console *console) {
    WisqPC *pc = wisq_pc_new(RAM, on_output, console);
    if (!pc) return NULL;
    check(wisq_pc_set_time(pc, 1795230600) == 0, "wisq_pc_set_time rend 0");
    check(wisq_pc_load(pc, kernel->bytes, kernel->len, line, NULL, 0) == 0,
          "le noyau se charge");
    return pc;
}

/* Le lecteur d'une base que l'appelant traduit : ici une image en mémoire,
 * qui compte ses lectures et ses lâchers. */
typedef struct {
    uint8_t bytes[8192];
    uint64_t size;
    int reads;
    int outside;
    int released;
    uint64_t broken; /* un octet que le lecteur ne sait pas rendre, ou 0 */
} Reader;

static int reader_read(void *context, uint64_t offset, uint8_t *buffer, size_t length) {
    Reader *reader = context;
    reader->reads++;
    if (offset > reader->size || length > reader->size - offset) {
        reader->outside++;
        return 0;
    }
    if (reader->broken && offset <= reader->broken && reader->broken < offset + length) return 0;
    memcpy(buffer, reader->bytes + offset, length);
    return 1;
}

static void reader_release(void *context) {
    ((Reader *)context)->released++;
}

/* Une machine dont le premier disque est lu par `reader`, sa couche dans
 * `writes`, le noyau factice chargé ; NULL si le branchement est refusé. */
static WisqPC *with_reader(const File *kernel, Reader *reader, const char *writes, Console *console) {
    WisqPC *pc = wisq_pc_new(RAM, console ? on_output : NULL, console);
    if (!pc) return NULL;
    check(wisq_pc_set_time(pc, 1795230600) == 0, "wisq_pc_set_time rend 0");
    if (wisq_pc_attach_disk_reader(pc, 0, reader->size, reader_read, reader_release, reader, writes) != 0) {
        wisq_pc_free(pc);
        return NULL;
    }
    check(wisq_pc_load(pc, kernel->bytes, kernel->len, "x=y", NULL, 0) == 0, "le noyau se charge");
    return pc;
}

/* Le fil qui arrête une course sans fin. */
typedef struct {
    WisqPC *pc;
    int progress_seen;
} Stopper;

static void pause_ms(long milliseconds) {
    struct timespec wait = {milliseconds / 1000, (milliseconds % 1000) * 1000000L};
    nanosleep(&wait, NULL);
}

static void *stop_later(void *argument) {
    Stopper *stopper = argument;
    uint64_t retired = 0, rip = 0;
    /* L'avancement se lit pendant la course, de ce fil-ci. */
    for (int tries = 0; tries < 200 && !stopper->progress_seen; tries++) {
        pause_ms(5);
        if (wisq_pc_progress(stopper->pc, &retired, &rip) == 1 && retired > 0)
            stopper->progress_seen = 1;
    }
    /* Taper et toucher pendant la course : rien ne doit casser. */
    wisq_pc_send(stopper->pc, (const uint8_t *)"x", 1);
    const uint8_t a[] = {0x1E, 0x9E};
    (void)wisq_pc_keys(stopper->pc, a, sizeof a);
    (void)wisq_pc_keys_pending(stopper->pc);
    wisq_pc_mouse(stopper->pc, 1, 1, 0);
    wisq_pc_stop(stopper->pc);
    return NULL;
}

int main(int argc, char **argv) {
    if (argc < 8) {
        fprintf(stderr, "usage : pc factice boucle faute remise reseau disque dossier\n");
        return 2;
    }
    File factice = read_file(argv[1]);
    File boucle = read_file(argv[2]);
    File faute = read_file(argv[3]);
    File remise = read_file(argv[4]);
    File reseau = read_file(argv[5]);
    File disque = read_file(argv[6]);
    const char *folder = argv[7];
    if (!factice.len || !boucle.len || !faute.len || !remise.len || !reseau.len || !disque.len) {
        fprintf(stderr, "ABI pc : un noyau illisible\n");
        return 2;
    }

    /* --- Un pointeur nul ne fait rien casser, et le dit. --- */
    WisqPCDisplay display;
    uint64_t a64 = 0, b64 = 0;
    uint8_t *snapshot = NULL;
    size_t snapshot_len = 0;
    check(wisq_pc_set_time(NULL, 0) == -1, "set_time(NULL)");
    check(wisq_pc_seed(NULL, 0) == -1, "seed(NULL)");
    check(wisq_pc_attach_display(NULL, 1, 1) == -1, "attach_display(NULL)");
    check(wisq_pc_attach_disk(NULL, (const uint8_t *)"", 0) == -1, "attach_disk(NULL)");
    check(wisq_pc_attach_disk_file(NULL, "a", "b") == -1, "attach_disk_file(NULL)");
    check(wisq_pc_attach_second_disk_file(NULL, "a", "b") == -1, "attach_second_disk_file(NULL)");
    check(wisq_pc_load(NULL, factice.bytes, factice.len, NULL, NULL, 0) == -1, "load(NULL)");
    check(wisq_pc_run(NULL, 1) == -1, "run(NULL)");
    check(wisq_pc_fault(NULL, NULL, 0) == 0, "fault(NULL)");
    wisq_pc_send(NULL, (const uint8_t *)"x", 1);
    check(wisq_pc_keys(NULL, (const uint8_t *)"\x1e", 1) == -1, "keys(NULL)");
    check(wisq_pc_keys_pending(NULL) == 0, "keys_pending(NULL)");
    wisq_pc_keys_abandon(NULL);
    wisq_pc_mouse(NULL, 0, 0, 0);
    check(wisq_pc_touch(NULL, 0.5, 0.5, 0) == -1, "touch(NULL)");
    check(wisq_pc_scroll(NULL, 1) == -1, "scroll(NULL)");
    check(wisq_pc_display(NULL, &display) == -1, "display(NULL)");
    check(wisq_pc_display_copy(NULL, NULL, 0, NULL) == -1, "display_copy(NULL)");
    wisq_pc_stop(NULL);
    check(wisq_pc_retired(NULL) == 0, "retired(NULL)");
    check(wisq_pc_progress(NULL, &a64, &b64) == -1, "progress(NULL)");
    check(wisq_pc_guest_time(NULL) == 0, "guest_time(NULL)");
    check(wisq_pc_guest_hertz(NULL) == 0, "guest_hertz(NULL)");
    check(wisq_pc_halted(NULL) == 0, "halted(NULL)");
    wisq_pc_elapse(NULL, 1.0);
    check(wisq_pc_snapshot(NULL, &snapshot, &snapshot_len) == -1, "snapshot(NULL)");
    wisq_pc_free_snapshot(NULL, 0);
    check(wisq_pc_restore(NULL, (const uint8_t *)"", 0) == -1, "restore(NULL)");
    check(wisq_pc_flush_disks(NULL) == -1, "flush_disks(NULL)");
    check(wisq_pc_disk_bytes_written(NULL) == 0, "disk_bytes_written(NULL)");
    check(wisq_pc_disk_activity(NULL, &a64, &b64) == -1, "disk_activity(NULL)");
    WisqPCNetwork network;
    uint8_t frame[WISQ_PC_FRAME_MAX];
    check(wisq_pc_attach_network(NULL, NULL) == -1, "attach_network(NULL)");
    check(wisq_pc_net_take(NULL, frame, sizeof frame) == 0, "net_take(NULL)");
    check(wisq_pc_net_give(NULL, frame, 60) == -1, "net_give(NULL)");
    check(wisq_pc_net_stats(NULL, &network) == -1, "net_stats(NULL)");
    wisq_pc_free(NULL);

    /* --- Une machine neuve, avant son noyau. --- */
    Console console = {{0}, 0};
    WisqPC *pc = wisq_pc_new(0, on_output, &console);
    if (!pc) {
        fprintf(stderr, "ABI pc : wisq_pc_new a rendu NULL\n");
        return 1;
    }
    check(wisq_pc_run(pc, 1000) == WISQ_PC_NOT_READY, "une course sans noyau est refusée");
    check(wisq_pc_snapshot(pc, &snapshot, &snapshot_len) == -2, "un instantané sans noyau est refusé");
    check(wisq_pc_progress(pc, &a64, &b64) == 0, "rien de publié avant la première course");
    check(wisq_pc_display(pc, &display) == -2, "pas d'écran avant d'en brancher un");
    check(wisq_pc_touch(pc, 0.5, 0.5, 1) == 0, "pas de toucher sans écran");
    check(wisq_pc_disk_activity(pc, &a64, &b64) == 0, "pas d'activité sans disque");
    check(wisq_pc_guest_hertz(pc) == 288ull * 1193182ull, "une seconde de l'invité vaut 288 × 1 193 182 instructions");

    /* L'écran : refusé nul, branché une fois, puis refusé. */
    check(wisq_pc_attach_display(pc, 0, 768) == -4, "un écran de largeur nulle est refusé");
    check(wisq_pc_attach_display(pc, 4096, 4096) == -4, "un écran de 64 Mio est refusé");
    check(wisq_pc_attach_display(pc, 1024, 768) == 0, "l'écran se branche");
    check(wisq_pc_attach_display(pc, 800, 600) == -3, "un second écran est refusé");
    check(wisq_pc_display(pc, &display) == 0, "l'écran se lit");
    check(display.memory != NULL && display.memory_size == 16u << 20, "la mémoire vidéo : seize mébioctets");
    check(display.width == 1024 && display.height == 768 && display.bytes_per_row == 4096 &&
              display.start == 0,
          "le mode du démarrage est celui de l'écran branché");
    const uint8_t *memory = display.memory;
    WisqPCDisplay copied;
    memset(&copied, 0, sizeof copied);
    uint8_t tiny[16];
    check(wisq_pc_display_copy(pc, tiny, sizeof tiny, &copied) == -3,
          "une copie dans un tampon trop court est refusée");
    check(copied.width == 1024 && copied.height == 768, "et dit la taille qu'il faut");
    size_t image_bytes = (size_t)copied.width * copied.height * 4;
    uint8_t *image = malloc(image_bytes);
    check(wisq_pc_display_copy(pc, image, image_bytes, NULL) == 0, "l'image se copie");
    check(wisq_pc_touch(pc, 0.5, 0.5, 1) == 0, "la tablette n'est pas encore prise");
    check(wisq_pc_scroll(pc, 1) == 0, "la molette non plus");

    /* Les disques. */
    check(wisq_pc_attach_disk(pc, (const uint8_t *)"court", 5) == -3, "un disque de moins d'un secteur est refusé");
    char base[4096], writes[4096], second[4096], second_writes[4096];
    snprintf(base, sizeof base, "%s/disque.img", folder);
    snprintf(writes, sizeof writes, "%s/disque.couche", folder);
    snprintf(second, sizeof second, "%s/second.img", folder);
    snprintf(second_writes, sizeof second_writes, "%s/second.couche", folder);
    check(wisq_pc_attach_disk_file(pc, base, writes) == -2, "une base absente est refusée");
    FILE *disk = fopen(base, "wb");
    FILE *other = fopen(second, "wb");
    static uint8_t sector[4096];
    fwrite(sector, 1, sizeof sector, disk);
    fwrite(sector, 1, sizeof sector, other);
    fclose(disk);
    fclose(other);
    check(wisq_pc_attach_disk_file(pc, base, writes) == 0, "le disque sur fichier se branche");
    check(wisq_pc_attach_second_disk_file(pc, second, second_writes) == 0, "le second aussi");
    check(wisq_pc_disk_activity(pc, &a64, &b64) == 1 && a64 == 0 && b64 == 0,
          "un disque branché, rien de servi");
    check(wisq_pc_disk_bytes_written(pc) == 0, "rien d'écrit");
    check(wisq_pc_flush_disks(pc) == 0, "vider les disques");

    /* Le chargement : ses refus, puis le noyau. */
    check(wisq_pc_load(pc, (const uint8_t *)"pas un noyau", 12, NULL, NULL, 0) == -3,
          "ce qui n'est pas un noyau est refusé");
    check(wisq_pc_load(pc, factice.bytes, factice.len, "\xff\xfe", NULL, 0) == -2,
          "une ligne qui n'est pas de l'UTF-8 est refusée");
    check(wisq_pc_load(pc, factice.bytes, factice.len / 2, NULL, NULL, 0) == -7,
          "un noyau tronqué est refusé");
    check(wisq_pc_set_time(pc, 1795230600) == 0, "l'heure se fige");
    check(wisq_pc_seed(pc, 42) == 0, "la graine se pose");
    check(wisq_pc_load(pc, factice.bytes, factice.len, "a=b", NULL, 0) == 0, "le noyau factice se charge");
    check(wisq_pc_load(pc, factice.bytes, factice.len, "a=b", NULL, 0) == -8, "pas deux fois");
    check(wisq_pc_attach_display(pc, 1024, 768) == -2, "plus d'écran une fois chargée");
    check(wisq_pc_attach_disk(pc, sector, sizeof sector) == -2, "plus de disque une fois chargée");
    check(wisq_pc_attach_disk_file(pc, base, writes) == -7, "ni sur fichier");
    /* Refusé avant d'ouvrir quoi que ce soit : la couche d'un branchement
     * refusé n'est pas créée sur le disque. */
    char refused[4096], refused_map[4096];
    snprintf(refused, sizeof refused, "%s/tard.couche", folder);
    snprintf(refused_map, sizeof refused_map, "%s/tard.couche.map", folder);
    check(wisq_pc_attach_second_disk_file(pc, second, refused) == -7, "ni en second disque");
    check(access(refused, F_OK) != 0 && access(refused_map, F_OK) != 0,
          "et la couche d'un branchement refusé n'est pas créée");

    /* Les frappes : leurs refus, leur file, leur annulation. */
    const uint8_t alone[] = {0xE0};
    const uint8_t pause_key[] = {0xE1, 0x1D, 0x45};
    const uint8_t zero[] = {0x00};
    const uint8_t up[] = {0xE0, 0x48, 0xE0, 0xC8};
    check(wisq_pc_keys(pc, alone, sizeof alone) == -2, "un E0 seul est refusé");
    check(wisq_pc_keys(pc, pause_key, sizeof pause_key) == -2, "E1 est refusé");
    check(wisq_pc_keys(pc, zero, sizeof zero) == -2, "le code nul est refusé");
    check(wisq_pc_keys_pending(pc) == 0, "et rien n'est entré");
    check(wisq_pc_keys(pc, up, sizeof up) == 1, "la flèche du haut est admise");
    check(wisq_pc_keys_pending(pc) == 2, "deux frappes attendent");
    wisq_pc_keys_abandon(pc);
    check(wisq_pc_keys_pending(pc) == 0, "l'annulation les jette");

    /* La course : la console, l'extinction, les compteurs. */
    int outcome = wisq_pc_run(pc, 50000000);
    check(outcome == WISQ_PC_POWER_OFF, "le noyau factice s'éteint");
    check(strncmp(console.bytes,
                  "wisq-noyau-factice\nconsole=tty0 a=b\n.....\nFIN\n", console.len) == 0 &&
              console.len == strlen("wisq-noyau-factice\nconsole=tty0 a=b\n.....\nFIN\n"),
          "la console est celle du noyau factice, console=tty0 devant sa ligne sous un écran");
    uint64_t retired = wisq_pc_retired(pc);
    check(retired > 100 && retired < 100000, "des instructions retirées");
    check(wisq_pc_progress(pc, &a64, &b64) == 1 && a64 == retired, "l'avancement publié est celui de la fin");
    check(wisq_pc_guest_time(pc) > retired, "l'invité a dormi : son temps dépasse ses instructions");
    check(wisq_pc_halted(pc) == 1, "éteint sur hlt");
    check(wisq_pc_fault(pc, NULL, 0) == 0, "aucune faute");
    check(wisq_pc_display(pc, &display) == 0 && display.memory == memory,
          "la mémoire vidéo n'a pas bougé");
    check(wisq_pc_run(pc, 1000) == WISQ_PC_POWER_OFF, "éteinte, elle le reste");
    free(image);
    wisq_pc_free(pc);

    /* --- L'instantané : à mi-course, repris ailleurs, il finit pareil. --- */
    Console whole = {{0}, 0};
    WisqPC *reference = booted(&factice, "x=y", &whole);
    check(reference && wisq_pc_run(reference, 50000000) == WISQ_PC_POWER_OFF, "la course de référence");
    uint64_t reference_retired = wisq_pc_retired(reference);

    Console first = {{0}, 0};
    WisqPC *cut = booted(&factice, "x=y", &first);
    /* Cinq battements d'une milliseconde : 1,7 million d'instructions de son
     * temps. Un million en coupe la course entre deux points. */
    check(wisq_pc_run(cut, 1000000) == WISQ_PC_BUDGET, "la course coupée rend au budget");
    size_t cut_at = first.len;
    check(wisq_pc_snapshot(cut, &snapshot, &snapshot_len) == 0 && snapshot && snapshot_len > 8,
          "l'instantané se prend");
    check(memcmp(snapshot, "WISQPC\r\n", 8) == 0, "il commence par son nom");
    check(snapshot_len < (RAM / 8), "les pages nulles n'y sont pas");

    Console second_half = {{0}, 0};
    WisqPC *resumed = wisq_pc_new(RAM, on_output, &second_half);
    check(wisq_pc_run(resumed, 1) == WISQ_PC_NOT_READY, "rien à faire tourner avant la reprise");
    check(wisq_pc_restore(resumed, (const uint8_t *)"autre chose", 11) == -2, "pas un instantané");
    uint8_t *altered = malloc(snapshot_len);
    memcpy(altered, snapshot, snapshot_len);
    check(snapshot[8] == 2, "la version 2, qui porte la carte");
    altered[8] = 3; /* la version */
    check(wisq_pc_restore(resumed, altered, snapshot_len) == -3, "une version inconnue est refusée");
    altered[8] = 1;
    check(wisq_pc_restore(resumed, altered, snapshot_len) == -7, "la version 1, sans la carte, est refusée");
    check(wisq_pc_restore(resumed, snapshot, snapshot_len - 1) == -4, "un instantané tronqué est refusé");
    free(altered);
    WisqPC *bigger = wisq_pc_new(RAM * 2, NULL, NULL);
    check(wisq_pc_restore(bigger, snapshot, snapshot_len) == -5, "une autre RAM est refusée");
    wisq_pc_free(bigger);
    WisqPC *screened = wisq_pc_new(RAM, NULL, NULL);
    check(wisq_pc_attach_display(screened, 640, 480) == 0, "un écran");
    check(wisq_pc_restore(screened, snapshot, snapshot_len) == -6, "un autre écran est refusé");
    wisq_pc_free(screened);
    /* Un disque branché là où l'instantané n'en avait pas. */
    WisqPC *disked = wisq_pc_new(RAM, NULL, NULL);
    check(wisq_pc_attach_disk(disked, sector, sizeof sector) == 0, "un disque");
    check(wisq_pc_restore(disked, snapshot, snapshot_len) == -8, "d'autres disques sont refusés");
    wisq_pc_free(disked);
    check(wisq_pc_restore(resumed, snapshot, snapshot_len) == 0, "la reprise");
    wisq_pc_free_snapshot(snapshot, snapshot_len);
    check(wisq_pc_retired(resumed) == wisq_pc_retired(cut), "le compteur repris");
    check(wisq_pc_run(resumed, 50000000) == WISQ_PC_POWER_OFF, "la machine reprise s'éteint");
    check(wisq_pc_run(cut, 50000000) == WISQ_PC_POWER_OFF, "l'originale aussi");
    check(wisq_pc_retired(resumed) == reference_retired && wisq_pc_retired(cut) == reference_retired,
          "les trois retirent les mêmes instructions");
    check(cut_at > 0 && second_half.len > 0, "chaque moitié a dit quelque chose");
    check(cut_at + second_half.len == whole.len &&
              memcmp(first.bytes, whole.bytes, cut_at) == 0 &&
              memcmp(second_half.bytes, whole.bytes + cut_at, second_half.len) == 0,
          "la console coupée puis reprise est celle d'une course entière");
    check(strcmp(first.bytes, whole.bytes) == 0, "l'originale, continuée, aussi");
    wisq_pc_free(reference);
    wisq_pc_free(cut);
    wisq_pc_free(resumed);

    /* --- Un disque dont la base est lue par l'appelant (un qcow2, côté
     * Swift) : chaque refus lâche le lecteur tout de suite, une fois ; le
     * disque branché le garde jusqu'à wisq_pc_free ; l'instantané le dit
     * « ailleurs », comme un disque sur fichier. --- */
    {
        static Reader reader, other;
        memset(&reader, 0, sizeof reader);
        reader.size = sizeof reader.bytes;
        char couche[4096], couche_map[4096];
        snprintf(couche, sizeof couche, "%s/lu.couche", folder);
        snprintf(couche_map, sizeof couche_map, "%s/lu.couche.map", folder);
        check(wisq_pc_attach_disk_reader(NULL, 0, 8192, reader_read, reader_release, &reader, couche) == -1 &&
                  reader.released == 1,
              "attach_disk_reader(NULL) refuse et lâche le lecteur");
        WisqPC *lone = wisq_pc_new(RAM, NULL, NULL);
        check(wisq_pc_attach_disk_reader(lone, 0, 8192, NULL, reader_release, &reader, couche) == -1 &&
                  reader.released == 2,
              "sans read : refusé, lâché");
        check(wisq_pc_attach_disk_reader(lone, 0, 8192, NULL, NULL, &reader, couche) == -1,
              "ni read ni release : refusé");
        check(wisq_pc_attach_disk_reader(lone, 2, 8192, reader_read, reader_release, &reader, couche) == -1 &&
                  reader.released == 3,
              "un troisième disque n'existe pas");
        check(wisq_pc_attach_disk_reader(lone, 0, 8192, reader_read, reader_release, &reader, NULL) == -1 &&
                  reader.released == 4,
              "sans couche : refusé");
        check(wisq_pc_attach_disk_reader(lone, 1, 511, reader_read, reader_release, &reader, couche) == -3 &&
                  reader.released == 5,
              "moins d'un secteur");
        check(access(couche, F_OK) != 0 && access(couche_map, F_OK) != 0,
              "et aucune couche n'est créée pour un refus");
        check(reader.reads == 0, "aucun refus ne lit la base");
        wisq_pc_free(lone);

        reader.released = 0;
        for (size_t i = 0; i < sizeof reader.bytes; i++) reader.bytes[i] = (uint8_t)(i * 7 + i / 512);
        WisqPC *read_pc = with_reader(&factice, &reader, couche, NULL);
        check(read_pc != NULL, "le disque lu par l'appelant se branche");
        check(reader.released == 0, "branché, il n'est pas lâché");
        check(access(couche, F_OK) == 0 && access(couche_map, F_OK) == 0, "sa couche est créée");
        char tard[4096], tard_map[4096];
        snprintf(tard, sizeof tard, "%s/lu-tard.couche", folder);
        snprintf(tard_map, sizeof tard_map, "%s/lu-tard.couche.map", folder);
        check(wisq_pc_attach_disk_reader(read_pc, 1, 8192, reader_read, reader_release, &other, tard) == -7 &&
                  other.released == 1,
              "plus de disque une fois chargée, et le lecteur refusé est lâché");
        check(access(tard, F_OK) != 0 && access(tard_map, F_OK) != 0,
              "sans créer la couche d'un branchement refusé");
        check(wisq_pc_disk_bytes_written(read_pc) == 0 && wisq_pc_flush_disks(read_pc) == 0,
              "rien d'écrit, et la couche se scelle");
        check(wisq_pc_run(read_pc, 1000000) == WISQ_PC_BUDGET, "la course coupée");
        uint8_t *taken = NULL;
        size_t taken_len = 0;
        check(wisq_pc_snapshot(read_pc, &taken, &taken_len) == 0 && taken, "son instantané se prend");
        check(taken_len < 1u << 20, "sans les octets du disque : ils vivent ailleurs");

        /* La reprise : sur un disque lu de la même taille, oui ; d'une autre
         * taille, ou en mémoire, non. */
        static Reader same;
        memcpy(&same, &reader, sizeof same);
        same.released = 0;
        WisqPC *again = wisq_pc_new(RAM, NULL, NULL);
        check(wisq_pc_attach_disk_reader(again, 0, same.size, reader_read, reader_release, &same, couche) == 0,
              "le même disque, rebranché");
        check(wisq_pc_restore(again, taken, taken_len) == 0, "se reprend");
        check(wisq_pc_run(again, 50000000) == WISQ_PC_POWER_OFF, "et finit sa course");
        wisq_pc_free(again);
        check(same.released == 1, "lâché avec la machine");

        static Reader smaller;
        memset(&smaller, 0, sizeof smaller);
        smaller.size = 4096;
        char autre[4096];
        snprintf(autre, sizeof autre, "%s/lu-autre.couche", folder);
        WisqPC *shrunk = wisq_pc_new(RAM, NULL, NULL);
        check(wisq_pc_attach_disk_reader(shrunk, 0, smaller.size, reader_read, reader_release, &smaller, couche) ==
                  -5 && smaller.released == 1,
              "la couche d'un disque de huit mille octets refuse un disque de quatre mille");
        check(wisq_pc_attach_disk_reader(shrunk, 0, smaller.size, reader_read, reader_release, &smaller, autre) == 0,
              "sur sa propre couche, il se branche");
        check(wisq_pc_restore(shrunk, taken, taken_len) == -8, "mais ne reprend pas l'instantané d'un autre disque");
        wisq_pc_free(shrunk);
        check(smaller.released == 2, "lâché avec la machine");
        WisqPC *in_memory = wisq_pc_new(RAM, NULL, NULL);
        check(wisq_pc_attach_disk(in_memory, reader.bytes, sizeof reader.bytes) == 0, "le même disque, en mémoire");
        check(wisq_pc_restore(in_memory, taken, taken_len) == -8, "n'est pas celui qui vivait ailleurs");
        wisq_pc_free(in_memory);
        wisq_pc_free_snapshot(taken, taken_len);

        check(wisq_pc_run(read_pc, 50000000) == WISQ_PC_POWER_OFF, "l'originale finit sa course");
        check(reader.outside == 0 && same.outside == 0, "rien n'a été demandé hors du disque");
        wisq_pc_free(read_pc);
        check(reader.released == 1, "le lecteur est lâché une fois, avec la machine");

        /* Le pilote disque lit à travers le lecteur : les 1 024 octets du
         * secteur 7, puis « 0 » ; un octet que le lecteur ne sait pas rendre
         * fait une erreur d'entrée-sortie, « 1 ». */
        for (int broken = 0; broken < 2; broken++) {
            static Reader guest_reader;
            memcpy(&guest_reader, &reader, sizeof guest_reader);
            guest_reader.released = 0;
            guest_reader.reads = 0;
            guest_reader.broken = broken ? 7 * 512 + 700 : 0;
            char lue[4096];
            snprintf(lue, sizeof lue, "%s/lu-invite-%d.couche", folder, broken);
            static Console said;
            memset(&said, 0, sizeof said);
            WisqPC *guest = with_reader(&disque, &guest_reader, lue, &said);
            check(guest && wisq_pc_run(guest, 50000000) == WISQ_PC_POWER_OFF, "le pilote disque s'éteint");
            check(said.len == 1025, "1 024 octets et le statut");
            check(said.bytes[1024] == (broken ? '1' : '0'),
                  broken ? "ce que le lecteur ne rend pas est une erreur pour l'invité" : "lu");
            if (!broken)
                check(memcmp(said.bytes, guest_reader.bytes + 7 * 512, 1024) == 0,
                      "l'invité lit ce que le lecteur rend");
            check(guest_reader.reads == 1, "un seul appel pour 1 024 octets");
            wisq_pc_free(guest);
            check(guest_reader.released == 1, "lâché avec la machine");
        }

        /* Le second disque est le second : l'instantané d'une machine dont
         * le seul disque lu est vdb ne se reprend pas là où il est vda. */
        static Reader as_second, as_first, again_second;
        memcpy(&as_second, &reader, sizeof as_second);
        char seconde[4096];
        snprintf(seconde, sizeof seconde, "%s/lu-second.couche", folder);
        WisqPC *second_pc = wisq_pc_new(RAM, NULL, NULL);
        check(wisq_pc_attach_disk_reader(second_pc, 1, 8192, reader_read, reader_release, &as_second, seconde) == 0,
              "un disque lu, en second");
        check(wisq_pc_load(second_pc, factice.bytes, factice.len, NULL, NULL, 0) == 0, "chargée");
        check(wisq_pc_run(second_pc, 1000000) == WISQ_PC_BUDGET, "coupée");
        uint8_t *second_snapshot = NULL;
        size_t second_len = 0;
        check(wisq_pc_snapshot(second_pc, &second_snapshot, &second_len) == 0, "son instantané");
        memcpy(&as_first, &reader, sizeof as_first);
        WisqPC *first_pc = wisq_pc_new(RAM, NULL, NULL);
        check(wisq_pc_attach_disk_reader(first_pc, 0, 8192, reader_read, reader_release, &as_first, seconde) == 0,
              "le même, en premier");
        check(wisq_pc_restore(first_pc, second_snapshot, second_len) == -8, "n'est pas le même branchement");
        memcpy(&again_second, &reader, sizeof again_second);
        WisqPC *again_pc = wisq_pc_new(RAM, NULL, NULL);
        check(wisq_pc_attach_disk_reader(again_pc, 1, 8192, reader_read, reader_release, &again_second, seconde) ==
                  0,
              "le même, en second");
        check(wisq_pc_restore(again_pc, second_snapshot, second_len) == 0, "se reprend");
        wisq_pc_free_snapshot(second_snapshot, second_len);
        wisq_pc_free(second_pc);
        wisq_pc_free(first_pc);
        wisq_pc_free(again_pc);
    }

    /* --- Le temps passé dehors : payé pendant le sommeil, hors du temps. --- */
    Console late = {{0}, 0};
    WisqPC *elapsed = booted(&factice, "x=y", &late);
    wisq_pc_elapse(elapsed, -5.0);
    wisq_pc_elapse(elapsed, NAN);
    wisq_pc_elapse(elapsed, 30.0);
    check(wisq_pc_run(elapsed, 50000000) == WISQ_PC_POWER_OFF, "avec du temps à rattraper, il s'éteint");
    check(strcmp(late.bytes, whole.bytes) == 0, "et dit la même chose");
    wisq_pc_free(elapsed);

    /* --- Une course sans fin, arrêtée d'un autre fil. --- */
    Console none = {{0}, 0};
    WisqPC *looping = booted(&boucle, NULL, &none);
    wisq_pc_stop(looping);
    check(wisq_pc_run(looping, UINT64_MAX) == WISQ_PC_STOPPED, "un arrêt demandé avant la course la fait rendre");
    check(wisq_pc_run(looping, 1000000) == WISQ_PC_BUDGET, "consommé, il ne l'arrête plus");
    Stopper stopper = {looping, 0};
    pthread_t thread;
    pthread_create(&thread, NULL, stop_later, &stopper);
    outcome = wisq_pc_run(looping, UINT64_MAX);
    pthread_join(thread, NULL);
    check(outcome == WISQ_PC_STOPPED, "arrêtée d'un autre fil");
    check(stopper.progress_seen, "l'avancement s'est lu pendant la course");
    check(wisq_pc_halted(looping) == 0, "une boucle n'est pas un hlt");
    wisq_pc_free(looping);

    /* --- Le réseau : une trame émise sort, une trame remise entre. --- */
    Console wire = {{0}, 0};
    WisqPC *net = wisq_pc_new(RAM, on_output, &wire);
    const uint8_t code_frame[60] = {0xB8, 'R', 0x00, 0x00, 0x00, 0xC3};
    check(wisq_pc_net_give(net, code_frame, sizeof code_frame) == -3, "rien n'entre sans carte");
    check(wisq_pc_net_stats(net, &network) == 0, "pas de compteurs sans carte");
    check(wisq_pc_net_take(net, frame, sizeof frame) == 0, "rien ne sort sans carte");
    /* Une adresse qui n'est pas celle par défaut : le pilote la lit dans la
     * configuration de la carte, et la met en source de sa trame. */
    const uint8_t mac[6] = {0x02, 0x00, 0x5E, 0x10, 0x20, 0x2A};
    check(wisq_pc_attach_network(net, mac) == 0, "la carte réseau se branche");
    check(wisq_pc_attach_network(net, NULL) == -3, "une seule carte");
    check(wisq_pc_net_stats(NULL, NULL) == -1 && wisq_pc_net_stats(net, NULL) == -1, "stats sans sortie");
    check(wisq_pc_net_give(net, NULL, 60) == -1, "une trame nulle");
    check(wisq_pc_net_give(net, code_frame, 0) == -2, "une trame vide n'est pas une trame");
    static uint8_t huge[WISQ_PC_FRAME_MAX + 1];
    check(wisq_pc_net_give(net, huge, sizeof huge) == -2, "ni une trame de 1 515 octets");
    check(wisq_pc_set_time(net, 1795230600) == 0, "l'heure");
    check(wisq_pc_load(net, reseau.bytes, reseau.len, NULL, NULL, 0) == 0, "le pilote réseau se charge");
    check(wisq_pc_attach_network(net, NULL) == -2, "plus de carte une fois chargée");
    check(wisq_pc_run(net, 1000000) == WISQ_PC_BUDGET, "il attend sa trame");
    check(wire.len == 1 && wire.bytes[0] == 'o', "le code d'avant a dit « o »");
    /* La trame émise : sa longueur d'abord, sans la prendre, puis elle. */
    size_t sent = wisq_pc_net_take(net, NULL, 0);
    check(sent == 61, "la trame émise fait 61 octets");
    check(wisq_pc_net_take(net, frame, 10) == sent, "un tampon trop court dit la longueur");
    check(wisq_pc_net_take(net, frame, sizeof frame) == sent, "et la trame se prend");
    check(memcmp(frame, "\xff\xff\xff\xff\xff\xff", 6) == 0 && memcmp(frame + 6, mac, 6) == 0 &&
              frame[12] == 0x88 && frame[13] == 0xB5 && memcmp(frame + 14, "wisq-reseau", 11) == 0,
          "diffusée, depuis l'adresse donnée à la carte, de type 0x88B5, son texte");
    check(wisq_pc_net_take(net, frame, sizeof frame) == 0, "une seule");
    check(wisq_pc_net_stats(net, &network) == 1 && network.transmitted == 1 && network.delivered == 0,
          "une émise, rien de livré");
    /* La trame remise, puis la file qui se remplit jusqu'au refus. */
    check(wisq_pc_net_give(net, code_frame, sizeof code_frame) == 1, "la trame est prise");
    int taken = 1;
    for (int i = 1; i < WISQ_PC_FRAME_QUEUE; i++) taken += wisq_pc_net_give(net, code_frame, sizeof code_frame);
    check(taken == WISQ_PC_FRAME_QUEUE, "la file entrante tient WISQ_PC_FRAME_QUEUE trames");
    check(wisq_pc_net_give(net, code_frame, sizeof code_frame) == 0, "pleine, elle refuse");
    check(wisq_pc_net_stats(net, &network) == 1 && network.refused == 1 &&
              network.incoming == WISQ_PC_FRAME_QUEUE,
          "le refus est compté");
    check(wisq_pc_run(net, 10000000) == WISQ_PC_POWER_OFF, "la trame reçue, il s'éteint");
    check(wire.len == 2 && wire.bytes[1] == 'R', "le code que la trame a rangé a dit « R »");
    check(wisq_pc_net_stats(net, &network) == 1 && network.delivered == 1 && network.incoming == 0,
          "livrée, et la carte a pris toute la file");
    check(wisq_pc_net_give(net, code_frame, sizeof code_frame) == 1, "la file reprend");
    wisq_pc_free(net);

    /* --- Une faute, nommée. --- */
    WisqPC *faulting = booted(&faute, NULL, &none);
    check(wisq_pc_run(faulting, 1000000) == WISQ_PC_FAULT, "ud2 sans IDT est une faute");
    size_t length = wisq_pc_fault(faulting, NULL, 0);
    char name[8];
    check(length > sizeof name, "la faute a un nom");
    check(wisq_pc_fault(faulting, name, sizeof name) == length && strlen(name) == sizeof name - 1,
          "coupé à la capacité, terminé par NUL");
    wisq_pc_free(faulting);

    /* --- La remise à zéro. --- */
    WisqPC *rebooting = booted(&remise, NULL, &none);
    check(wisq_pc_run(rebooting, 1000000) == WISQ_PC_REBOOT, "l'impulsion de l'i8042 redémarre");
    wisq_pc_free(rebooting);

    if (failures) {
        fprintf(stderr, "ABI pc : %d échecs\n", failures);
        return 1;
    }
    printf("ABI conforme : la machine PC\n");
    return 0;
}
