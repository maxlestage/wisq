#!/usr/bin/env python3
"""Checks wisq's one-line ternary raster operation against the reference's 256.

`common/rop3.c` in spice-common does not evaluate a truth table. It registers a
handler per opcode, generated from the formula written beside it:

    ROP3_HANDLERS(DPSoon, ~(*pat | *src | *dest), 0x01);

wisq evaluates

    result = (opcode >> ((pattern << 2) | (source << 1) | destination)) & 1

instead. This script reads the reference's formulas out of `rop3.c` and checks
that claim against every one of them, over all eight combinations of the three
operand bits.

It also checks the second claim wisq's comment makes: that the opcodes the
reference leaves unimplemented are exactly the ones ignoring an operand.

Usage:  curl -sO <rop3.c>  &&  ./check-rop3.py rop3.c
"""
import re
import sys


def evaluate(formula: str, pattern: int, source: int, destination: int) -> int:
    """The reference's C formula, over one bit.

    Over a single bit `~x` is `1 - x`, and C's precedence for `&`, `|` and `^`
    matches Python's, so the substituted text evaluates directly. The formulas
    are otherwise fully parenthesised.
    """
    expression = (formula
                  .replace("*pat", str(pattern))
                  .replace("*src", str(source))
                  .replace("*dest", str(destination))
                  .replace("~", "1-"))
    return eval(expression) & 1  # noqa: S307 - the input is this repo's own C


def ignores(opcode: int, operand: int) -> bool:
    """Whether flipping one operand never changes the result. 0=P, 1=S, 2=D."""
    for first in (0, 1):
        for second in (0, 1):
            bits = [first, second]
            bits.insert(operand, 0)
            low = (bits[0] << 2) | (bits[1] << 1) | bits[2]
            bits[operand] = 1
            high = (bits[0] << 2) | (bits[1] << 1) | bits[2]
            if (opcode >> low) & 1 != (opcode >> high) & 1:
                return False
    return True


def main() -> int:
    path = sys.argv[1] if len(sys.argv) > 1 else "rop3.c"
    rows = re.findall(
        r"^ROP3_HANDLERS\((\w+),\s*(.+?),\s*(0x[0-9a-fA-F]+)\);",
        open(path).read(), re.M,
    )
    if not rows:
        print(f"no ROP3_HANDLERS lines in {path}")
        return 2

    disagreements = []
    for name, formula, text in rows:
        opcode = int(text, 16)
        for pattern in (0, 1):
            for source in (0, 1):
                for destination in (0, 1):
                    index = (pattern << 2) | (source << 1) | destination
                    want = (opcode >> index) & 1
                    got = evaluate(formula, pattern, source, destination)
                    if got != want:
                        disagreements.append(
                            f"{name} {text}: p{pattern}s{source}d{destination} "
                            f"formula={got} table={want}"
                        )

    registered = {int(text, 16) for _, _, text in rows}
    absent = sorted(c for c in range(256) if c not in registered)
    degenerate = sorted(
        c for c in range(256) if any(ignores(c, operand) for operand in range(3))
    )

    print(f"formulas read              : {len(rows)}")
    print(f"disagreements with the table: {len(disagreements)}")
    for line in disagreements[:10]:
        print("   ", line)
    print(f"opcodes the reference omits : {len(absent)}")
    print(f"opcodes ignoring an operand : {len(degenerate)}")
    print(f"the two sets are identical  : {absent == degenerate}")
    return 1 if disagreements or absent != degenerate else 0


if __name__ == "__main__":
    sys.exit(main())
