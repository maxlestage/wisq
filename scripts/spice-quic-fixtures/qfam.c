/* Dumps the two family tables the reference builds, so the Swift ones are
   compared against the codec's own numbers rather than a reading of them. */
#include <stdio.h>
#include <string.h>
#include "quic.h"

/* The tables are file-static in quic.c, so this includes it rather than
   linking: the point is to read what that file computed. */
#define main quic_main_unused
#include "quic.c"
#undef main

static void dump(const char *name, QuicFamily *f, int bpc) {
    printf("=== %s bpc=%d ===\n", name, bpc);
    printf("nGRcodewords:");   for (int l = 0; l < bpc; l++) printf(" %u", f->nGRcodewords[l]);
    printf("\nnotGRcwlen:");     for (int l = 0; l < bpc; l++) printf(" %u", f->notGRcwlen[l]);
    printf("\nnotGRprefixmask:");for (int l = 0; l < bpc; l++) printf(" %u", f->notGRprefixmask[l]);
    printf("\nnotGRsuffixlen:"); for (int l = 0; l < bpc; l++) printf(" %u", f->notGRsuffixlen[l]);
    printf("\nxlatU2L:");        for (int s = 0; s <= (int)bppmask[bpc]; s++) printf(" %u", f->xlatU2L[s]);
    printf("\nxlatL2U:");        for (int s = 0; s <= (int)bppmask[bpc]; s++) printf(" %u", f->xlatL2U[s]);
    printf("\ngolomb_code_len:");
    for (int b = 0; b < 256; b++) for (int l = 0; l < bpc; l++) printf(" %u", f->golomb_code_len[b][l]);
    printf("\ngolomb_code:");
    for (int b = 0; b < 256; b++) for (int l = 0; l < bpc; l++) printf(" %u", f->golomb_code[b][l]);
    printf("\n");
}

int main(void) {
    family_init(&family_8bpc, 8, DEFmaxclen);
    family_init(&family_5bpc, 5, DEFmaxclen);
    dump("family_8bpc", &family_8bpc, 8);
    dump("family_5bpc", &family_5bpc, 5);
    return 0;
}
