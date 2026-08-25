# Where the QUIC fixtures come from

QUIC is SPICE's own codec, and it has no second implementation anywhere to
disagree with. So the encoder it shipped with is the only honest authority
available, and everything in `Tests/WisqRemoteTests/SpiceQUICFixtures.swift`
and `SpiceQUICFamilyFixtures.swift` is produced by it rather than written here.

* `qgen.c` links `spice-common/common/quic.c` and compresses images built from
  flat bands, a gradient and pseudo-random noise, so the adaptive model meets
  runs, smooth prediction and surprises in one image. The stream goes to
  stdout as hex; the original pixels to stderr.
* `qdec.c` runs the reference *decoder* over a stream on stdin. Every fixture
  is round-tripped through it, and what it prints is the `decoded` field — an
  expectation taken from the codec rather than from a reading of it.
* `qfam.c` `#include`s `quic.c` rather than linking it, because the family
  tables are file-static: the point is to read the very arrays `family_init`
  filled in, not to recompute them from a second reading of the same C.
* `qstub.c` supplies `spice_log`, which `quic.c` calls and which lives
  elsewhere in spice-common.

Two things the harness taught, both recorded in the fixtures:

* **`rgb32` never transmits the fourth byte.** The decoder writes zero there,
  so `decoded` has zero there, whatever the original held. Comparing against
  the original would be comparing against bytes the format does not carry.
* **`gray` decodes only to `gray`.** Asking `quic_decode` for 32-bit output
  from a gray stream returns an error; it is the one form whose output is one
  byte per pixel. `qdec.c` picks the output format accordingly.

To rebuild them:

```sh
git clone https://gitlab.freedesktop.org/spice/spice-common
git clone https://gitlab.freedesktop.org/spice/spice-protocol
mkdir -p build && cd build
cp -r ../spice-common/common . && cp -r ../spice-protocol/spice .
cp ../wisq/scripts/spice-quic-fixtures/*.c .
cp common/quic*.c common/quic*.h .
touch config.h

cc -I. -Icommon -Ispice $(pkg-config --cflags glib-2.0) \
   -o qgen qgen.c quic.c qstub.c $(pkg-config --libs glib-2.0)
cc -I. -Icommon -Ispice $(pkg-config --cflags glib-2.0) \
   -o qdec qdec.c quic.c qstub.c $(pkg-config --libs glib-2.0)
cc -I. -Icommon -Ispice $(pkg-config --cflags glib-2.0) \
   -o qfam qfam.c qstub.c $(pkg-config --libs glib-2.0)

# type: 1 gray, 2 rgb16, 3 rgb24, 4 rgb32, 5 rgba
./qgen 4 8 6 1 > stream.hex 2> original.hex
./qdec < stream.hex > decoded.hex
./qfam > families.txt
```
