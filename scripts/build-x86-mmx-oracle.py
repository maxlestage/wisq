#!/usr/bin/env python3
"""Fabrique le verdict du **vrai processeur** sur le MMX.

    scripts/build-x86-mmx-oracle.py Tests/Fixtures/x86-mmx-oracle.tsv

CPUID annonçait le MMX — la glibc l'exige pour charger un programme — et
aucune de ses instructions n'existait dans ce cœur. Voir
`Sources/WisqVM/X86MMX.swift`.

**Le harnais ne connaît pas les registres MMX.** Il pose les registres
généraux et les XMM, exécute des octets et rend le tout. Chaque forme est donc
une courte suite : `movdq2q` copie xmm0 et xmm1 dans mm0 et mm1, l'instruction
essayée travaille, `movq2dq` recopie mm0 et mm1 dans xmm0 et xmm1 (la moitié
haute à zéro), et `emms` rend la pile x87 vide comme le harnais l'attend. Le
cœur exécute la même suite — `movdq2q` et `movq2dq` compris, qui sont du MMX
eux aussi.

**Aucun rangement en mémoire.** La fenêtre de données est exigée intacte ;
`movq mm, m64`, `movntq` et `maskmovq` sont tenus par des tests à part.
"""

import argparse
import re
import subprocess
import sys
import tempfile
from pathlib import Path

DATA = 0x30001000
MEMORY = "0x20(%rsi)"

REGISTERS = [
    "rax", "rcx", "rdx", "rbx", "rsp", "rbp", "rsi", "rdi",
    "r8", "r9", "r10", "r11", "r12", "r13", "r14", "r15",
]

PROLOGUE = ["movdq2q %xmm0, %mm0", "movdq2q %xmm1, %mm1"]
EPILOGUE = ["movq2dq %mm0, %xmm0", "movq2dq %mm1, %xmm1", "emms"]

COUNTS = [0, 1, 7, 15, 16, 31, 32, 63, 64, 255]
SHUFFLES = [0xE4, 0x1B, 0x4E, 0x00, 0xFF, 0x93]
POSITIONS = [0, 1, 3, 4, 7]


def forms():
    """Les instructions à l'essai, chacune entre le prologue et l'épilogue."""
    out = []
    for name in ["punpcklbw", "punpcklwd", "punpckldq", "punpckhbw", "punpckhwd", "punpckhdq",
                 "packsswb", "packssdw", "packuswb",
                 "pcmpeqb", "pcmpeqw", "pcmpeqd", "pcmpgtb", "pcmpgtw", "pcmpgtd",
                 "psrlw", "psrld", "psrlq", "psraw", "psrad", "psllw", "pslld", "psllq",
                 "paddb", "paddw", "paddd", "paddq", "psubb", "psubw", "psubd", "psubq",
                 "paddsb", "paddsw", "psubsb", "psubsw", "paddusb", "paddusw", "psubusb", "psubusw",
                 "pmullw", "pmulhw", "pmulhuw", "pmuludq", "pmaddwd",
                 "pminub", "pmaxub", "pminsw", "pmaxsw", "pavgb", "pavgw", "psadbw",
                 "pand", "pandn", "por", "pxor", "movq"]:
        out += [f"{name} %mm1, %mm0", f"{name} {MEMORY}, %mm0"]
    for name in ["psrlw", "psraw", "psllw", "psrld", "psrad", "pslld", "psrlq", "psllq"]:
        for count in COUNTS:
            out.append(f"{name} ${count}, %mm0")
    for control in SHUFFLES:
        out += [f"pshufw ${control:#x}, %mm1, %mm0", f"pshufw ${control:#x}, {MEMORY}, %mm0"]
    for position in POSITIONS:
        out += [f"pinsrw ${position}, %eax, %mm0", f"pinsrw ${position}, {MEMORY}, %mm0",
                f"pextrw ${position}, %mm1, %eax"]
    out += ["pmovmskb %mm1, %eax",
            "movd %eax, %mm0", f"movd {MEMORY}, %mm0", "movq %rax, %mm0",
            "movd %mm1, %eax", "movq %mm1, %rax"]
    # **SSSE3 sur les registres MMX** : les mêmes opérations que sous 66, sur
    # huit octets. `pshufb` n'y lit que trois bits d'index ; `palignr` et les
    # horizontales mêlent destination et source autrement que sur seize.
    for name in ["pshufb", "phaddw", "phaddd", "phaddsw", "phsubw", "phsubd", "phsubsw",
                 "pmaddubsw", "psignb", "psignw", "psignd", "pmulhrsw",
                 "pabsb", "pabsw", "pabsd"]:
        out += [f"{name} %mm1, %mm0", f"{name} {MEMORY}, %mm0"]
    for count in [0, 1, 3, 7, 8, 9, 15, 16, 200]:
        out += [f"palignr ${count}, %mm1, %mm0", f"palignr ${count}, {MEMORY}, %mm0"]
    # **Les conversions entre MMX et flottants.** Elles écrivent un XMM ou
    # lisent un XMM : le prologue et l'épilogue ordinaires écraseraient leur
    # résultat. Chacune a donc les siens — `(prologue, instruction,
    # épilogue)` — et son résultat finit dans xmm0.
    # Vers un XMM : mm1 chargé depuis xmm1, le résultat laissé dans xmm0.
    for name in ["cvtpi2ps", "cvtpi2pd"]:
        out.append((["movdq2q %xmm1, %mm1"], f"{name} %mm1, %xmm0", ["emms"]))
        out.append(([], f"{name} {MEMORY}, %xmm0", ["emms"]))
    # Vers un MMX : la source dans xmm1 ou en mémoire, mm0 rendu dans xmm0.
    for name in ["cvtps2pi", "cvttps2pi", "cvtpd2pi", "cvttpd2pi"]:
        out.append(([], f"{name} %xmm1, %mm0", ["movq2dq %mm0, %xmm0", "emms"]))
        out.append(([], f"{name} {MEMORY}, %mm0", ["movq2dq %mm0, %xmm0", "emms"]))
    return out


def parts(item):
    """Une forme : son prologue, son instruction, son épilogue."""
    return (PROLOGUE, item, EPILOGUE) if isinstance(item, str) else item


VALUES = [
    (0x0000000000000000, 0x0000000000000000),
    (0xFFFFFFFFFFFFFFFF, 0xFFFFFFFFFFFFFFFF),
    (0x0706050403020100, 0x0F0E0D0C0B0A0908),
    (0x1122334455667788, 0x99AABBCCDDEEFF00),
    (0x8000000080000000, 0x0000000100000001),
    (0x00000000FFFFFFFF, 0xFFFFFFFF00000000),
    (0xDEADBEEFCAFEF00D, 0x0123456789ABCDEF),
    (0x5555555555555555, 0xAAAAAAAAAAAAAAAA),
    (0x7FFFFFFF7FFFFFFF, 0x8000000080000000),
    (0xFFFFFFFEFFFFFFFF, 0x0000000000000002),
    # Un petit compte dans le bas, pour les décalages par registre, et des mots
    # aux deux bords du signe.
    (0x0000000000000003, 0x8001800180017FFF),
    (0x000000000000001F, 0x7FFF00FF80000100),
    # Des octets autour de 0x7F, 0x80 et 0xFF : la saturation et la
    # comparaison signée s'y décident.
    (0x80FF7F0001FE817E, 0x00FF00800080FF7F),
]

GENERAL = [
    0x0000000000000000,
    0xFFFFFFFFFFFFFFFF,
    0x123456789ABCDEF0,
    0x00000000DEADBEEF,
]

IN_FLAGS = [0x002, 0x8D5]

ARITHMETIC_FLAGS = (1 << 0) | (1 << 2) | (1 << 4) | (1 << 6) | (1 << 7) | (1 << 11)


def states():
    """Un étalement, pas un début de produit cartésien. Une paire sur trois met
    la **même** valeur dans les deux registres : sans elle, `PCMPEQD` ne
    rendrait jamais qu'un masque vide et le fichier n'en dirait rien."""
    fixed = [0xAAAAAAAAAAAAAAAA + i for i in range(16)]
    count = len(VALUES)
    pairs = [(i, count - 1 - i) for i in range(count)]
    pairs += [(i, (i * 3 + 1) % count) for i in range(count)]
    pairs += [(i, i) for i in range(count)]
    for index, (first, second) in enumerate(pairs):
        general = list(fixed)
        general[0] = GENERAL[index % len(GENERAL)]
        general[6] = DATA
        vectors = [(0xC000000000000000 + i, 0xD000000000000000 + i) for i in range(16)]
        vectors[0] = VALUES[first]
        vectors[1] = VALUES[second]
        yield general + [IN_FLAGS[index % len(IN_FLAGS)]], vectors



def assemble(texts):
    """Les octets de chaque suite : prologue, instruction, épilogue."""
    flat = []
    sizes = []
    for item in texts:
        before, text, after = parts(item)
        flat += before + [text] + after
        sizes.append(len(before) + 1 + len(after))
    with tempfile.TemporaryDirectory() as directory:
        source = Path(directory) / "cases.s"
        obj = Path(directory) / "cases.o"
        with open(source, "w") as out:
            out.write(".text\n")
            for text in flat:
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
    if len(encoded) != len(flat):
        raise SystemExit(f"{len(flat)} instructions demandées, {len(encoded)} relues")
    suites = []
    start = 0
    for size in sizes:
        suites.append("".join(encoded[start:start + size]))
        start += size
    return suites


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output")
    parser.add_argument("--oracle", default="scripts/x86-oracle/oracle")
    arguments = parser.parse_args()

    items = forms()
    encoded = assemble(items)
    texts = [parts(item)[1] for item in items]
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
        out.write("# Ce que le vrai processeur répond sur le MMX.\n")
        out.write("# Voir scripts/build-x86-mmx-oracle.py.\n")
        out.write("# état\t<indice>\t<xmm0 bas>\t<xmm0 haut>\t<xmm1 bas>\t<xmm1 haut>"
                  "\t<rax>\t<drapeaux>\n")
        out.write("# instr\t<indice>\t<octets>\t<mnémonique>\n")
        out.write("# cas\t<instr>\t<état>\t<xmm0 bas>\t<xmm0 haut>\t<xmm1 bas>"
                  "\t<xmm1 haut>\t<rax>\n")
        out.write("#   Chaque instruction est entourée de movdq2q (xmm0, xmm1 vers\n")
        out.write("#   mm0, mm1), puis de movq2dq et emms : les octets sont la suite\n")
        out.write("#   entière, et le mnémonique celui de l'instruction essayée.\n")
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
            if after[16] & ARITHMETIC_FLAGS != general[16] & ARITHMETIC_FLAGS:
                raise SystemExit(f"{texts[instruction]} a touché aux drapeaux")
            out.write("cas\t%d\t%d\t%x\t%x\t%x\t%x\t%x\n"
                      % (instruction, index,
                         after[17], after[18], after[19], after[20], after[0]))
    print(f"{len(encoded)} instructions, {len(cases)} cas", file=sys.stderr)


if __name__ == "__main__":
    main()
