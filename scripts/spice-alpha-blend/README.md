# Where the alpha-blend expectations come from

`DRAW_ALPHA_BLEND` is the only draw on the display channel that really
composites, and the arithmetic is not SPICE's. `__blend_image` in
`spice-common/common/sw_canvas.c` builds a solid mask whose alpha is the
message's overall alpha — and only when that is not `0xff` — then calls

```c
pixman_image_composite32(PIXMAN_OP_OVER, src, mask, dest, …);
```

So the expectations in `SpiceAlphaBlendTests` are **pixman's output**, produced
by `abref.c` making that exact call. Recomputing the formula in the test would
agree with a wrong formula.

## The thing nobody writes down

**The source is premultiplied.** There is no mention of it in the protocol, in
`canvas_base.c` or in `sw_canvas.c`, and nothing anywhere divides by alpha.
What settles it is the chain: `SPICE_BITMAP_FMT_RGBA` maps to
`PIXMAN_a8r8g8b8` in `spice_bitmap_format_to_pixman`, and pixman's `OVER` is
defined on premultiplied source. Premultiplied is therefore what the pipeline
*means* rather than what anyone stated, and reading it the other way gives
halos — a picture, and a wrong one.

## What was measured

`./abref` runs wisq's formula and pixman side by side over every combination of

* overall alpha 0…255,
* source alpha and destination alpha across a twenty-value spread that includes
  0, 1, 2, 3, 254, 255 and a scattering between,
* source and destination colour bytes over the same spread, with each colour
  clamped to its own alpha so the pixels are legal premultiplied values,
* `DEST_HAS_ALPHA` set and clear.

**43 008 000 combinations, zero differences.**

The first version of this harness left the destination opaque throughout, which
never exercised `DEST_HAS_ALPHA` at all; it reported 4 096 000 agreements and
proved less than it looked. The destination's own alpha varies now.

## pixman's multiply

`MUL_UN8` is `a · b / 255` rounded by adding a half and folding the carry back
in. The two obvious alternatives are both wrong and both wrong *often*:
`(a · b) >> 8` disagrees on tens of thousands of the 65 536 byte pairs, and
`(a · b) / 255` on hundreds. A blend written with either produces an image that
is almost right.

## To rebuild

```sh
cc -O2 -o abref abref.c $(pkg-config --cflags --libs pixman-1)
./abref              # the exhaustive comparison; exits non-zero on a difference
./abref fixtures     # the table pasted into SpiceAlphaBlendTests
```

Built against pixman 0.42.2. The formula is pixman's own `MUL_UN8`, so a
different pixman version would have to change that helper for the comparison to
move.
