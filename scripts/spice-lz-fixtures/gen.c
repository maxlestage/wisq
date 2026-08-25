/* Generates real SPICE-LZ streams with the reference encoder, so the Swift
   decoder is checked against the codec rather than against a reading of it. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <stdint.h>
#include "common/lz.h"

typedef struct { LzUsrContext base; uint8_t *lines; int n; } Usr;

static void on_error(LzUsrContext *u, const char *fmt, ...) {
    va_list ap; va_start(ap, fmt); vfprintf(stderr, fmt, ap); va_end(ap); exit(2);
}
static void on_msg(LzUsrContext *u, const char *fmt, ...) { (void)u; (void)fmt; }
static void *on_malloc(LzUsrContext *u, int size) { (void)u; return malloc(size); }
static void on_free(LzUsrContext *u, void *p) { (void)u; free(p); }
static int no_more_space(LzUsrContext *u, uint8_t **p) { (void)u; (void)p; return 0; }
static int no_more_lines(LzUsrContext *u, uint8_t **l) { (void)u; (void)l; return 0; }

int main(int argc, char **argv) {
    if (argc < 5) { fprintf(stderr, "usage: gen TYPE W H seed\n"); return 1; }
    int type = atoi(argv[1]), w = atoi(argv[2]), h = atoi(argv[3]);
    unsigned seed = (unsigned)atoi(argv[4]);

    int bpp = (type == LZ_IMAGE_TYPE_RGB32) ? 4
            : (type == LZ_IMAGE_TYPE_RGB24) ? 3
            : (type == LZ_IMAGE_TYPE_RGB16) ? 2 : 4;
    int stride = w * bpp;
    uint8_t *lines = malloc((size_t)stride * h);

    /* A picture with runs, repeats and noise, so matches and literals both
       occur: flat bands, a repeating pattern, then pseudo-random bytes. */
    unsigned s = seed ? seed : 1;
    for (int y = 0; y < h; y++) {
        for (int x = 0; x < stride; x++) {
            uint8_t v;
            if (y < h / 3)            v = (uint8_t)(0x40 + (y & 3));
            else if (y < 2 * h / 3)   v = (uint8_t)((x % 7) * 31);
            else { s = s * 1103515245u + 12345u; v = (uint8_t)(s >> 16); }
            lines[(size_t)y * stride + x] = v;
        }
    }

    /* RGB32's fourth byte is padding the codec never transmits and always
       writes back as zero. Zeroing it here makes the fixture comparable to
       what a correct decoder produces, rather than to bytes the format
       does not carry. RGBA and XXXA *do* carry it, so they keep theirs. */
    if (type == LZ_IMAGE_TYPE_RGB32)
        for (size_t i = 3; i < (size_t)stride * h; i += 4) lines[i] = 0;
    /* XXXA carries only the alpha byte: the colour bytes are never encoded and
       come back as whatever the buffer held, so they are zeroed to make the
       comparison meaningful. */
    if (type == LZ_IMAGE_TYPE_XXXA)
        for (size_t i = 0; i < (size_t)stride * h; i++) if (i % 4 != 3) lines[i] = 0;

    Usr usr = {0};
    usr.base.error = on_error; usr.base.warn = on_msg; usr.base.info = on_msg;
    usr.base.malloc = on_malloc; usr.base.free = on_free;
    usr.base.more_space = no_more_space; usr.base.more_lines = no_more_lines;

    LzContext *lz = lz_create(&usr.base);
    size_t cap = (size_t)stride * h * 2 + 4096;
    uint8_t *out = malloc(cap);
    int n = lz_encode(lz, type, w, h, 1 /* top down */, lines, h, stride, out, cap);

    /* stdout: the compressed stream. stderr: the original pixels, as hex. */
    fwrite(out, 1, (size_t)n, stdout);
    for (size_t i = 0; i < (size_t)stride * h; i++) fprintf(stderr, "%02x", lines[i]);
    fprintf(stderr, "\n");
    lz_destroy(lz);
    return 0;
}

/* The only symbol lz.c needs from spice-common's logging. Aborting on a fatal
   log is right here: this harness exists to produce correct streams, and a
   stream produced after an assertion failed is not one. */
void spice_log(GLogLevelFlags level, const char *strloc, const char *function,
               const char *format, ...) {
    va_list ap; va_start(ap, format); vfprintf(stderr, format, ap); va_end(ap);
    fprintf(stderr, "\n");
    if (level & (G_LOG_LEVEL_ERROR | G_LOG_LEVEL_CRITICAL)) abort();
}
