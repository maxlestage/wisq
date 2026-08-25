# Where the GLZ fixtures come from

GLZ is the one SPICE codec whose decoder does **not** live in spice-common.
`quic.c` and `lz.c` ship there; GLZ's decoder is in spice-gtk
(`src/decode-glz.c`), and its encoder is in spice-server
(`server/glz-encoder.c`). Both are needed here, because neither side alone can
produce a checkable fixture.

## Why a sequence, and not an image

A single image cannot contain a cross-image match, and the cross-image match is
the entire difference between GLZ and LZ. So the fixtures are **sequences**
encoded against one shared dictionary.

That the sequence really exercises that path is measured, not assumed. The same
four images, encoded each against a fresh dictionary and then against a shared
one:

| image | fresh dictionary | shared dictionary |
| --- | --- | --- |
| 0 | 615 | 615 |
| 1 | 615 | 201 |
| 2 | 615 | 205 |
| 3 | 615 | 194 |

The difference is cross-image matching and nothing else.

## The trap this harness fell into first

**The GLZ dictionary stores pointers into the caller's pixel buffers.** It does
not copy them. Encoding a sequence out of one reused buffer makes the encoder
match image *N* against memory that by then holds image *N+1*, and it emits a
match that is correct about nothing. The streams still decode; they decode to
an image the encoder never saw.

It showed up as images 1–3 round-tripping to image 0's content in the band that
should have been new, and as absurd stream sizes — 51 bytes where honest
encoding gives about 200. `gzgen.c` therefore allocates one buffer per image
and keeps every one of them alive for the encoder's lifetime.

## The header is not LZ's

`lz_encode` writes seven 32-bit words — magic, version, type, width, height,
stride, top_down — 28 bytes, and leaves a comment wondering whether type and
top_down could share a byte. GLZ does share them, and adds the image id as 64
bits and `win_head_dist` as 32 more. 33 bytes, big-endian, laid out
differently. Confirmed by parsing what `gzgen` produces, not only by reading
the C.

## Files

* `gzgen.c` — encodes N images against one dictionary. Streams to stdout as
  hex, one per line; the original pixels to stderr, likewise.
* `gzdec.c` — runs the reference *decoder* over a whole sequence through one
  window, which is the only way a cross-image reference can resolve. What it
  prints is the `decoded` expectation.
* Stub headers (`gio-coroutine.h`, `spice-util.h`, `decode.h`) — spice-gtk's
  decoder reaches for its coroutine machinery and its canvas. Only two things
  are actually needed: `g_coroutine_condition_wait`, which suspends until the
  referenced image arrives and is already satisfied when images are fed in id
  order, and `alloc_lz_image_surface`, which only has to put the pixels
  somewhere readable. Both are stubbed; the decode path itself is untouched
  reference code.

## To rebuild

```sh
git clone --depth 1 https://gitlab.freedesktop.org/spice/spice.git spice-server
git clone --depth 1 https://gitlab.freedesktop.org/spice/spice-gtk.git
git clone --depth 1 https://gitlab.freedesktop.org/spice/spice-common.git
git clone --depth 1 https://gitlab.freedesktop.org/spice/spice-protocol.git

mkdir -p build && cd build
cp -r ../spice-common/common . && cp -r ../spice-protocol/spice .
cp ../spice-server/server/glz-encoder*.[ch] ../spice-server/server/glz-encode*.tmpl.c .
cp ../spice-gtk/src/decode-glz.c ../spice-gtk/src/decode-glz-tmpl.c .
cp ../wisq/scripts/spice-glz-fixtures/* .
cp ../wisq/scripts/spice-quic-fixtures/qstub.c .   # spice_log, same stub as QUIC uses
touch config.h

CF="-I. -Icommon -Ispice $(pkg-config --cflags glib-2.0 pixman-1)"
cc $CF -c glz-encoder.c -o glz-encoder.o
cc $CF -c glz-encoder-dict.c -o glz-encoder-dict.o
cc $CF -c decode-glz.c -o decode-glz.o
cc $CF -o gzgen gzgen.c glz-encoder.o glz-encoder-dict.o qstub.c \
   $(pkg-config --libs glib-2.0) -lpthread
cc $CF -o gzdec gzdec.c decode-glz.o $(pkg-config --libs glib-2.0 pixman-1)

./gzgen 16 12 4 1 > seq.hex 2> seq.orig
./gzdec < seq.hex > seq.dec
```

`seq.dec` must equal `seq.orig` line for line. It does.
