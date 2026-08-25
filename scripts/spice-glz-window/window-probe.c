/* What does a GLZ dictionary declared with N pixels do when asked to encode
   an image?  The client picks N in SPICE_MSGC_DISPLAY_INIT and the server
   hands it straight to glz_enc_dictionary_create, so N=0 is a thing a client
   can say.  spice-server's own usr->error is glz_usr_error, which calls
   spice_critical, which calls abort() -- so "error was called" here is
   "the server process died" there. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "glz-encoder.h"
#include "glz-encoder-dict.h"

typedef struct { GlzEncoderUsrContext usr; } Usr;

static int errors = 0;
static void u_err(GlzEncoderUsrContext *u, const char *f, ...) {
    (void)u;
    /* spice-server aborts here.  Record and keep going so we can see what the
       call actually was rather than only that there was one. */
    errors++;
    fprintf(stderr, "  usr->error: %s", f);
}
static void u_warn(GlzEncoderUsrContext *u, const char *f, ...) { (void)u;(void)f; }
static void *u_malloc(GlzEncoderUsrContext *u, int n) { (void)u; return malloc(n); }
static void u_free(GlzEncoderUsrContext *u, void *p) { (void)u; free(p); }
static int u_more_lines(GlzEncoderUsrContext *u, uint8_t **l) { (void)u;(void)l; return 0; }
static int u_more_space(GlzEncoderUsrContext *u, uint8_t **p) { (void)u;(void)p; return 0; }
static void u_free_image(GlzEncoderUsrContext *u, GlzUsrImageContext *i) { (void)u;(void)i; }

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: gzwin WINDOW_PIXELS [W H]\n"); return 1; }
    uint32_t window = (uint32_t)strtoul(argv[1], NULL, 0);
    int w = argc > 3 ? atoi(argv[2]) : 64, h = argc > 3 ? atoi(argv[3]) : 64;
    int stride = w * 4;

    Usr u = {0};
    u.usr.error = u_err; u.usr.warn = u_warn; u.usr.info = u_warn;
    u.usr.malloc = u_malloc; u.usr.free = u_free;
    u.usr.more_lines = u_more_lines; u.usr.more_space = u_more_space;
    u.usr.free_image = u_free_image;

    printf("window = %u pixels, image = %dx%d (%d pixels)\n", window, w, h, w * h);

    GlzEncDictContext *dict = glz_enc_dictionary_create(window, 4, &u.usr);
    if (!dict) { printf("  dictionary create: FAILED (returned NULL)\n"); return 0; }
    printf("  dictionary create: ok, errors so far = %d\n", errors);

    GlzEncoderContext *enc = glz_encoder_create(0, dict, &u.usr);
    if (!enc) { printf("  encoder create: FAILED\n"); return 0; }

    uint8_t *pixels = malloc((size_t)stride * h);
    for (int i = 0; i < stride * h; i++) pixels[i] = (uint8_t)(i * 7);
    size_t outcap = (size_t)stride * h * 2 + 4096;
    uint8_t *out = malloc(outcap);

    GlzEncDictImageContext *dctx = NULL;
    int before = errors;
    int size = glz_encode(enc, LZ_IMAGE_TYPE_RGB32, w, h, 1, pixels, h, stride,
                          out, (unsigned)outcap, (GlzUsrImageContext *)(intptr_t)1, &dctx);
    printf("  glz_encode: %d bytes, usr->error called %d time(s) during encode\n",
           size, errors - before);
    printf("  VERDICT: %s\n", errors ? "SERVER WOULD ABORT" : "clean");
    return 0;
}
