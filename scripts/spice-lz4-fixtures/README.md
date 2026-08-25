# Where the LZ4 fixtures come from

LZ4 is the odd one out among the display channel's codecs. LZ, GLZ and QUIC are
SPICE's own and exist nowhere else; this is stock LZ4 with a two-byte header in
front and a big-endian length before each block. So the harness here is not a
port of anything — it is the server's own `lz4_encode` loop
(`spice/server/lz4-encoder.c`) driving upstream lz4, and the client's own
`canvas_get_lz4` loop (`spice-common/common/canvas_base.c`) reading it back.

## The one thing that is easy to get wrong

**The blocks share a dictionary.** `lz4_encode` creates one `LZ4_stream_t` per
image and calls `LZ4_compress_fast_continue` for every chunk of lines, so a
match in the fourth block routinely names bytes the first one produced. A
decoder that treats each block independently gets a flat image exactly right
and a real one wrong in bands.

That is measured here rather than argued. `l4dec.c` was rebuilt with
`LZ4_setStreamDecode(stream, NULL, 0)` inserted before every block, and the
column below records which fixtures then came out wrong. Seven of eleven did.

## Every fixture, and the command that rebuilds it

| fixture | size | fmt | top-down | lines/block | payload | rows | shared dictionary | command |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `crossBlock` | 24×12 | 8 | yes | 4 | 720 | 1152 | **required** | `L4MODE=cross ./l4gen 24 12 4` |
| `independent` | 24×12 | 8 | yes | 4 | 92 | 1152 | not needed | `L4MODE=flat ./l4gen 24 12 4` |
| `longRuns` | 24×12 | 8 | yes | 4 | 53 | 1152 | **required** | `L4MODE=runs ./l4gen 24 12 4` |
| `shortOffsets` | 24×12 | 8 | yes | 4 | 50 | 1152 | **required** | `L4MODE=near ./l4gen 24 12 4` |
| `incompressible` | 24×12 | 8 | yes | 4 | 1175 | 1152 | not needed | `L4MODE=noise ./l4gen 24 12 4` |
| `oneBlock` | 24×12 | 8 | yes | 12 | 704 | 1152 | not needed | `L4MODE=cross ./l4gen 24 12 12` |
| `manyBlocks` | 40×16 | 8 | yes | 2 | 1539 | 2560 | **required** | `L4MODE=cross ./l4gen 40 16 2` |
| `fiveFiveFive` | 24×12 | 6 | yes | 4 | 383 | 576 | **required** | `L4MODE=cross L4FMT=6 ./l4gen 24 12 4` |
| `threeBytes` | 24×12 | 7 | yes | 4 | 552 | 864 | **required** | `L4MODE=cross L4FMT=7 ./l4gen 24 12 4` |
| `withAlpha` | 24×12 | 9 | yes | 4 | 720 | 1152 | **required** | `L4MODE=cross L4FMT=9 ./l4gen 24 12 4` |
| `bottomUp` | 24×12 | 8 | no | 4 | 720 | 1152 | **required** | `L4MODE=cross L4TD=0 ./l4gen 24 12 4` |

Three of them are the *same compressed blocks* and differ only in a header
byte: `crossBlock`, `withAlpha` (format 9 instead of 8) and `bottomUp`
(direction 0 instead of 1). That is deliberate — it makes "is the byte read at
all?" a test with nothing else moving.

Two more fixtures are written by hand rather than generated, because no encoder
produces them: a block with a literal run of exactly fourteen (the value that
separates "the nibble is the length" from "the nibble is the escape"), and a
zero distance. Both were run through `l4dec` before being written down; they
live in the test file rather than here.

## The modes, and the paths that needed them

| mode | content | what it reaches |
| --- | --- | --- |
| `cross` | each row repeats one five above it, over noise | matches across block boundaries, long literal runs |
| `flat` | one byte value per row | short offsets, matches that need no shared dictionary |
| `runs` | identical stretches of 700 bytes | match lengths past 19, so the extension bytes |
| `near` | period 3 | offsets below 8, the overlapping copy |
| `noise` | an LCG | all literals, and a payload larger than the image |

A third reading of the block format, written separately in Python, decodes all
eleven and agrees with lz4 byte for byte. It also counts what each one reaches:

| | blocks | sequences | literal ext. | match ext. | offset < 8 | match into an earlier block |
| --- | --- | --- | --- | --- | --- | --- |
| `crossBlock` | 3 | 7 | 4 | 4 | 0 | 4 |
| `independent` | 3 | 15 | 0 | 12 | 12 | 0 |
| `longRuns` | 3 | 7 | 0 | 4 | 4 | 2 |
| `shortOffsets` | 3 | 6 | 0 | 3 | 1 | 2 |
| `incompressible` | 3 | 3 | 3 | 0 | 0 | 0 |
| `manyBlocks` | 8 | 15 | 7 | 7 | 0 | 7 |

## Two places wisq decides differently from the reference

Both were found by differential fuzzing — 400 000 random blocks and 150 000
mutations of real payloads, every one run through both decoders — rather than
by reading the C.

* **A short decode.** `canvas_get_lz4` does not check that the blocks fill the
  surface. What they do not reach keeps whatever pixman's allocation held, and
  is drawn. wisq refuses: 1 101 of the mutations landed here.
* **A zero distance.** The block format calls it a corrupted block, but lz4's
  decoder does not reject one — `LZ4_write32(op, 0)` on the short-offset path
  makes it copy zeroes instead. The reference client draws a black band; wisq
  refuses.

Everything else agreed: 103 184 payloads decoded identically, 45 709 were
refused by both.

The same fuzz answered a question the sabotage pass raised. lz4's rule that a
match may not finish inside the last five bytes of the output is **unreachable**
— removing it changed no outcome in any of the 550 000 payloads, and the
arithmetic for why is in `SpiceLZ4Tests`.

## Files

* `l4gen.c` — the server's encoding loop. Prints the payload and the packed
  rows it was built from, as hex.
* `l4dec.c` — the client's decoding loop, minus pixman. Prints the packed rows
  it read back. What it produces is the `rows` expectation.

## To rebuild

lz4 is not vendored here. Fetch the version you want to encode with — the block
format is stable, so any of them produce streams this decoder reads, but the
bytes of a given fixture come from a given version.

```sh
mkdir -p build && cd build
curl -sO https://raw.githubusercontent.com/lz4/lz4/v1.10.0/lib/lz4.c
curl -sO https://raw.githubusercontent.com/lz4/lz4/v1.10.0/lib/lz4.h
cp ../wisq/scripts/spice-lz4-fixtures/*.c .

cc -O2 -I. -o l4gen l4gen.c lz4.c
cc -O2 -I. -o l4dec l4dec.c lz4.c

L4MODE=cross ./l4gen 24 12 4 > cross.txt
sed -n 3p cross.txt | ./l4dec 24 12 > cross.dec
sed -n 5p cross.txt > cross.orig
```

`cross.dec` must equal `cross.orig`. It does, for all eleven.
