#pragma once
#include <glib.h>
#include <pixman.h>
#include <common/lz_common.h>
#include <common/draw.h>

typedef struct SpiceGlzDecoder SpiceGlzDecoder;
typedef struct SpiceGlzDecoderOps SpiceGlzDecoderOps;
typedef struct SpiceGlzDecoderWindow SpiceGlzDecoderWindow;

struct SpiceGlzDecoderOps {
    void (*decode)(SpiceGlzDecoder *decoder, uint8_t *data,
                   SpicePalette *palette, void *usr_data);
};
struct SpiceGlzDecoder { SpiceGlzDecoderOps *ops; };

SpiceGlzDecoderWindow *glz_decoder_window_new(void);
void glz_decoder_window_clear(SpiceGlzDecoderWindow *w);
void glz_decoder_window_destroy(SpiceGlzDecoderWindow *w);
SpiceGlzDecoder *glz_decoder_new(SpiceGlzDecoderWindow *w);
void glz_decoder_destroy(SpiceGlzDecoder *d);
