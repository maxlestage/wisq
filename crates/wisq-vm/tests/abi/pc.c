/*
 * La machine PC native, telle qu'un appelant C la mène.
 *
 * `include/wisq_vm.h` est écrit à la main : une signature qui dériverait de
 * src/ffi.rs ne serait ni une erreur Rust ni une erreur Swift, mais un appel
 * faux à l'exécution. Ce programme appelle chaque fonction `wisq_pc_*`, juge
 * ce qu'elle rend, et le dit en français.
 *
 * Il reçoit quatre petits noyaux, gravés par tests/abi.rs : le noyau factice
 * (sa bannière, sa ligne, cinq battements, « FIN »), une boucle sans fin, un
 * `ud2` sans IDT, et l'impulsion de remise à zéro de l'i8042 ; puis un dossier
 * où poser un disque.
 *
 *   cc -I include tests/abi/pc.c -L <libdir> -lwisq_vm -lpthread -o pc
 *   ./pc factice.bin boucle.bin faute.bin remise.bin <dossier>
 */

#include "wisq_vm.h"

#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
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
    if (argc < 6) {
        fprintf(stderr, "usage : pc factice boucle faute remise dossier\n");
        return 2;
    }
    File factice = read_file(argv[1]);
    File boucle = read_file(argv[2]);
    File faute = read_file(argv[3]);
    File remise = read_file(argv[4]);
    if (!factice.len || !boucle.len || !faute.len || !remise.len) {
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
    snprintf(base, sizeof base, "%s/disque.img", argv[5]);
    snprintf(writes, sizeof writes, "%s/disque.couche", argv[5]);
    snprintf(second, sizeof second, "%s/second.img", argv[5]);
    snprintf(second_writes, sizeof second_writes, "%s/second.couche", argv[5]);
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
    altered[8] = 2; /* la version */
    check(wisq_pc_restore(resumed, altered, snapshot_len) == -3, "une version inconnue est refusée");
    check(wisq_pc_restore(resumed, snapshot, snapshot_len - 1) == -4, "un instantané tronqué est refusé");
    free(altered);
    WisqPC *bigger = wisq_pc_new(RAM * 2, NULL, NULL);
    check(wisq_pc_restore(bigger, snapshot, snapshot_len) == -5, "une autre RAM est refusée");
    wisq_pc_free(bigger);
    WisqPC *screened = wisq_pc_new(RAM, NULL, NULL);
    check(wisq_pc_attach_display(screened, 640, 480) == 0, "un écran");
    check(wisq_pc_restore(screened, snapshot, snapshot_len) == -6, "un autre écran est refusé");
    wisq_pc_free(screened);
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
