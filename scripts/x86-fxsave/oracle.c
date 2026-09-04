// Ce que le vrai processeur fait d'une zone FXSAVE.
//
// On lui donne une image de 512 octets, il la charge avec `FXRSTOR`, puis la
// réécrit avec `FXSAVE`. L'aller-retour montre à la fois où chaque champ vit
// et **comment le processeur normalise ce que le format abrège** — le mot
// d'étiquettes n'a qu'un bit par registre là où l'état en tient deux, et c'est
// la machine qui dit ce qu'elle en reconstruit.
//
// Une ligne par cas sur l'entrée standard : 512 octets en hexadécimal.
// Une ligne par cas en sortie : les 512 octets rendus, en hexadécimal.
#include <stdio.h>
#include <string.h>

static unsigned char area[512] __attribute__((aligned(16)));

int main(void) {
    char line[2048];
    while (fgets(line, sizeof line, stdin)) {
        if (line[0] == '#' || line[0] == '\n') continue;
        memset(area, 0, sizeof area);
        for (int i = 0; i < 512; i++) {
            unsigned value;
            if (sscanf(line + 2 * i, "%2x", &value) != 1) break;
            area[i] = (unsigned char)value;
        }
        __asm__ volatile("fxrstor %0" :: "m"(area) : "memory");
        memset(area, 0xCC, sizeof area);
        __asm__ volatile("fxsave %0" : "=m"(area) :: "memory");
        for (int i = 0; i < 512; i++) printf("%02x", area[i]);
        printf("\n");
    }
    return 0;
}
