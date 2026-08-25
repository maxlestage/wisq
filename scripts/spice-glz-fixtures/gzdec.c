/* Runs the reference GLZ decoder over a SEQUENCE of streams sharing one
   window, which is the only way a cross-image match can be exercised. One
   hex stream per input line; one hex image per output line. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pixman.h>
#include "decode.h"

/* The real one allocates through the canvas. Here the pixels only have to
   land somewhere the decoder can read back, so a plain buffer will do. */
pixman_image_t *alloc_lz_image_surface(void *canvas_data,
                                       pixman_format_code_t format,
                                       int width, int height, int gross_pixels,
                                       int top_down)
{
    (void)canvas_data; (void)top_down;
    int stride = gross_pixels / height * 4;
    uint8_t *data = calloc(1, (size_t)stride * height);
    return pixman_image_create_bits(format, width, height, (uint32_t *)data, stride);
}

int main(void) {
    static char hex[1 << 22];
    SpiceGlzDecoderWindow *w = glz_decoder_window_new();
    SpiceGlzDecoder *d = glz_decoder_new(w);

    while (fgets(hex, sizeof hex, stdin)) {
        size_t len = strlen(hex);
        while (len && (hex[len-1] == '\n' || hex[len-1] == '\r')) hex[--len] = 0;
        if (!len) continue;
        size_t n = len / 2;
        uint8_t *raw = malloc(n);
        for (size_t i = 0; i < n; i++) {
            unsigned v; sscanf(hex + i * 2, "%2x", &v); raw[i] = (uint8_t)v;
        }
        /* width/height come out of the stream's own header, so read them the
           same way the decoder does, only to size the dump. */
        uint32_t width  = (raw[9]<<24)|(raw[10]<<16)|(raw[11]<<8)|raw[12];
        uint32_t height = (raw[13]<<24)|(raw[14]<<16)|(raw[15]<<8)|raw[16];

        d->ops->decode(d, raw, NULL, NULL);

        /* The decoded image is the newest in the window. */
        extern uint8_t *glz_last_image_data(SpiceGlzDecoderWindow *w);
        uint8_t *out = glz_last_image_data(w);
        if (!out) { fprintf(stderr, "no image\n"); return 3; }
        for (size_t i = 0; i < (size_t)width * height * 4; i++) printf("%02x", out[i]);
        printf("\n");
        free(raw);
    }
    glz_decoder_destroy(d);
    glz_decoder_window_destroy(w);
    return 0;
}
