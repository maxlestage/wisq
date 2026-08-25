/* Generates palette-form SPICE-LZ streams with the reference encoder, and
   decodes them back to RGB32 with the reference decoder, so the Swift side can
   be checked against the codec rather than against a reading of it.

   stdout: the compressed stream.
   stderr: "PALETTE <hex>" then "RGB32 <hex>" — the palette as it travels in the
   message, and the pixels the reference decoder produces from the stream. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <stdint.h>
#include "common/lz.h"

static void on_error(LzUsrContext *u, const char *fmt, ...) {
    va_list ap; va_start(ap, fmt); vfprintf(stderr, fmt, ap); va_end(ap); exit(2);
}
static void on_msg(LzUsrContext *u, const char *fmt, ...) { (void)u; (void)fmt; }
static void *on_malloc(LzUsrContext *u, int size) { (void)u; return malloc(size); }
static void on_free(LzUsrContext *u, void *p) { (void)u; free(p); }
static int no_more_space(LzUsrContext *u, uint8_t **p) { (void)u; (void)p; return 0; }
static int no_more_lines(LzUsrContext *u, uint8_t **l) { (void)u; (void)l; return 0; }

void spice_log(GLogLevelFlags level, const char *strloc, const char *function,
               const char *format, ...) {
    va_list ap; va_start(ap, format); vfprintf(stderr, format, ap); va_end(ap);
    fprintf(stderr, "\n");
    if (level & (G_LOG_LEVEL_ERROR | G_LOG_LEVEL_CRITICAL)) abort();
}

int main(int argc, char **argv) {
    if (argc < 5) { fprintf(stderr, "usage: genplt TYPE W H seed\n"); return 1; }
    int type = atoi(argv[1]), w = atoi(argv[2]), h = atoi(argv[3]);
    unsigned seed = (unsigned)atoi(argv[4]);

    int entries = (type == LZ_IMAGE_TYPE_PLT8) ? 256
                : (type == LZ_IMAGE_TYPE_PLT4_LE || type == LZ_IMAGE_TYPE_PLT4_BE) ? 16 : 2;
    int per_byte = (type == LZ_IMAGE_TYPE_PLT8) ? 1
                 : (type == LZ_IMAGE_TYPE_PLT4_LE || type == LZ_IMAGE_TYPE_PLT4_BE) ? 2 : 8;
    int stride = (w + per_byte - 1) / per_byte;

    SpicePalette *palette = calloc(1, sizeof(SpicePalette) + entries * 4);
    palette->unique = 1;
    palette->num_ents = entries;
    for (int i = 0; i < entries; i++)
        palette->ents[i] = (uint32_t)((i * 7 & 0xFF) | ((i * 13 & 0xFF) << 8)
                                      | ((i * 29 & 0xFF) << 16));

    uint8_t *lines = malloc((size_t)stride * h);
    unsigned s = seed ? seed : 1;
    for (int y = 0; y < h; y++)
        for (int x = 0; x < stride; x++) {
            uint8_t v;
            if (y < h / 3)          v = 0x11;
            else if (y < 2 * h / 3) v = (uint8_t)(x % 5);
            else { s = s * 1103515245u + 12345u; v = (uint8_t)(s >> 16); }
            lines[(size_t)y * stride + x] = v;
        }

    LzUsrContext usr = {0};
    usr.error = on_error; usr.warn = on_msg; usr.info = on_msg;
    usr.malloc = on_malloc; usr.free = on_free;
    usr.more_space = no_more_space; usr.more_lines = no_more_lines;

    LzContext *lz = lz_create(&usr);
    size_t cap = (size_t)stride * h * 4 + 8192;
    uint8_t *out = malloc(cap);
    int n = lz_encode(lz, type, w, h, 1, lines, h, stride, out, cap);
    fwrite(out, 1, (size_t)n, stdout);
    lz_destroy(lz);

    /* The palette, laid out as it travels: unique, num_ents, entries. */
    fprintf(stderr, "PALETTE ");
    for (int i = 0; i < 8; i++) fprintf(stderr, "%02x", (unsigned)(palette->unique >> (8*i)) & 0xFF);
    fprintf(stderr, "%02x%02x", entries & 0xFF, (entries >> 8) & 0xFF);
    for (int i = 0; i < entries; i++)
        for (int b = 0; b < 4; b++) fprintf(stderr, "%02x", (palette->ents[i] >> (8*b)) & 0xFF);
    fprintf(stderr, "\n");

    /* And what the reference decoder makes of the stream, as RGB32. */
    LzContext *dec = lz_create(&usr);
    LzImageType dtype; int dw, dh, npix, topdown;
    lz_decode_begin(dec, out, n, &dtype, &dw, &dh, &npix, &topdown, palette);
    uint8_t *rgb = calloc((size_t)npix + 64, 4);
    lz_decode(dec, LZ_IMAGE_TYPE_RGB32, rgb);
    fprintf(stderr, "RGB32 ");
    for (size_t i = 0; i < (size_t)npix * 4; i++) fprintf(stderr, "%02x", rgb[i]);
    fprintf(stderr, "\n");
    lz_destroy(dec);
    return 0;
}
