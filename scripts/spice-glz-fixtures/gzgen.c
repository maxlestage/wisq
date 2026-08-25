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
        const char *mode = getenv("GZMODE");
        int repeats = mode && mode[0] == 'r';      /* flat blocks: local matches */
        int farback = mode && mode[0] == 'f';      /* last image repeats image 0 */
        int deep = mode && mode[0] == 'd';         /* last image = source's 2nd half */
        int longofs = mode && mode[0] == 'l';      /* bottom half repeats top half */
        if (farback && (n == 0 || n == count - 1)) r = seed * 2654435761u;
        for (int y = 0; y < h; y++) {
            for (int x = 0; x < w; x++) {
                uint8_t *p = pixels + (size_t)y * stride + (size_t)x * 4;
                if (deep) {
                    /* Image 0 is noise. The last image reproduces image 0's
                       BOTTOM half in its own top half, so the match lands at a
                       high absolute offset inside an earlier image: a
                       cross-image reference that also takes the long-offset
                       path. */
                    int sy = (n == count - 1) ? (y + h / 2) % h : y;
                    /* Smooth, so the base images compress to almost nothing
                       and the fixture stays small, but with the two halves
                       distinct so the deep match is unambiguous. */
                    int band = sy / 8;
                    p[0] = (uint8_t)(band * 24 + (n == 1 ? 7 : 0));
                    p[1] = (uint8_t)(band * 11 + (n == 1 ? 3 : 0));
                    p[2] = (uint8_t)(band * 37 + (n == 1 ? 5 : 0));
                    p[3] = 0;
                } else if (longofs) {
                    /* The bottom half is the top half again, so a match at the
                       midpoint reaches back half an image — past the 4095
                       pixels the short offset field can hold. */
                    int sy = y % (h / 2);
                    unsigned q = (seed * 2654435761u) + (unsigned)(sy * 7919 + x * 104729);
                    q = q * 1103515245u + 12345u;
                    p[0] = (uint8_t)(q >> 16); p[1] = (uint8_t)(q >> 8);
                    p[2] = (uint8_t)(q >> 24); p[3] = 0;
                } else if (repeats) {
                    /* Wide flat blocks, so a match can be found inside the
                       very first image, where no window exists yet. */
                    p[0] = (uint8_t)((x / 8) * 40); p[1] = (uint8_t)((y / 4) * 30);
                    p[2] = (uint8_t)(((x / 8) ^ (y / 4)) * 20); p[3] = 0;
                } else if (farback) {
                    if (n == 0 || n == count - 1) {
                        p[0] = (uint8_t)(x * 11); p[1] = (uint8_t)(y * 13);
                        p[2] = (uint8_t)((x + y) * 17); p[3] = 0;
                    } else {
                        r = r * 1103515245u + 12345u;
                        p[0] = (uint8_t)(r >> 16); p[1] = (uint8_t)(r >> 8);
                        p[2] = (uint8_t)(r >> 24); p[3] = 0;
                    }
                } else if (n > 0 && y >= (n * 3) % h && y < (n * 3) % h + 3) {
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
