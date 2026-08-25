/* Generates a SPICE LZ4 image payload the way spice-server does.
 *
 * The loop is lz4_encode() from spice/server/lz4-encoder.c: a direction byte,
 * a format byte, then for each chunk of lines a big-endian uint32 length
 * followed by LZ4_compress_fast_continue on a *shared* stream — which is why
 * the blocks are not independent and a match in block three can name bytes
 * decoded in block one.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include "lz4.h"

static int env_int(const char *name, int fallback) {
    const char *v = getenv(name);
    return v ? atoi(v) : fallback;
}

/* Deterministic content. The patterns are chosen for what they make the codec
 * do, not for what they look like. */
static void fill(uint8_t *src, int total, int stride, int height, const char *mode) {
    uint32_t s = 0x1234567u;
    if (!strcmp(mode, "flat")) {
        for (int i = 0; i < total; i++) src[i] = (uint8_t)((i / stride) & 0xFF);
    } else if (!strcmp(mode, "noise")) {
        /* Incompressible: every sequence is a literal run and the block grows. */
        for (int i = 0; i < total; i++) { s = s * 1103515245u + 12345u; src[i] = (uint8_t)(s >> 16); }
    } else if (!strcmp(mode, "runs")) {
        /* Long identical stretches: match lengths past 19, so the extension
         * bytes of the match-length field get exercised. */
        for (int i = 0; i < total; i++) src[i] = (uint8_t)((i / 700) * 37);
    } else if (!strcmp(mode, "near")) {
        /* Period 3: offsets below 8, the overlapping-copy path. */
        for (int i = 0; i < total; i++) src[i] = (uint8_t)((i % 3) * 80 + 5);
    } else { /* "cross": each row repeats a row far above it, plus noise, so
              * matches reach back across block boundaries. */
        for (int row = 0; row < height; row++) {
            for (int col = 0; col < stride; col++) {
                int i = row * stride + col;
                if (row >= 5 && (row % 3)) { src[i] = src[(row - 5) * stride + col]; }
                else { s = s * 1103515245u + 12345u; src[i] = (uint8_t)(s >> 16); }
            }
        }
    }
}

int main(int argc, char **argv) {
    if (argc < 4) { fprintf(stderr, "usage: [L4MODE=] [L4FMT=] [L4TD=] l4gen <width> <height> <lines-per-block>\n"); return 2; }
    int width = atoi(argv[1]), height = atoi(argv[2]), lines = atoi(argv[3]);
    int format = env_int("L4FMT", 8), topDown = env_int("L4TD", 1);
    const char *mode = getenv("L4MODE") ? getenv("L4MODE") : "cross";

    int bpp = format == 6 ? 2 : format == 7 ? 3 : 4;
    int stride = width * bpp, total = stride * height;
    uint8_t *src = malloc(total);
    fill(src, total, stride, height, mode);

    uint8_t *out = malloc(total * 2 + 4096);
    int outSize = 0;
    out[outSize++] = topDown ? 1 : 0;
    out[outSize++] = (uint8_t)format;

    LZ4_stream_t *stream = LZ4_createStream();
    for (int done = 0; done < height; ) {
        int n = lines; if (done + n > height) n = height - done;
        int inSize = stride * n;
        int bound = LZ4_compressBound(inSize);
        uint8_t *block = malloc(bound);
        int enc = LZ4_compress_fast_continue(stream, (const char *)(src + done * stride),
                                             (char *)block, inSize, bound, 1);
        if (enc <= 0) { fprintf(stderr, "compress failed\n"); return 1; }
        out[outSize++] = (uint8_t)(enc >> 24); out[outSize++] = (uint8_t)(enc >> 16);
        out[outSize++] = (uint8_t)(enc >> 8);  out[outSize++] = (uint8_t)enc;
        memcpy(out + outSize, block, enc); outSize += enc;
        free(block);
        done += n;
    }
    LZ4_freeStream(stream);

    printf("width %d height %d format %d topDown %d lines %d mode %s\n",
           width, height, format, topDown, lines, mode);
    printf("payload %d\n", outSize);
    for (int i = 0; i < outSize; i++) printf("%02x", out[i]);
    printf("\nplain %d\n", total);
    for (int i = 0; i < total; i++) printf("%02x", src[i]);
    printf("\n");
    return 0;
}
