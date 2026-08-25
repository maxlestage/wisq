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
* `qbits.c` traces the bit reader: it prints `io_word` and
  `io_available_bits` after `init_decode_io` and after each
  `decode_eatbits(len)`, for lengths given on the command line. Comparing only
  a final answer would let a reader be wrong in the middle and right at the
  end; this says which call diverged.
* `qmodel.c` dumps the adaptive model: the bucket layout `find_model_params`
  and `fill_model_structures` produce, the `tabrand` draws, `set_wm_trigger`
  across its whole index range, and an `update_model` trace under a fixed
  sequence. It also sets `wm_trigger` **by hand** to reach the halving
  boundary exactly — `set_wm_trigger` can only produce eleven tabulated
  values, and no ordinary sequence lands on one of them, so without that the
  difference between halving on `>` and on `>=` is untestable.
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
cc -I. -Icommon -Ispice $(pkg-config --cflags glib-2.0) \
   -o qbits qbits.c qstub.c $(pkg-config --libs glib-2.0)
cc -I. -Icommon -Ispice $(pkg-config --cflags glib-2.0) \
   -o qmodel qmodel.c qstub.c $(pkg-config --libs glib-2.0)

# type: 1 gray, 2 rgb16, 3 rgb24, 4 rgb32, 5 rgba
./qgen 4 8 6 1 > stream.hex 2> original.hex
./qdec < stream.hex > decoded.hex
./qfam > families.txt
./qbits 16 16 3 31 1 < stream.hex > trace.txt
./qmodel > model.txt
```

The seven cases in `SpiceQUICFixtures.swift`, with the arguments that produce
them. `qdec` takes the output type: gray and rgba decode only to themselves,
everything else to 32-bit.

| case | qgen | qdec |
| --- | --- | --- |
| `rgb32 8x6` | `./qgen 4 8 6 1` | `./qdec` |
| `rgb32 32x24` | `./qgen 4 32 24 7` | `./qdec` |
| `rgb24 16x12` | `./qgen 3 16 12 3` | `./qdec` |
| `rgb16 16x12` | `./qgen 2 16 12 11` | `./qdec` |
| `gray 16x12` | `./qgen 1 16 12 5` | `./qdec 1` |
| `rgba 24x18` | `./qgen 5 24 18 3` | `./qdec 5` |
| `rgb32 64x96` | `./qgen 4 64 96 9` | `./qdec` |

The last two are there for the decode loop rather than for coverage of the
formats: `rgba` is the only type that decodes as two passes per row, and
64×96 is 6144 pixels, enough for the wait mask to advance three times. Nothing
smaller reaches that path at all — it takes 2048 pixels to advance once.

A third thing the harness taught, this one the hard way:

* **The generator drifted from the fixtures.** The table above was added after
  finding that `./qgen 1 16 12 5` no longer produced the committed `gray 16x12`
  stream. The five original fixtures still verified against the reference
  decoder — they were honest — but the `qgen.c` committed here had been tidied
  before the commit without regenerating them, so its pseudo-random noise band
  no longer matched. All seven were regenerated with the harness as it now
  stands, and the rebuild instructions above reproduce every one of them byte
  for byte. Fixtures that cannot be rebuilt are fixtures nobody can check.
