/* canvas_get_lz4()'s loop, minus pixman: reads a SPICE LZ4 payload on stdin as
 * hex and prints the packed rows it decodes to. The point is to have a second
 * opinion that is not the generator's. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include "lz4.h"

int main(int argc, char **argv) {
    if (argc < 3) { fprintf(stderr, "usage: l4dec <width> <height>\n"); return 2; }
    int width = atoi(argv[1]), height = atoi(argv[2]);

    static char hex[1 << 22];
    if (!fgets(hex, sizeof hex, stdin)) return 2;
    int len = strlen(hex); while (len && (hex[len-1] == '\n' || hex[len-1] == '\r')) hex[--len] = 0;
    int n = len / 2;
    uint8_t *data = malloc(n);
    for (int i = 0; i < n; i++) { unsigned b; sscanf(hex + 2*i, "%2x", &b); data[i] = (uint8_t)b; }

    uint8_t *end = data + n;
    if (n < 2) { fprintf(stderr, "missing header\n"); return 1; }
    int topDown = !!*data++;
    uint8_t format = *data++;
    int strideEncoded = width;
    switch (format) {
        case 6: strideEncoded *= 2; break;
        case 7: strideEncoded *= 3; break;
        case 8: case 9: strideEncoded *= 4; break;
        default: fprintf(stderr, "unsupported format %d\n", format); return 1;
    }
    int available = strideEncoded * height;
    uint8_t *dest = calloc(available, 1), *bits = dest;
    LZ4_streamDecode_t *stream = LZ4_createStreamDecode();
    do {
        if (data + 4 > end) { fprintf(stderr, "truncated length\n"); return 1; }
        int enc = (data[0] << 24) | (data[1] << 16) | (data[2] << 8) | data[3];
        data += 4;
        if (enc < 0 || end - data < enc) { fprintf(stderr, "truncated block\n"); return 1; }
        int dec = LZ4_decompress_safe_continue(stream, (const char *)data, (char *)dest, enc, available);
        if (dec <= 0) { fprintf(stderr, "block error %d\n", dec); return 1; }
        dest += dec; available -= dec; data += enc;
    } while (data < end);
    LZ4_freeStreamDecode(stream);

    fprintf(stderr, "topDown %d format %d left %d\n", topDown, format, available);
    int total = strideEncoded * height;
    for (int i = 0; i < total; i++) printf("%02x", bits[i]);
    printf("\n");
    return 0;
}
