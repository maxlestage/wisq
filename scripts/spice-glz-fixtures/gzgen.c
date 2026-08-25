/* Encodes a sequence of images against ONE GLZ dictionary, so later images
   can match into earlier ones. A single image cannot produce a cross-image
   match, which is the whole thing that separates GLZ from LZ. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "glz-encoder.h"
#include "glz-encoder-dict.h"

typedef struct { GlzEncoderUsrContext usr; uint8_t *buf; size_t cap; } Usr;

static void u_err(GlzEncoderUsrContext *u, const char *f, ...) {
    (void)u;(void)f; fprintf(stderr, "glz error\n"); exit(2);
}
static void u_warn(GlzEncoderUsrContext *u, const char *f, ...) { (void)u;(void)f; }
static void u_info(GlzEncoderUsrContext *u, const char *f, ...) { (void)u;(void)f; }
static void *u_malloc(GlzEncoderUsrContext *u, int n) { (void)u; return malloc(n); }
static void u_free(GlzEncoderUsrContext *u, void *p) { (void)u; free(p); }
static int u_more_lines(GlzEncoderUsrContext *u, uint8_t **l) { (void)u;(void)l; return 0; }
static int u_more_space(GlzEncoderUsrContext *u, uint8_t **p) { (void)u;(void)p; return 0; }
static void u_free_image(GlzEncoderUsrContext *u, GlzUsrImageContext *i) { (void)u;(void)i; }

int main(int argc, char **argv) {
    if (argc < 4) { fprintf(stderr, "usage: gzgen W H COUNT [seed]\n"); return 1; }
    int w = atoi(argv[1]), h = atoi(argv[2]), count = atoi(argv[3]);
    unsigned seed = argc > 4 ? (unsigned)atoi(argv[4]) : 1;
    int stride = w * 4;

    Usr u = {0};
    u.usr.error = u_err; u.usr.warn = u_warn; u.usr.info = u_info;
    u.usr.malloc = u_malloc; u.usr.free = u_free;
    u.usr.more_lines = u_more_lines; u.usr.more_space = u_more_space;
    u.usr.free_image = u_free_image;

    GlzEncDictContext *dict = glz_enc_dictionary_create(1 << 20, 4, &u.usr);
    if (!dict) { fprintf(stderr, "dict create failed\n"); return 2; }
    GlzEncoderContext *enc = glz_encoder_create(0, dict, &u.usr);
    if (!enc) { fprintf(stderr, "encoder create failed\n"); return 2; }

    size_t outcap = (size_t)stride * h * 2 + 4096;
    uint8_t *out = malloc(outcap);
    /* One buffer PER IMAGE, and all of them kept alive.
       The GLZ dictionary stores pointers into the caller's pixels so later
       images can match against earlier ones. Reusing a single buffer makes
       the encoder match image N against memory that already holds image N+1,
       and the stream then decodes to something the encoder never saw. */
    uint8_t **frames = calloc(count, sizeof *frames);

    for (int n = 0; n < count; n++) {
        uint8_t *pixels = frames[n] = malloc((size_t)stride * h);
        /* Each image is the previous one with a moving band painted over it,
           so most of it matches the image before and some of it cannot. */
        unsigned r = (seed + n) * 2654435761u;
        for (int y = 0; y < h; y++) {
            for (int x = 0; x < w; x++) {
                uint8_t *p = pixels + (size_t)y * stride + (size_t)x * 4;
                if (n > 0 && y >= (n * 3) % h && y < (n * 3) % h + 3) {
                    r = r * 1103515245u + 12345u;
                    p[0] = (uint8_t)(r >> 16); p[1] = (uint8_t)(r >> 8);
                    p[2] = (uint8_t)(r >> 24); p[3] = 0;
                } else {
                    p[0] = (uint8_t)(x * 3); p[1] = (uint8_t)(y * 5);
                    p[2] = (uint8_t)((x ^ y) * 7); p[3] = 0;
                }
            }
        }
        GlzEncDictImageContext *dctx = NULL;
        int size = glz_encode(enc, LZ_IMAGE_TYPE_RGB32, w, h, 1 /*top_down*/,
                              pixels, h, stride, out, (unsigned)outcap,
                              (GlzUsrImageContext *)(intptr_t)(n + 1), &dctx);
        if (size <= 0) { fprintf(stderr, "encode %d failed: %d\n", n, size); return 3; }
        for (int i = 0; i < size; i++) printf("%02x", out[i]);
        printf("\n");
        for (size_t i = 0; i < (size_t)stride * h; i++) fprintf(stderr, "%02x", pixels[i]);
        fprintf(stderr, "\n");
    }
    return 0;
}
