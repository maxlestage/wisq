/* Decodes an LZ stream with the reference decoder, so hand-crafted streams
   that target one branch can be checked against the codec rather than against
   an expectation. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <stdint.h>
#include "common/lz.h"

static void on_error(LzUsrContext *u, const char *fmt, ...) {
    va_list ap; va_start(ap, fmt); vfprintf(stderr, fmt, ap); va_end(ap); exit(3);
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

int main(void) {
    static uint8_t in[1 << 20];
    size_t n = fread(in, 1, sizeof in, stdin);

    LzUsrContext usr = {0};
    usr.error = on_error; usr.warn = on_msg; usr.info = on_msg;
    usr.malloc = on_malloc; usr.free = on_free;
    usr.more_space = no_more_space; usr.more_lines = no_more_lines;

    LzContext *lz = lz_create(&usr);
    LzImageType type; int w, h, npix, top_down;
    lz_decode_begin(lz, in, n, &type, &w, &h, &npix, &top_down, NULL);

    int bpp = (type == LZ_IMAGE_TYPE_RGB24) ? 3 : 4;
    uint8_t *out = calloc((size_t)npix + 64, bpp);
    lz_decode(lz, type, out);

    fprintf(stderr, "type=%d w=%d h=%d npix=%d\n", type, w, h, npix);
    for (size_t i = 0; i < (size_t)npix * bpp; i++) printf("%02x", out[i]);
    printf("\n");
    lz_destroy(lz);
    return 0;
}
