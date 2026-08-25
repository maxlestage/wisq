/* DRAW_ALPHA_BLEND's compositing, exactly as spice-common performs it.
 *
 * __blend_image() in sw_canvas.c builds a solid mask whose alpha is the
 * message's overall alpha (only when it is not 0xff) and calls
 * pixman_image_composite32(PIXMAN_OP_OVER, src, mask, dest, ...). That is the
 * whole of it, so this harness is that call and nothing else — the point being
 * that pixman's rounding is pixman's, not something to be guessed at.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <pixman.h>

/* One pixel through the reference path. Returns the composited ARGB word. */
static uint32_t blend(uint32_t src, uint32_t dst, int overall, int destHasAlpha) {
    uint32_t s = src, d = dst;
    pixman_image_t *si = pixman_image_create_bits(PIXMAN_a8r8g8b8, 1, 1, &s, 4);
    pixman_image_t *di = pixman_image_create_bits(
        destHasAlpha ? PIXMAN_a8r8g8b8 : PIXMAN_x8r8g8b8, 1, 1, &d, 4);
    pixman_image_t *mask = NULL;
    if (overall != 0xff) {
        pixman_color_t colour = {0, 0, 0, 0};
        colour.alpha = overall * 0x101;
        mask = pixman_image_create_solid_fill(&colour);
    }
    pixman_image_set_repeat(si, PIXMAN_REPEAT_NONE);
    pixman_image_composite32(PIXMAN_OP_OVER, si, mask, di, 0, 0, 0, 0, 0, 0, 1, 1);
    uint32_t out = d;
    if (mask) pixman_image_unref(mask);
    pixman_image_unref(si);
    pixman_image_unref(di);
    return out;
}

/* The formula wisq implements, per channel, on premultiplied bytes.
 * MUL_UN8 and DIV_ONE_UN8 are pixman's own 8-bit helpers, reproduced here so
 * that whether the rounding matters is a measurement rather than an opinion. */
static inline uint32_t mulUN8(uint32_t a, uint32_t b) {
    uint32_t t = a * b + 0x80;
    return (t + (t >> 8)) >> 8;
}

static uint32_t mine(uint32_t src, uint32_t dst, int overall, int destHasAlpha) {
    uint32_t out = 0;
    uint32_t sa = mulUN8((src >> 24) & 0xFF, overall);
    for (int shift = 0; shift <= 24; shift += 8) {
        uint32_t s = mulUN8((src >> shift) & 0xFF, overall);
        uint32_t d = (dst >> shift) & 0xFF;
        if (shift == 24 && !destHasAlpha) d = 255;
        uint32_t v = s + mulUN8(d, 255 - sa);
        if (v > 255) v = 255;
        out |= v << shift;
    }
    if (!destHasAlpha) {
        /* The destination is x8r8g8b8: pixman gives it an implicit alpha of 1
         * for the arithmetic and reads it back as opaque. */
        out = (out & 0x00FFFFFF) | 0xFF000000;
    }
    return out;
}

int main(int argc, char **argv) {
    if (argc > 1 && strcmp(argv[1], "fixtures") == 0) {
        struct { uint32_t src, dst; int overall, has; } cases[] = {
            {0xFF203040, 0x00806040, 0xFF, 0}, {0x80102030, 0x00806040, 0xFF, 0},
            {0x00000000, 0x00806040, 0xFF, 0}, {0xFF203040, 0x00806040, 0x00, 0},
            {0xFF203040, 0x00806040, 0x80, 0}, {0x80102030, 0x00806040, 0x40, 0},
            {0xFF203040, 0x00806040, 0x01, 0}, {0x40101010, 0x00FFFFFF, 0xFF, 0},
            {0x80102030, 0x40201008, 0xFF, 1}, {0x80102030, 0x40201008, 0x80, 1},
            {0xFFFFFFFF, 0x00000000, 0xFF, 1}, {0x00000000, 0xFF806040, 0xFF, 1},
            {0x7F3F1F0F, 0x7F0F1F3F, 0x7F, 1}, {0xFE7E3E1E, 0x01010101, 0xFD, 1},
        };
        int n = sizeof cases / sizeof cases[0];
        for (int i = 0; i < n; i++) {
            uint32_t got = blend(cases[i].src, cases[i].dst, cases[i].overall, cases[i].has);
            printf("Case(source: 0x%08X, destination: 0x%08X, alpha: 0x%02X, "
                   "destinationHasAlpha: %s, expected: 0x%08X),\n",
                   cases[i].src, cases[i].dst, cases[i].overall,
                   cases[i].has ? "true" : "false", got);
        }
        return 0;
    }
    long long checked = 0, differed = 0;
    /* Exhaustive over the two alphas, and a spread over the colour bytes that
     * includes every boundary and a scattering between them. */
    int bytes[] = {0, 1, 2, 3, 5, 8, 13, 21, 34, 55, 89, 128, 144, 200, 233, 250,
                   252, 253, 254, 255};
    int n = sizeof bytes / sizeof bytes[0];
    for (int overall = 0; overall <= 255; overall++) {
        for (int sai = 0; sai < n; sai++) {
            for (int si = 0; si < n; si++) {
                for (int di = 0; di < n; di++) {
                    for (int has = 0; has <= 1; has++) {
                        /* Premultiplied: a channel may not exceed its alpha. */
                        uint32_t sa = bytes[sai];
                        uint32_t sc = bytes[si] > sa ? sa : bytes[si];
                        uint32_t src = sa << 24 | sc << 16 | sc << 8 | sc;
                        /* The destination's own alpha varies too, and only
                         * matters when the message says to read it. Leaving it
                         * opaque — as this harness first did — never exercises
                         * DEST_HAS_ALPHA at all. */
                        for (int dai = 0; dai < n; dai++) {
                        uint32_t da = has ? bytes[dai] : 0xFF;
                        uint32_t dc = bytes[di] > da ? da : bytes[di];
                        uint32_t dst = da << 24 | dc << 16 | dc << 8 | dc;
                        uint32_t a = blend(src, dst, overall, has);
                        uint32_t b = mine(src, dst, overall, has);
                        checked++;
                        if (!has) dai = n;   /* one pass when the flag is clear */
                        if (a != b) {
                            if (differed < 5) {
                                printf("differ src=%08x dst=%08x a=%d hasAlpha=%d "
                                       "pixman=%08x mine=%08x\n",
                                       src, dst, overall, has, a, b);
                            }
                            differed++;
                        }
                        }
                    }
                }
            }
        }
    }
    printf("checked %lld, differed %lld\n", checked, differed);
    return differed ? 1 : 0;
}

/* Appended: `./abref fixtures` prints a table for the Swift tests. Values are
 * chosen to hit the corners — fully transparent and fully opaque sources, an
 * overall alpha of 0, 1, 128 and 255, and a few in between. */
