# Where the ternary raster operation's one line comes from

`common/rop3.c` in spice-common does not evaluate a truth table. It declares a
handler per opcode, generated from a formula written beside it:

```c
ROP3_HANDLERS(DPSoon,  ~(*pat | *src | *dest),      0x01);
ROP3_HANDLERS(DPSona,  ~(*pat | *src) & *dest,      0x02);
…218 of them
```

wisq evaluates one expression instead:

```swift
result = (opcode >> ((pattern << 2) | (source << 1) | destination)) & 1
```

`check-rop3.py` is what makes that a claim rather than a hope. It reads the
formulas out of `rop3.c`, evaluates each over all eight combinations of the
three operand bits, and compares.

**218 formulas, 0 disagreements.**

## The 38 the reference does not implement

`rop3.c` registers 218 of the 256 opcodes. The rest fall through to
`spice_critical("not implemented")`, which aborts.

The script checks a second claim about them: **the 38 missing opcodes are
exactly the 38 that ignore at least one of their three operands.** The two sets
match element for element. They are the ones a server sends as a simpler
message instead — `0xCC` (`SRCCOPY`) as a `DRAW_COPY`, `0xF0` (`PATCOPY`) as a
`DRAW_FILL`, `0x00` as a `DRAW_BLACKNESS`, `0xAA` as nothing at all.

wisq evaluates the table, so all 256 work, including those 38. That is not
ambition: a `switch` over 218 cases plus a crash on the rest would be more code
than the line above and worse.

## The bit order is not the binary operation's

`SpiceROP` indexes its four-bit table as `3 − (2·src + dst)`, counting from the
top. This one indexes directly. Writing either convention in the other's place
produces a mirrored table, which is a picture and a wrong one. Both are pinned
by exhaustive tests, and the ternary one also by the Windows names — `SRCCOPY`
is `0xCC` and means "the source", which is true under exactly one of the two
orders.

## To run

```sh
curl -sO "https://gitlab.freedesktop.org/api/v4/projects/spice%2Fspice-common/repository/files/common%2Frop3.c/raw?ref=master"
mv 'raw?ref=master' rop3.c
./check-rop3.py rop3.c
```

It exits non-zero if any formula disagrees or if the two sets of 38 stop
matching.
