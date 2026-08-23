// zlib ships with every Apple SDK and every Linux distribution we care about, so
// this is a system-library target rather than a vendored copy.
//
// Apple's Compression framework was the obvious alternative and is the wrong tool:
// its COMPRESSION_ZLIB is raw DEFLATE with no zlib header, while RFB's streams are
// zlib-format (RFC 1950). Working around that means hand-stripping headers and
// gives up the identical behaviour we get from linking the real thing on both
// platforms.
#include <zlib.h>
