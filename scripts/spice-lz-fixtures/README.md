# Where `Tests/WisqRemoteTests/SpiceLZFixtures.swift` comes from

The LZ fixtures are not hand-written. They are produced by SPICE's own
encoder, and checked by SPICE's own decoder, because a fixture written by the
same person who wrote the decoder can only confirm that they made the same
assumptions twice. Two of the mistakes wisq's decoder actually made — reading
four bytes per `rgb32` literal instead of three, and dropping the per-type
length bias — would have survived a hand-written fixture and produced an image
that was almost right.

`gen.c` links `spice-common/common/lz.c` and compresses images built to contain
flat bands, a repeating pattern and pseudo-random noise, so that literal runs,
short matches, long matches and the two-byte far distance all occur. It writes
the stream to stdout and the original pixels, as hex, to stderr.

`dec.c` runs the reference *decoder* over a stream on stdin. It is what makes
hand-crafted streams usable: the far-distance boundary — a match whose low
distance byte is 255 while the control byte's five distance bits are not all
ones — does not appear in encoder output at these sizes, so that one fixture is
crafted and then validated against this, rather than against an expectation.

To rebuild them:

```sh
git clone https://gitlab.freedesktop.org/spice/spice-common
git clone https://gitlab.freedesktop.org/spice/spice-protocol
mkdir -p build && cd build
cp -r ../spice-common/common . && cp -r ../spice-protocol/spice .
touch config.h
cc -I. -Icommon -Ispice $(pkg-config --cflags glib-2.0) \
   -o gen ../gen.c common/lz.c $(pkg-config --libs glib-2.0) -w
./gen 8 8 8 1 > rgb32_8x8.lz 2> rgb32_8x8.hex     # 8 = LZ_IMAGE_TYPE_RGB32
./gen 7 40 30 3 > rgb24_40x30.lz 2> rgb24_40x30.hex  # 7 = LZ_IMAGE_TYPE_RGB24
```

`gen.c` zeroes every fourth byte of an `rgb32` source. That byte is padding the
codec never transmits and always writes back as zero, so leaving it set would
mean comparing against bytes the format does not carry.

`spice_log` is stubbed in both files: it is the only symbol `lz.c` needs from
spice-common's logging, and aborting on a fatal log is right here — a stream
produced after an assertion failed is not one worth keeping.

## The palette forms

`genplt.c` does the same for the palette-indexed streams, and does one more
thing: it runs the reference *decoder* over what it produced and prints the
RGB32 pixels. That is what makes the palette fixtures checkable at all — three
of the rules produce an image when written backwards rather than an error:

* a 4-bit `LE` byte gives the low nibble first, `BE` the high one;
* a 1-bit `LE` byte starts at bit 0, `BE` at bit 7;
* the palette is little-endian while the LZ stream header above it is
  big-endian, because the palette belongs to the display channel's message and
  the stream to the codec.

Get any of them backwards and you get a picture: mirrored in pairs, mirrored in
groups of eight, or in the wrong colours. Nothing throws. So each was checked
against this harness's output *before* the decoder was written, rather than
after.

```sh
cc -I. -Icommon -Ispice $(pkg-config --cflags glib-2.0) \
   -o genplt ../genplt.c common/lz.c $(pkg-config --libs glib-2.0) -w
./genplt 5 8 6 3 > plt8.lz 2> plt8.txt     # 5 = PLT8; 3/4 = PLT4 LE/BE; 1/2 = PLT1 LE/BE
```

stdout is the stream. stderr carries two lines: `PALETTE <hex>`, the colour
table as it travels, and `RGB32 <hex>`, what the reference decoder made of the
two together.

