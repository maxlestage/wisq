/* Runs SPICE's own QUIC decoder over a hex stream on stdin and prints the
   pixels it produced. What makes a fixture ground truth rather than an
   expectation. */
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
static int q_more_space(QuicUsrContext *u, uint32_t **p, int r) { (void)u;(void)p;(void)r; return 0; }
static int q_more_lines(QuicUsrContext *u, uint8_t **l) { (void)u;(void)l; return 0; }

int main(int argc, char **argv) {
    static char hex[1 << 22];
    if (!fgets(hex, sizeof hex, stdin)) return 1;
    size_t len = strlen(hex);
    while (len && (hex[len-1] == '\n' || hex[len-1] == '\r')) hex[--len] = 0;

    size_t n = len / 2;
    uint8_t *raw = malloc(n + 4);
    for (size_t i = 0; i < n; i++) {
        unsigned v; sscanf(hex + i * 2, "%2x", &v); raw[i] = (uint8_t)v;
    }

    QuicUsrContext usr = { q_error, q_warn, q_info, q_malloc, q_free,
                           q_more_space, q_more_lines };
    QuicContext *quic = quic_create(&usr);
    QuicImageType type; int w, h;
    if (quic_decode_begin(quic, (uint32_t *)raw, (unsigned)(n / 4), &type, &w, &h) != QUIC_OK) {
        fprintf(stderr, "decode_begin failed\n"); return 3;
    }
    fprintf(stderr, "type=%d w=%d h=%d\n", (int)type, w, h);

    /* 32-bit out is what the canvas asks for, except for GRAY, which the
       codec only ever writes as one byte per pixel. */
    int outType = (argc > 1) ? atoi(argv[1])
                : (type == QUIC_IMAGE_TYPE_GRAY ? QUIC_IMAGE_TYPE_GRAY : QUIC_IMAGE_TYPE_RGB32);
    int bpp = (outType == QUIC_IMAGE_TYPE_GRAY) ? 1 : 4;
    int stride = w * bpp;
    uint8_t *out = calloc(1, (size_t)stride * h);
    if (quic_decode(quic, (QuicImageType)outType, out, stride) != QUIC_OK) {
        fprintf(stderr, "decode failed\n"); return 4;
    }
    for (size_t i = 0; i < (size_t)stride * h; i++) printf("%02x", out[i]);
    printf("\n");
    quic_destroy(quic);
    return 0;
}
