// Le pilote de l'oracle : lit des cas sur l'entrée standard, les fait exécuter
// par le vrai processeur, écrit le verdict sur la sortie standard.
//
// Un cas par ligne :  <octets en hexa> TAB <17 valeurs d'entrée en hexa>
// Le verdict :        <octets> TAB <entrée> TAB <sortie>
//
// Les dix-sept valeurs sont les seize registres dans l'ordre de l'encodage
// (rax rcx rdx rbx rsp rbp rsi rdi r8..r15) puis RFLAGS.
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>

void wisq_x86_run(uint64_t *state, void *code);
// L'adresse du retour, prise directement sur le symbole : le créneau que le
// harnais remplit ne l'est qu'une fois l'appel commencé, donc trop tard pour
// la page de code, qui est écrite avant.
extern char wisq_return[];

#define SLOTS 17
#define MAX_CODE 512

// Des adresses **fixes**, pour que le verdict se reproduise d'une exécution à
// l'autre : une adresse rendue par mmap changerait à chaque fois et ne pourrait
// être ni comparée ni versionnée.
#define ARENA   0x30000000UL
#define CODE    (ARENA + 0x0000)
#define DATA    (ARENA + 0x1000)
#define STACK   (ARENA + 0x3000)
#define WINDOW  64

int main(void) {
    // Une page inscriptible puis exécutable. La pile de l'invité vit dans la
    // page suivante : un cas qui touche à RSP ne doit pas écraser le harnais.
    size_t page = 4096;
    unsigned char *arena = mmap((void *)ARENA, page * 4, PROT_READ | PROT_WRITE | PROT_EXEC,
                                MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED, -1, 0);
    if (arena == MAP_FAILED) { perror("mmap"); return 1; }
    unsigned char *code = (unsigned char *)CODE;
    unsigned char *data = (unsigned char *)DATA;

    char line[4096];
    while (fgets(line, sizeof line, stdin)) {
        if (line[0] == '#' || line[0] == '\n') continue;
        char hex[512];
        uint64_t in[SLOTS];
        int read = sscanf(line,
            "%511s %llx %llx %llx %llx %llx %llx %llx %llx "
            "%llx %llx %llx %llx %llx %llx %llx %llx %llx",
            hex,
            (unsigned long long *)&in[0], (unsigned long long *)&in[1],
            (unsigned long long *)&in[2], (unsigned long long *)&in[3],
            (unsigned long long *)&in[4], (unsigned long long *)&in[5],
            (unsigned long long *)&in[6], (unsigned long long *)&in[7],
            (unsigned long long *)&in[8], (unsigned long long *)&in[9],
            (unsigned long long *)&in[10], (unsigned long long *)&in[11],
            (unsigned long long *)&in[12], (unsigned long long *)&in[13],
            (unsigned long long *)&in[14], (unsigned long long *)&in[15],
            (unsigned long long *)&in[16]);
        if (read != SLOTS + 1) { fprintf(stderr, "ligne illisible : %s", line); return 1; }

        size_t length = strlen(hex) / 2;
        if (length > MAX_CODE) { fprintf(stderr, "cas trop long\n"); return 1; }
        for (size_t i = 0; i < length; i++) {
            unsigned byte;
            sscanf(hex + 2 * i, "%2x", &byte);
            code[i] = (unsigned char)byte;
        }
        // Le retour : jmp *(%rip) suivi de l'adresse, ajouté après les octets à
        // l'essai. Un saut indirect ne touche ni aux drapeaux ni à la pile.
        code[length + 0] = 0xFF;
        code[length + 1] = 0x25;
        code[length + 2] = 0x00;
        code[length + 3] = 0x00;
        code[length + 4] = 0x00;
        code[length + 5] = 0x00;
        void *back = wisq_return;
        memcpy(code + length + 6, &back, 8);

        // Une fenêtre de données au motif reconnaissable : si l'instruction
        // écrit là où il ne faut pas, ça se voit.
        for (int i = 0; i < WINDOW; i++) data[i] = (unsigned char)(0x10 + i);

        uint64_t state[SLOTS];
        memcpy(state, in, sizeof state);
        // La pile de l'invité, loin du harnais, et à une adresse fixe.
        state[4] = STACK;
        in[4] = state[4];

        wisq_x86_run(state, code);

        printf("%s", hex);
        for (int i = 0; i < SLOTS; i++) printf("\t%llx", (unsigned long long)in[i]);
        for (int i = 0; i < SLOTS; i++) printf("\t%llx", (unsigned long long)state[i]);
        printf("\t");
        for (int i = 0; i < WINDOW; i++) printf("%02x", data[i]);
        printf("\n");
    }
    return 0;
}
