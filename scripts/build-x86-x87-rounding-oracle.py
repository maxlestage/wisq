#!/usr/bin/env python3
"""Ce que le vrai processeur rend **quand le résultat ne tient pas**, dans les
quatre modes d'arrondi.

Le corpus x87 d'à côté fixe le mot de contrôle à `0x037F` — au plus près — et
ne le change jamais. Tout ce que les trois autres modes décident lui échappe
donc, et c'est justement là que les règles cessent d'être évidentes :

- **Un débordement ne donne pas toujours l'infini.** Trois modes le refusent et
  rendent le plus grand fini : la troncature toujours, l'arrondi vers −∞ pour un
  résultat positif, l'arrondi vers +∞ pour un négatif. wisq écrivait ces trois
  cas dans un `switch` que rien ne couvrait.
- **Un sous-débordement ne donne pas toujours zéro** : le dénormal graduel garde
  des bits jusqu'au bout, et le mode d'arrondi décide du dernier.
- Et l'inexact ordinaire, où les quatre modes se séparent d'une unité.

Les valeurs sont choisies pour tomber dans ces trois zones plutôt que pour
illustrer : le plus grand fini, son voisin, les puissances de deux qui le font
déborder en une multiplication, et les dénormaux qu'une division écrase.
"""

import argparse
import re
import subprocess
import sys
import tempfile
from pathlib import Path

DATA = 0x30001000
SLOTS = 49
FPUSLOTS = 14

REGISTERS = [
    "rax", "rcx", "rdx", "rbx", "rsp", "rbp", "rsi", "rdi",
    "r8", "r9", "r10", "r11", "r12", "r13", "r14", "r15",
]


def raw(significand, exponent):
    return significand.to_bytes(8, "little") + exponent.to_bytes(2, "little")


# Le plus grand fini : mantisse pleine, exposant maximal moins un.
LARGEST = raw(0xFFFFFFFFFFFFFFFF, 0x7FFE)
LARGEST_NEGATIVE = raw(0xFFFFFFFFFFFFFFFF, 0xFFFE)
# Le plus petit normal, et un dénormal d'un seul bit.
SMALLEST = raw(0x8000000000000000, 0x0001)
SMALLEST_NEGATIVE = raw(0x8000000000000000, 0x8001)
TINY = raw(0x0000000000000001, 0x0000)

VALUES = [
    ("max", LARGEST),
    ("-max", LARGEST_NEGATIVE),
    ("2", raw(0x8000000000000000, 0x4000)),
    ("-2", raw(0x8000000000000000, 0xC000)),
    ("1.5", raw(0xC000000000000000, 0x3FFF)),
    ("min normal", SMALLEST),
    ("-min normal", SMALLEST_NEGATIVE),
    ("dénormal", TINY),
    ("3", raw(0xC000000000000000, 0x4000)),
    ("1", raw(0x8000000000000000, 0x3FFF)),
]

# Les paires qui débordent, sous-débordent, ou tombent inexactes. ST(0) est le
# premier de la paire ; les formes `p` écrivent dans ST(1).
PAIRS = [
    (0, 2),    # max × 2 : déborde par le haut
    (0, 4),    # max × 1.5 : déborde aussi, d'un autre montant
    (1, 2),    # -max × 2 : déborde par le bas
    (1, 4),
    (0, 3),    # max × -2 : le signe vient du produit
    (2, 0),    # 2 × max, dans l'autre sens
    (5, 2),    # min normal ÷ 2 : sous-déborde
    (6, 2),
    (7, 2),    # dénormal ÷ 2 : il ne reste rien à garder
    (5, 8),
    (9, 8),    # 1 ÷ 3 : inexact ordinaire, les quatre modes se séparent
    (9, 2),
    (0, 0),    # max × max
    (8, 8),
]

# Les quatre modes, dans les bits 10 et 11 du mot de contrôle. Le reste est
# celui du corpus voisin : toutes les exceptions masquées, précision étendue.
CONTROLS = [
    ("au plus près", 0x037F),
    ("vers -inf", 0x077F),
    ("vers +inf", 0x0B7F),
    ("vers zéro", 0x0F7F),
]

TOP = 6


def image(top, control, registers):
    buffer = bytearray(8 * FPUSLOTS)
    buffer[0:2] = control.to_bytes(2, "little")
    buffer[4:6] = ((top & 7) << 11).to_bytes(2, "little")
    tags = 0xFFFF
    for index in range(len(registers)):
        physical = (top + index) & 7
        tags &= ~(0b11 << (2 * physical)) & 0xFFFF
    buffer[8:10] = tags.to_bytes(2, "little")
    for index, value in enumerate(registers):
        buffer[28 + 10 * index:38 + 10 * index] = value
    return [int.from_bytes(buffer[i * 8:(i + 1) * 8], "little") for i in range(FPUSLOTS)]


def forms():
    """Les quatre opérations qui peuvent sortir de la plage, et rien d'autre.

    Les formes en `p` écrivent dans ST(1) puis dépilent, ce qui met le résultat
    au sommet ; les autres écrivent dans ST(0). Les deux sont là parce que le
    chemin d'assemblage du résultat est le même et que la destination ne l'est
    pas.
    """
    out = []
    for name in ["fmul", "fadd", "fsub", "fdiv"]:
        out += [f"{name}p %st, %st(1)", f"{name} %st(1), %st"]
    return out


def assemble(texts):
    with tempfile.TemporaryDirectory() as directory:
        source = Path(directory) / "cases.s"
        obj = Path(directory) / "cases.o"
        with open(source, "w") as out:
            out.write(".text\n")
            for text in texts:
                out.write(f"    {text}\n")
        subprocess.run(["as", "--64", "-o", str(obj), str(source)], check=True)
        listing = subprocess.run(
            ["objdump", "-d", str(obj)], capture_output=True, text=True, check=True).stdout
    line = re.compile(r"^\s*[0-9a-f]+:\t([0-9a-f]{2}(?: [0-9a-f]{2})*) *\t(.*)$")
    encoded = [
        "".join(match.group(1).split())
        for row in listing.splitlines()
        if (match := line.match(row))
    ]
    if len(encoded) != len(texts):
        raise SystemExit(f"{len(texts)} instructions demandées, {len(encoded)} relues")
    return encoded


def registersFrom(slots):
    buffer = b"".join(value.to_bytes(8, "little") for value in slots)
    return [buffer[28 + 10 * i:38 + 10 * i].hex() for i in range(8)]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output")
    parser.add_argument("--oracle", default="scripts/x86-oracle/oracle")
    arguments = parser.parse_args()

    texts = forms()
    encoded = assemble(texts)

    general = [0xAAAAAAAAAAAAAAAA + i for i in range(16)] + [0x002]
    vectors = [0] * 32

    request = []
    cases = []
    for instruction, hexadecimal in enumerate(encoded):
        for control_index, (_, control) in enumerate(CONTROLS):
            for pair_index, (first, second) in enumerate(PAIRS):
                values = list(general)
                values[6] = DATA
                values += vectors
                values += image(TOP, control, [VALUES[first][1], VALUES[second][1]])
                request.append(hexadecimal + "\t" + "\t".join(f"{v:x}" for v in values))
                cases.append((instruction, control_index, pair_index))

    answer = subprocess.run([arguments.oracle], input="\n".join(request) + "\n",
                            capture_output=True, text=True, check=True).stdout.splitlines()
    if len(answer) != len(cases):
        raise SystemExit(f"{len(cases)} cas envoyés, {len(answer)} verdicts reçus")

    with open(arguments.output, "w") as out:
        out.write("# Ce que le vrai processeur rend quand le résultat ne tient pas.\n")
        out.write("# Voir scripts/build-x86-x87-rounding-oracle.py.\n")
        out.write("# arrondi\t<indice>\t<nom>\t<mot de contrôle>\n")
        out.write("# paire\t<indice>\t<nom de ST(0)>\t<nom de ST(1)>\t<ST(0)>\t<ST(1)>\n")
        out.write("# instr\t<indice>\t<octets>\t<mnémonique>\n")
        out.write("# cas\t<instr>\t<arrondi>\t<paire>\t<sommet>\t<état x87>"
                  "\t<étiquettes>\t<ST0..ST7>\n")
        out.write("#   Le sommet part à %d.\n" % TOP)
        for index, (name, control) in enumerate(CONTROLS):
            out.write("arrondi\t%d\t%s\t%x\n" % (index, name, control))
        for index, (first, second) in enumerate(PAIRS):
            out.write("paire\t%d\t%s\t%s\t%s\t%s\n"
                      % (index, VALUES[first][0], VALUES[second][0],
                         VALUES[first][1].hex(), VALUES[second][1].hex()))
        for index, (hexadecimal, text) in enumerate(zip(encoded, texts)):
            out.write("instr\t%d\t%s\t%s\n" % (index, hexadecimal, text))
        for (instruction, control_index, pair_index), verdict in zip(cases, answer):
            fields = verdict.split("\t")
            after = [int(value, 16) for value in fields[64:64 + SLOTS + FPUSLOTS]]
            fpu = after[SLOTS:]
            status = (fpu[0] >> 32) & 0xFFFF
            tags = fpu[1] & 0xFFFF
            out.write("cas\t%d\t%d\t%d\t%d\t%x\t%x\t%s\n"
                      % (instruction, control_index, pair_index,
                         (status >> 11) & 7, status, tags,
                         "\t".join(registersFrom(fpu))))
    print(f"{len(encoded)} instructions, {len(cases)} cas", file=sys.stderr)


if __name__ == "__main__":
    main()
