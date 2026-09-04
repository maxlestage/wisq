#!/usr/bin/env python3
"""Fabrique le verdict du **vrai processeur** sur le flottant scalaire.

Le dépôt a refusé la virgule flottante cinq tranches durant, et disait
pourquoi : « le jour où la machine le demandera, elle le dira en s'arrêtant
dessus ». Elle vient de le dire. Une fois `/init` vivant, le SSE2 entier posé
et les déplacements scalaires en place, la course s'arrête sur `0F 2A` —
`CVTSI2SD` — dans le binaire d'Alpine.

    scripts/build-x86-float-oracle.py Tests/Fixtures/x86-float-oracle.tsv

**Le cadrage vient d'un comptage.** Dans les binaires réellement présents chez
l'invité : mulsd 914, addsd 748, mulss 503, subsd 458, addss 331, cvtsi2sd 221,
subss 197, divsd 180, comisd 145, divss 109, cvttsd2si 92, ucomisd 74,
cvtss2sd 63, ucomiss 35, cvtsd2ss 33, cvtsi2ss 27, comiss 23, cvttss2si 9,
maxsd 7, minsd 6.

**Tout est scalaire.** Les formes empaquetées — `addps`, `mulpd`, `sqrtps` —
apparaissent une à trois fois chacune, dans du code que ce démarrage
n'atteint pas. Elles ne sont pas ici, et ce n'est pas un oubli : le jour où
elles seront demandées, la machine s'arrêtera dessus et le dira.

**Ce fichier mesure ce que les six autres interdisaient : les drapeaux.**
Chaque corpus vectoriel jusqu'ici reposait sur la propriété « aucune de ces
instructions ne touche un drapeau », exigée à chaque cas. `UCOMISS` et
`COMISS`, elles, **écrivent** ZF, PF et CF, et effacent OF, SF et AF. Le
fichier garde donc les drapeaux d'après pour chaque cas, et c'est au cœur de
les rendre identiques.

**Et il mesure surtout ce que personne n'écrit à la main.** Additionner deux
flottants, n'importe quel langage le fait. Ce qu'un corpus matériel apporte,
c'est le reste : `0.0 / 0.0`, `-0.0 + 0.0`, un NaN qui traverse un `MAXSD` —
où l'ordre des opérandes décide, contrairement à ce que le nom laisse croire —
la différence entre un NaN silencieux et un NaN signalant devant `COMISD` et
`UCOMISD`, et un flottant trop grand pour l'entier visé, que `CVTTSD2SI` rend
par une valeur bien précise plutôt que par une faute.
"""

import argparse
import re
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

DATA = 0x30001000
ALIGNED = 0x20

REGISTERS = [
    "rax", "rcx", "rdx", "rbx", "rsp", "rbp", "rsi", "rdi",
    "r8", "r9", "r10", "r11", "r12", "r13", "r14", "r15",
]


def double(value):
    return struct.unpack("<Q", struct.pack("<d", value))[0]


def single(value):
    return struct.unpack("<I", struct.pack("<f", value))[0]


def forms():
    """Les formes à l'essai. Chacune ne touche que xmm0, xmm1, RAX et les
    drapeaux."""
    out = []
    # L'arithmétique scalaire. **Seule la partie basse change** : les bits
    # au-dessus de la valeur traitée sont laissés tels quels, et c'est une
    # règle que le nom de l'instruction ne dit pas.
    for name in ["add", "sub", "mul", "div", "min", "max"]:
        for width in ["ss", "sd"]:
            out += [f"{name}{width} %xmm1, %xmm0",
                    f"{name}{width} {ALIGNED:#x}(%rsi), %xmm0"]
    out += ["sqrtss %xmm1, %xmm0", "sqrtsd %xmm1, %xmm0"]
    # Les comparaisons qui écrivent les drapeaux. `COMIS*` et `UCOMIS*` ne
    # diffèrent que sur un point — ce qu'elles font d'un NaN silencieux — et
    # c'est exactement le genre de point qu'une lecture rapide confond.
    for name in ["ucomiss", "ucomisd", "comiss", "comisd"]:
        out += [f"{name} %xmm1, %xmm0", f"{name} {ALIGNED:#x}(%rsi), %xmm0"]
    # Les conversions entre les deux largeurs de flottant.
    out += ["cvtss2sd %xmm1, %xmm0", "cvtsd2ss %xmm1, %xmm0"]
    # De l'entier vers le flottant, aux deux largeurs de chaque côté.
    out += ["cvtsi2ss %eax, %xmm0", "cvtsi2ss %rax, %xmm0",
            "cvtsi2sd %eax, %xmm0", "cvtsi2sd %rax, %xmm0"]
    # Et le retour. `CVTT…` tronque vers zéro ; `CVT…` suit le mode d'arrondi,
    # qui est « au plus proche » par défaut. Les deux sont là parce que les
    # deux sont employées, et parce que leur écart est invisible sur un
    # nombre entier.
    out += ["cvttss2si %xmm1, %eax", "cvttss2si %xmm1, %rax",
            "cvttsd2si %xmm1, %eax", "cvttsd2si %xmm1, %rax",
            "cvtss2si %xmm1, %eax", "cvtsd2si %xmm1, %rax"]
    return out


# Les doubles qui font basculer quelque chose. Le zéro négatif, les infinis,
# les deux sortes de NaN, le plus grand et le plus petit, une valeur qui ne
# tient pas dans un entier, et une qui exige un arrondi.
DOUBLES = [
    0.0, -0.0, 1.0, -1.0, 0.5, -2.5, 3.0, 2.0,
    1.7976931348623157e308, 5e-324, float("inf"), float("-inf"),
    4503599627370497.0, 1e300,
]
# Les motifs de bits qu'aucun littéral ne donne : NaN silencieux, NaN
# signalant, et un dénormal.
RAW_DOUBLES = [
    0x7FF8000000000000,  # NaN silencieux
    0x7FF0000000000001,  # NaN signalant
    0xFFF8000000000000,  # NaN silencieux négatif
    0x0000000000000001,  # le plus petit dénormal
]

FLOATS = [0.0, -0.0, 1.0, -1.0, 0.5, -2.5, 3.4028235e38, 1.1754944e-38,
          float("inf"), float("-inf"), 16777217.0]
RAW_FLOATS = [0x7FC00000, 0x7F800001, 0xFFC00000, 0x00000001]

# Les entiers pour `CVTSI2*` : les bords des deux largeurs, et une valeur qui
# ne peut pas être représentée exactement en double.
GENERAL = [
    0, 1, 0xFFFFFFFFFFFFFFFF, 0x000000007FFFFFFF, 0x0000000080000000,
    0x7FFFFFFFFFFFFFFF, 0x8000000000000000, 0x0020000000000001,
]

IN_FLAGS = [0x002, 0x8D5]

ARITHMETIC_FLAGS = (1 << 0) | (1 << 2) | (1 << 4) | (1 << 6) | (1 << 7) | (1 << 11)


def patterns():
    """Les motifs de cent vingt-huit bits à l'essai.

    Deux familles, parce qu'une seule ne suffirait pas. Les doubles occupent
    les soixante-quatre bits bas, et leurs trente-deux bits bas font alors des
    flottants quelconques — souvent dénormaux. Les simples sont donc repris à
    part, **dupliqués sur les deux moitiés** du mot bas, pour que les formes
    `ss` reçoivent de vraies valeurs et que les formes `sd` en reçoivent
    d'autres encore.
    """
    out = [(double(value), 0x4142434445464748) for value in DOUBLES]
    out += [(bits, 0x4142434445464748) for bits in RAW_DOUBLES]
    out += [(single(value) | (single(value) << 32), 0x4142434445464748)
            for value in FLOATS]
    out += [(bits | (bits << 32), 0x4142434445464748) for bits in RAW_FLOATS]
    return out


def states():
    """Un étalement. Une paire sur trois met la **même** valeur des deux côtés
    — sans quoi aucune comparaison ne rendrait jamais « égal »."""
    fixed = [0xAAAAAAAAAAAAAAAA + i for i in range(16)]
    values = patterns()
    count = len(values)
    pairs = [(i, count - 1 - i) for i in range(count)]
    pairs += [(i, (i * 5 + 3) % count) for i in range(count)]
    pairs += [(i, i) for i in range(count)]
    for index, (first, second) in enumerate(pairs):
        general = list(fixed)
        general[0] = GENERAL[index % len(GENERAL)]
        general[6] = DATA
        vectors = [(0xC000000000000000 + i, 0xD000000000000000 + i) for i in range(16)]
        vectors[0] = values[first]
        vectors[1] = values[second]
        yield general + [IN_FLAGS[index % len(IN_FLAGS)]], vectors


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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output")
    parser.add_argument("--oracle", default="scripts/x86-oracle/oracle")
    arguments = parser.parse_args()

    texts = forms()
    encoded = assemble(texts)
    chosen = list(states())

    request = []
    cases = []
    for instruction, hexadecimal in enumerate(encoded):
        for index, (general, vectors) in enumerate(chosen):
            values = list(general)
            for low, high in vectors:
                values += [low, high]
            request.append(hexadecimal + "\t" + "\t".join(f"{v:x}" for v in values))
            cases.append((instruction, index, general, vectors))

    answer = subprocess.run([arguments.oracle], input="\n".join(request) + "\n",
                            capture_output=True, text=True, check=True).stdout.splitlines()
    if len(answer) != len(cases):
        raise SystemExit(f"{len(cases)} cas envoyés, {len(answer)} verdicts reçus")

    with open(arguments.output, "w") as out:
        out.write("# Ce que le vrai processeur répond sur le flottant scalaire.\n")
        out.write("# Voir scripts/build-x86-float-oracle.py.\n")
        out.write("# état\t<indice>\t<xmm0 bas>\t<xmm0 haut>\t<xmm1 bas>\t<xmm1 haut>"
                  "\t<rax>\t<drapeaux>\n")
        out.write("# instr\t<indice>\t<octets>\t<mnémonique>\n")
        out.write("# cas\t<instr>\t<état>\t<xmm0 bas>\t<xmm0 haut>\t<xmm1 bas>"
                  "\t<xmm1 haut>\t<rax>\t<drapeaux>\n")
        out.write("#   Les drapeaux d'après sont gardés pour **chaque** cas, et pas\n")
        out.write("#   seulement vérifiés inchangés : UCOMIS* et COMIS* en écrivent,\n")
        out.write("#   contrairement à tout ce que les six corpus d'avant tenaient.\n")
        out.write("#   RSI pointe la fenêtre de 64 octets à 0x30001000 ; les opérandes\n")
        out.write("#   mémoire travaillent à +0x20. Aucune forme n'écrit en mémoire.\n")
        for index, (general, vectors) in enumerate(chosen):
            out.write("état\t%d\t%x\t%x\t%x\t%x\t%x\t%x\n"
                      % (index, vectors[0][0], vectors[0][1], vectors[1][0], vectors[1][1],
                         general[0], general[16] & ARITHMETIC_FLAGS))
        for index, (hexadecimal, text) in enumerate(zip(encoded, texts)):
            out.write("instr\t%d\t%s\t%s\n" % (index, hexadecimal, text))

        window = ("101112131415161718191a1b1c1d1e1f"
                  "202122232425262728292a2b2c2d2e2f"
                  "303132333435363738393a3b3c3d3e3f"
                  "404142434445464748494a4b4c4d4e4f")
        for (instruction, index, general, vectors), verdict in zip(cases, answer):
            fields = verdict.split("\t")
            after = [int(value, 16) for value in fields[50:99]]
            if fields[99] != window:
                raise SystemExit(f"{texts[instruction]} a écrit dans la fenêtre")
            for register in [1, 2, 3] + list(range(8, 16)):
                if after[register] != general[register]:
                    raise SystemExit(
                        f"{texts[instruction]} a écrit dans {REGISTERS[register]}")
            for vector in range(2, 16):
                got = (after[17 + 2 * vector], after[18 + 2 * vector])
                if got != vectors[vector]:
                    raise SystemExit(f"{texts[instruction]} a écrit dans xmm{vector}")
            out.write("cas\t%d\t%d\t%x\t%x\t%x\t%x\t%x\t%x\n"
                      % (instruction, index,
                         after[17], after[18], after[19], after[20], after[0],
                         after[16] & ARITHMETIC_FLAGS))
    print(f"{len(encoded)} instructions, {len(cases)} cas", file=sys.stderr)


if __name__ == "__main__":
    main()
