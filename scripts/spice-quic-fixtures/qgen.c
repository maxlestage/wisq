/* Produces QUIC streams with SPICE's own encoder, and the pixels they came
   from, so the Swift decoder is checked against the codec rather than against
   a reading of it. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "quic.h"

static void q_error(QuicUsrContext *u, const char *fmt, ...) {
    (void)u; (void)fmt; fprintf(stderr, "quic error\n"); exit(2);
}
static void q_warn(QuicUsrContext *u, const char *fmt, ...) { (void)u; (void)fmt; }
static void q_info(QuicUsrContext *u, const char *fmt, ...) { (void)u; (void)fmt; }
static void *q_malloc(QuicUsrContext *u, int size) { (void)u; return malloc(size); }
static void q_free(QuicUsrContext *u, void *p) { (void)u; free(p); }
static int q_more_space(QuicUsrContext *u, uint32_t **io_ptr, int rows) {
    (void)u; (void)io_ptr; (void)rows; return 0;   /* one buffer, big enough */
}
static int q_more_lines(QuicUsrContext *u, uint8_t **lines) {
    (void)u; (void)lines; return 0;
}

int main(int argc, char **argv) {
    if (argc < 4) { fprintf(stderr, "usage: qgen TYPE W H [seed]\n"); return 1; }
    int type = atoi(argv[1]), w = atoi(argv[2]), h = atoi(argv[3]);
    unsigned seed = argc > 4 ? (unsigned)atoi(argv[4]) : 1;

    int bpp = (type == QUIC_IMAGE_TYPE_RGB32 || type == QUIC_IMAGE_TYPE_RGBA) ? 4
            : (type == QUIC_IMAGE_TYPE_RGB24) ? 3
            : (type == QUIC_IMAGE_TYPE_RGB16) ? 2 : 1;
    int stride = w * bpp;
    uint8_t *pixels = calloc(1, (size_t)stride * h);

    /* Flat bands, a gradient and pseudo-random noise, so the adaptive model
       meets runs, smooth prediction and surprises in one image. */
    unsigned r = seed * 2654435761u;
    for (int y = 0; y < h; y++) {
        for (int x = 0; x < w; x++) {
            uint8_t *p = pixels + (size_t)y * stride + (size_t)x * bpp;
            int band = (y / 3) % 3;
            for (int c = 0; c < bpp; c++) {
                r = r * 1103515245u + 12345u;
                if (band == 0)      p[c] = (uint8_t)(64 + c * 20);
                else if (band == 1) p[c] = (uint8_t)((x * 7 + c * 3) & 0xFF);
                else                p[c] = (uint8_t)((r >> 16) & 0xFF);
            }
        }
    }

    QuicUsrContext usr = { q_error, q_warn, q_info, q_malloc, q_free,
                           q_more_space, q_more_lines };
    QuicContext *quic = quic_create(&usr);
    if (!quic) { fprintf(stderr, "quic_create failed\n"); return 2; }

    size_t words = (size_t)stride * h * 2 + 1024;
    uint32_t *out = calloc(words, 4);
    int n = quic_encode(quic, type, w, h, pixels, h, stride, out, (unsigned)words);
    if (n <= 0) { fprintf(stderr, "quic_encode failed: %d\n", n); return 3; }

    /* The stream, as the wire carries it: the encoder writes native-endian
       words, and SPICE sends those words' bytes as they sit in memory. */
    for (int i = 0; i < n * 4; i++) printf("%02x", ((uint8_t *)out)[i]);
    printf("\n");
    for (size_t i = 0; i < (size_t)stride * h; i++) fprintf(stderr, "%02x", pixels[i]);
    fprintf(stderr, "\n");
    quic_destroy(quic);
    return 0;
}
