// Le pilote de l'oracle : lit des cas sur l'entrée standard, les fait exécuter
// par le vrai processeur, écrit le verdict sur la sortie standard.
//
// Un cas par ligne :  <octets en hexa> TAB <valeurs d'entrée en hexa>
// Le verdict :        <octets> TAB <entrée> TAB <sortie>
//
// Les dix-sept premières valeurs sont les seize registres dans l'ordre de
// l'encodage (rax rcx rdx rbx rsp rbp rsi rdi r8..r15) puis RFLAGS.
//
// **Le nombre de valeurs est celui de la ligne**, et la réponse en porte
// autant. Une ligne de dix-sept ne parle que des registres généraux ; une de
// quarante-neuf ajoute les seize XMM, deux mots chacun, le bas d'abord. Les
// deux formes cohabitent exprès : le corpus arithmétique existant a été
// produit avec dix-sept, et le régénérer avec quarante-neuf changerait dix
// mille lignes pour des colonnes que personne ne lirait. Ce qui n'est pas
// donné part à zéro, et ce qui n'est pas demandé n'est pas rendu.
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>

void wisq_x86_run(uint64_t *state, void *code);
// L'adresse du retour, prise directement sur le symbole : le créneau que le
// harnais remplit ne l'est qu'une fois l'appel commencé, donc trop tard pour
// la page de code, qui est écrite avant.
extern char wisq_return[];

// Le harnais lit et écrit toujours quarante-neuf mots ; le pilote ne montre
// que ceux qu'on lui a demandés.
#define SLOTS 49
#define GENERAL 17
#define MAX_CODE 512

// Des adresses **fixes**, pour que le verdict se reproduise d'une exécution à
// l'autre : une adresse rendue par mmap changerait à chaque fois et ne pourrait
// être ni comparée ni versionnée.
#define ARENA   0x30000000UL
#define CODE    (ARENA + 0x0000)
#define DATA    (ARENA + 0x1000)
#define STACK   (ARENA + 0x3000)
#define WINDOW  64
// La **fenêtre de pile** : soixante-quatre octets de part et d'autre de RSP.
// En dessous vit ce qu'un `push` écrit ; au-dessus, ce qu'un `pop` relit. Les
// deux moitiés portent des motifs différents pour qu'on voie du premier coup
// de quel côté d'une pile un octet vient.
//
// **Elle est rendue après la fenêtre de données, et non à sa place.** Les dix
// mille cas déjà figés lisent la fenêtre de données à un rang fixe ; une
// colonne ajoutée en queue les laisse à l'octet près, une colonne insérée les
// décalerait toutes.
#define STACKWIN 64
#define BELOW    (STACK - STACKWIN)

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
        uint64_t in[SLOTS] = {0};
        char *cursor = line;
        if (sscanf(cursor, "%511s", hex) != 1) {
            fprintf(stderr, "ligne sans octets : %s", line); return 1;
        }
        cursor += strlen(hex);
        int count = 0;
        while (count < SLOTS) {
            char *next;
            unsigned long long value = strtoull(cursor, &next, 16);
            if (next == cursor) break;
            in[count++] = value;
            cursor = next;
        }
        if (count != GENERAL && count != SLOTS) {
            fprintf(stderr, "ligne à %d valeurs, il en faut %d ou %d : %s",
                    count, GENERAL, SLOTS, line);
            return 1;
        }

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
        // Et la pile, des deux côtés du sommet.
        unsigned char *below = (unsigned char *)BELOW;
        for (int i = 0; i < STACKWIN; i++) below[i] = (unsigned char)(0xB0 + i);
        for (int i = 0; i < STACKWIN; i++)
            below[STACKWIN + i] = (unsigned char)(0x40 + i);

        uint64_t state[SLOTS];
        memcpy(state, in, sizeof state);
        // La pile de l'invité, loin du harnais, et à une adresse fixe.
        state[4] = STACK;
        in[4] = state[4];

        wisq_x86_run(state, code);

        printf("%s", hex);
        for (int i = 0; i < count; i++) printf("\t%llx", (unsigned long long)in[i]);
        for (int i = 0; i < count; i++) printf("\t%llx", (unsigned long long)state[i]);
        printf("\t");
        for (int i = 0; i < WINDOW; i++) printf("%02x", data[i]);
        printf("\t");
        for (int i = 0; i < 2 * STACKWIN; i++) printf("%02x", below[i]);
        printf("\n");
    }
    return 0;
}
