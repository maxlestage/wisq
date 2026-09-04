#!/usr/bin/env python3
"""Fabrique le verdict du **vrai processeur** sur la pile x87.

Huitième corpus. Une fois le flottant scalaire posé, la course s'arrête sur
`DB /0` — `FILD` — à 3,136 milliards d'instructions, dans le binaire d'Alpine.

    scripts/build-x86-x87-oracle.py Tests/Fixtures/x86-x87-oracle.tsv

**Le cadrage vient d'un comptage, et ce comptage a un piège.** Le vrai usage
x87 de ce système est le `long double` de musl dans `printf` : 627 des 647
`fldt` sont dans `ld-musl`, dans la famille `vasprintf`/`vdprintf`. Avec
`fstpt` 349, `fxch` 285, `fmul` 260, `faddp` 210, `fld` 204, `fld1` 89,
`fldz` 78, `fchs` 77, `fldcw` 49, `fucomip` 49, `fcomip` 49, `fnstsw` 37.

Mais la queue exotique du comptage — `fnsave`, `frstor`, `fldenv`, `fidivrs` —
se compte à vingt-trois ou vingt-six occurrences chacune, une régularité
suspecte, et soixante-neuf d'entre elles sont dans `libcrypto`. libcrypto
n'emploie pas la sauvegarde d'état x87 : c'est **objdump qui décode des tables
de constantes comme du code**, en balayage linéaire. La technique qui avait
bien cadré les six corpus précédents a un mode de défaillance, et il fallait
le voir avant d'écrire cent vingt-cinq formes dont la moitié n'existe pas.

**Ce que ce corpus mesure et qu'aucun autre ne pouvait mesurer :**

- **Une pile, pas des registres.** `ST(0)` n'est pas un registre, c'est le
  sommet ; `ST(i)` désigne `R[(sommet + i) mod 8]`. Chaque `fld` décrémente le
  sommet, chaque `fstp` l'incrémente, et le mot d'étiquettes suit — indexé par
  registre **physique**, alors que l'image de sauvegarde range les registres
  dans l'ordre de la **pile**. Les deux conventions cohabitent, et l'oracle
  les a établies par la mesure.
- **Quatre-vingts bits.** Un `long double` porte soixante-quatre bits de
  mantisse avec son bit entier **explicite** — ce que ni le simple ni le double
  n'ont. Charger un double puis le ranger en étendu n'est pas l'identité.
- **Les drapeaux, par deux chemins.** `FCOMI` les écrit directement ;
  `FCOM` puis `FNSTSW %ax` passe par le mot d'état et RAX. Les deux sont
  employés par musl, et ils ne disent pas la même chose de la même façon.
"""

import argparse
import math
import re
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

DATA = 0x30001000

REGISTERS = [
    "rax", "rcx", "rdx", "rbx", "rsp", "rbp", "rsi", "rdi",
    "r8", "r9", "r10", "r11", "r12", "r13", "r14", "r15",
]

SLOTS = 49
FPUSLOTS = 14


def extended(value):
    """Les dix octets d'un `long double`, fabriqués à la main.

    Le bit entier est **explicite** en quatre-vingts bits, contrairement au
    simple et au double où il est sous-entendu. C'est la différence qui fait
    qu'un chargement suivi d'un rangement n'est pas l'identité.
    """
    if value == 0.0:
        sign = 0x8000 if math.copysign(1, value) < 0 else 0
        return (0).to_bytes(8, "little") + sign.to_bytes(2, "little")
    sign = 0x8000 if value < 0 else 0
    fraction, exponent = math.frexp(abs(value))
    significand = int(fraction * (1 << 64))
    return significand.to_bytes(8, "little") + (sign | exponent - 1 + 16383).to_bytes(2, "little")


def raw(significand, exponent):
    return significand.to_bytes(8, "little") + exponent.to_bytes(2, "little")


# Les valeurs qui font basculer quelque chose. Les quatre dernières n'ont pas
# de littéral : un infini, les deux sortes de NaN, et un dénormal — c'est là
# que les règles se séparent.
VALUES = [
    ("0.0", extended(0.0)),
    ("-0.0", extended(-0.0)),
    ("1.0", extended(1.0)),
    ("-1.0", extended(-1.0)),
    ("2.0", extended(2.0)),
    ("3.0", extended(3.0)),
    ("0.5", extended(0.5)),
    ("-2.5", extended(-2.5)),
    ("1e300", extended(1e300)),
    ("1e-300", extended(1e-300)),
    ("+inf", raw(0x8000000000000000, 0x7FFF)),
    ("-inf", raw(0x8000000000000000, 0xFFFF)),
    ("qNaN", raw(0xC000000000000000, 0x7FFF)),
    ("sNaN", raw(0xA000000000000000, 0x7FFF)),
    ("dénormal", raw(0x0000000000000001, 0x0000)),
    # **Les trois qui séparent cinquante-trois bits de soixante-quatre.**
    # Sans elles, une implémentation qui calculerait en `Double` et
    # reconvertirait passerait sans qu'on le voie : toutes les valeurs
    # au-dessus sont exactement représentables en double, et leurs sommes et
    # produits le restent. Celles-ci ne le sont pas.
    ("1+2⁻⁶³", raw(0x8000000000000001, 0x3FFF)),
    ("π", raw(0xC90FDAA22168C235, 0x4000)),
    ("2⁶⁴-1", raw(0xFFFFFFFFFFFFFFFF, 0x403E)),
]

# Le sommet de départ. Six laisse deux valeurs en place et deux crans pour
# empiler sans déborder ; zéro fait déborder au premier `fld`, ce qui est un
# cas à part et non l'ordinaire.
TOP = 6

CONTROL = 0x037F


def image(top, control, registers):
    """L'image de 108 octets que `FRSTOR` charge.

    `registers` est donné dans l'ordre de la **pile** — ST(0) d'abord — parce
    que c'est ainsi que `FNSAVE` la rend, ce que la mesure a établi. Le mot
    d'étiquettes, lui, est indexé par registre **physique**.
    """
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
    """Les formes à l'essai, cadrées sur ce que l'invité emploie."""
    out = []
    # Les constantes et les copies : ce qui empile sans rien lire.
    out += ["fld1", "fldz", "fld %st(1)", "fld %st(0)"]
    # Les chargements depuis la mémoire, aux trois largeurs. La fenêtre porte
    # un motif connu ; trois décalages donnent trois valeurs différentes.
    for offset in [0x0, 0x8, 0x10]:
        out += [f"flds {offset:#x}(%rsi)", f"fldl {offset:#x}(%rsi)",
                f"fldt {offset:#x}(%rsi)"]
    # Les entiers vers la pile — c'est `FILD` qui a arrêté la course.
    for offset in [0x0, 0x8]:
        out += [f"filds {offset:#x}(%rsi)", f"fildl {offset:#x}(%rsi)",
                f"fildll {offset:#x}(%rsi)"]
    # Les rangements, qui dépilent ou non, aux trois largeurs.
    out += ["fstp %st(1)", "fst %st(1)", "fstp %st(0)"]
    for name in ["fsts", "fstl", "fstps", "fstpl", "fstpt"]:
        out.append(f"{name} 0x20(%rsi)")
    for name in ["fists", "fistl", "fistps", "fistpl", "fistpll"]:
        out.append(f"{name} 0x20(%rsi)")
    # L'arithmétique. Les formes en `p` dépilent après avoir écrit dans ST(1),
    # les autres écrivent dans ST(0) ou dans ST(i) sans dépiler — et `r`
    # renverse les opérandes, ce qui ne se voit que sur une soustraction ou une
    # division.
    for name in ["fadd", "fmul", "fsub", "fsubr", "fdiv", "fdivr"]:
        out += [f"{name} %st(1), %st", f"{name} %st, %st(1)", f"{name}p %st, %st(1)"]
    for name in ["fadds", "fmuls", "fsubs", "fdivs"]:
        out.append(f"{name} 0x20(%rsi)")
    # Le signe et la valeur absolue, qui ne touchent qu'un bit.
    out += ["fchs", "fabs", "fxch %st(1)", "fxch %st(2)"]
    # Les comparaisons, par les deux chemins que musl emprunte.
    out += ["fcomi %st(1), %st", "fcomip %st(1), %st",
            "fucomi %st(1), %st", "fucomip %st(1), %st",
            "fcom %st(1)", "fucom %st(1)", "fnstsw %ax"]
    # Le mot de contrôle : le lire et l'écrire, parce que musl change l'arrondi
    # autour de ses conversions.
    out += ["fnstcw 0x20(%rsi)", "fldcw 0x20(%rsi)"]
    return out


def states():
    """Chaque paire une fois, plus les paires identiques — sans quoi aucune
    comparaison ne rendrait jamais « égal »."""
    count = len(VALUES)
    pairs = [(i, count - 1 - i) for i in range(count)]
    pairs += [(i, (i * 5 + 3) % count) for i in range(count)]
    pairs += [(i, i) for i in range(count)]
    for first, second in pairs:
        yield (first, second)


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


ARITHMETIC_FLAGS = (1 << 0) | (1 << 2) | (1 << 4) | (1 << 6) | (1 << 7) | (1 << 11)


def registersFrom(slots):
    """Les huit registres de l'image rendue, dans l'ordre de la pile."""
    buffer = b"".join(value.to_bytes(8, "little") for value in slots)
    return [buffer[28 + 10 * i:38 + 10 * i].hex() for i in range(8)]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output")
    parser.add_argument("--oracle", default="scripts/x86-oracle/oracle")
    arguments = parser.parse_args()

    texts = forms()
    encoded = assemble(texts)
    chosen = list(states())

    general = [0xAAAAAAAAAAAAAAAA + i for i in range(16)] + [0x002]
    vectors = [0] * 32

    request = []
    cases = []
    for instruction, hexadecimal in enumerate(encoded):
        for index, (first, second) in enumerate(chosen):
            values = list(general)
            values[6] = DATA
            values += vectors
            values += image(TOP, CONTROL, [VALUES[first][1], VALUES[second][1]])
            request.append(hexadecimal + "\t" + "\t".join(f"{v:x}" for v in values))
            cases.append((instruction, index))

    answer = subprocess.run([arguments.oracle], input="\n".join(request) + "\n",
                            capture_output=True, text=True, check=True).stdout.splitlines()
    if len(answer) != len(cases):
        raise SystemExit(f"{len(cases)} cas envoyés, {len(answer)} verdicts reçus")

    window = ("101112131415161718191a1b1c1d1e1f"
              "202122232425262728292a2b2c2d2e2f"
              "303132333435363738393a3b3c3d3e3f"
              "404142434445464748494a4b4c4d4e4f")

    with open(arguments.output, "w") as out:
        out.write("# Ce que le vrai processeur répond sur la pile x87.\n")
        out.write("# Voir scripts/build-x86-x87-oracle.py.\n")
        out.write("# état\t<indice>\t<nom de ST(0)>\t<nom de ST(1)>\t<ST(0)>\t<ST(1)>\n")
        out.write("#   Le sommet part à %d et le mot de contrôle à %#x.\n" % (TOP, CONTROL))
        out.write("# instr\t<indice>\t<octets>\t<mnémonique>\n")
        out.write("# cas\t<instr>\t<état>\t<sommet>\t<état x87>\t<étiquettes>"
                  "\t<ST0..ST7>\t<rax>\t<drapeaux>\t<mémoire>\n")
        out.write("#   Les huit registres sont donnés dans l'ordre de la PILE,\n")
        out.write("#   vingt chiffres chacun : mantisse puis exposant signé.\n")
        out.write("#   « - » quand la fenêtre est restée telle qu'on l'avait posée.\n")
        for index, (first, second) in enumerate(chosen):
            out.write("état\t%d\t%s\t%s\t%s\t%s\n"
                      % (index, VALUES[first][0], VALUES[second][0],
                         VALUES[first][1].hex(), VALUES[second][1].hex()))
        for index, (hexadecimal, text) in enumerate(zip(encoded, texts)):
            out.write("instr\t%d\t%s\t%s\n" % (index, hexadecimal, text))
        for (instruction, index), verdict in zip(cases, answer):
            fields = verdict.split("\t")
            after = [int(value, 16) for value in fields[64:64 + SLOTS + FPUSLOTS]]
            memory = fields[64 + SLOTS + FPUSLOTS]
            for register in [1, 2, 3] + list(range(8, 16)):
                if after[register] != general[register]:
                    raise SystemExit(
                        f"{texts[instruction]} a écrit dans {REGISTERS[register]}")
            fpu = after[SLOTS:]
            status = (fpu[0] >> 32) & 0xFFFF
            tags = fpu[1] & 0xFFFF
            out.write("cas\t%d\t%d\t%d\t%x\t%x\t%s\t%x\t%x\t%s\n"
                      % (instruction, index, (status >> 11) & 7, status, tags,
                         "\t".join(registersFrom(fpu)),
                         after[0], after[16] & ARITHMETIC_FLAGS,
                         "-" if memory == window else memory))
    print(f"{len(encoded)} instructions, {len(cases)} cas", file=sys.stderr)


if __name__ == "__main__":
    main()
