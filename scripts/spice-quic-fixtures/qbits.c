/* Traces the reference bit reader: after init, and after each decode_eatbits
   of the given length, prints the window and how many bits of the next word
   are still unspent. What lets the Swift reader be compared step by step
   rather than only at the end. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define main quic_main_unused
#include "quic.c"
#undef main

int main(int argc, char **argv) {
    static char hex[1 << 20];
    if (!fgets(hex, sizeof hex, stdin)) return 1;
    size_t len = strlen(hex);
    while (len && (hex[len-1] == '\n' || hex[len-1] == '\r')) hex[--len] = 0;
    size_t n = len / 2;
    uint8_t *raw = calloc(n + 8, 1);
    for (size_t i = 0; i < n; i++) { unsigned v; sscanf(hex + i*2, "%2x", &v); raw[i] = (uint8_t)v; }

    Encoder e;
    memset(&e, 0, sizeof e);
    e.io_now = (uint32_t *)raw;
    e.io_end = e.io_now + (n / 4);
    init_decode_io(&e);
    printf("init %08x %u\n", e.io_word, e.io_available_bits);

    for (int a = 1; a < argc; a++) {
        int bits = atoi(argv[a]);
        decode_eatbits(&e, bits);
        printf("eat%-3d %08x %u\n", bits, e.io_word, e.io_available_bits);
    }
    return 0;
}
