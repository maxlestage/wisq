#!/usr/bin/env python3
"""Fabrique le verdict du **vrai processeur** sur l'arithmétique SSE2 entière.

Une fois le `push` fautif corrigé, `/init` vit : le port série dit « Alpine
Init 3.10.1-r0 », les pilotes se chargent, le média de démarrage se monte. La
course ne meurt plus — elle bute sur un opcode absent, `0F 76` (`PCMPEQD`), à
trois milliards d'instructions.

    scripts/build-x86-simd-oracle.py Tests/Fixtures/x86-simd-oracle.tsv

**Le cadrage vient d'un comptage, pas d'une intuition.** En désassemblant les
binaires réellement présents dans l'initramfs de l'invité — la bibliothèque C,
libcrypto, libssl, libapk, busybox — et en comptant les mnémoniques que ce cœur
ne sait pas exécuter, il reste exactement ceci :

    paddd 1129   psrld 634   pslld 522   pshufd 343   psrlq 125   psllq 118
    pcmpeqd 106  paddq 98    pslldq 77   pinsrw 74    pcmpgtd 64  psrldq 55
    psubd 30     psrad 22    pcmpeqb 10  psubq 5      psadbw 3

Et un fait que le comptage donne et qu'aucune lecture de manuel n'aurait donné :
**tous les décalages sont par immédiat**, jamais par registre XMM. Le groupe
`0F 71/72/73` suffit ; `0F D1/D2/D3`, `0F E1/E2` et `0F F1/F2/F3` ne sont
employés nulle part. Les écrire quand même serait exactement ce que ce dépôt
évite.

**Toujours pas de virgule flottante.** `PADDD` additionne quatre entiers de
trente-deux bits ; ce n'est pas `ADDPS`, et rien dans l'invité ne demande
encore le second. Deux décisions différentes.

**Aucun drapeau.** Aucune de ces instructions n'en touche un — c'est une
propriété qui vaut d'être tenue, donc les drapeaux d'entrée varient et doivent
revenir intacts.
"""

import argparse
import re
import subprocess
import sys
import tempfile
from pathlib import Path

# Là où pointe RSI : la fenêtre de données du harnais, soixante-quatre octets.
DATA = 0x30001000
# L'opérande mémoire de ces instructions doit être aligné sur seize : ce ne
# sont pas des formes « u ». Un désalignement lèverait #GP et le harnais
# mourrait au lieu de répondre.
ALIGNED = 0x20

REGISTERS = [
    "rax", "rcx", "rdx", "rbx", "rsp", "rbp", "rsi", "rdi",
    "r8", "r9", "r10", "r11", "r12", "r13", "r14", "r15",
]

# Les comptes de décalage à l'essai. Zéro, les petits, la limite de la largeur,
# **juste au-delà**, et un immédiat énorme. C'est au-delà que les familles se
# séparent : un décalage logique de trente-deux sur des mots de trente-deux bits
# rend zéro, tandis que l'arithmétique rend le signe étalé. Se tromper là-dessus
# est invisible sur les petits comptes et faux partout ailleurs.
COUNTS = [0, 1, 7, 15, 16, 31, 32, 63, 64, 255]

# Les permutations de `PSHUFD` : l'identité, le renversement, l'échange des
# moitiés, la diffusion d'un seul mot, et une permutation quelconque.
SHUFFLES = [0xE4, 0x1B, 0x4E, 0x00, 0xFF, 0x93]

# Les positions de `PINSRW` : les deux bords et le milieu. Le champ ne fait que
# trois bits utiles — 8 et 9 doivent donc désigner les mêmes mots que 0 et 1.
INSERTS = [0, 3, 7, 8, 9]


def forms():
    """Les formes à l'essai. Chacune ne touche que xmm0, xmm1 et RAX."""
    out = []
    # Les comparaisons, qui rendent un masque de tout-un ou de tout-zéro par
    # élément. C'est `PCMPEQD` qui a arrêté la course.
    for name in ["pcmpeqb", "pcmpeqd", "pcmpgtd"]:
        out += [f"{name} %xmm1, %xmm0", f"{name} {ALIGNED:#x}(%rsi), %xmm0"]
    # L'addition et la soustraction, par paquets de trente-deux et de
    # soixante-quatre bits. Elles **enveloppent** sans saturer et sans drapeau :
    # une retenue qui sort d'un élément ne rentre pas dans le suivant, et c'est
    # tout l'intérêt de la chose.
    for name in ["paddd", "paddq", "psubd", "psubq"]:
        out += [f"{name} %xmm1, %xmm0", f"{name} {ALIGNED:#x}(%rsi), %xmm0"]
    # La permutation des quatre mots de trente-deux bits.
    for control in SHUFFLES:
        out += [f"pshufd ${control:#x}, %xmm1, %xmm0",
                f"pshufd ${control:#x}, {ALIGNED:#x}(%rsi), %xmm0"]
    # Les décalages par immédiat. `psrldq` et `pslldq` décalent le registre
    # **entier en octets** et n'ont rien à voir avec les autres malgré le nom.
    for name in ["psrld", "pslld", "psrad", "psrlq", "psllq", "psrldq", "pslldq"]:
        for count in COUNTS:
            out.append(f"{name} ${count}, %xmm0")
    # L'insertion d'un mot de seize bits, depuis un registre général ou la
    # mémoire.
    for position in INSERTS:
        out += [f"pinsrw ${position}, %eax, %xmm0",
                f"pinsrw ${position}, {ALIGNED:#x}(%rsi), %xmm0"]
    # La somme des différences absolues, qui condense seize octets en deux
    # nombres et n'a d'équivalent nulle part ailleurs dans le jeu.
    out += ["psadbw %xmm1, %xmm0", f"psadbw {ALIGNED:#x}(%rsi), %xmm0"]
    return out


# Les valeurs qui font basculer quelque chose : zéro, tout à un, des motifs
# d'octets tous différents pour que l'ordre se voie, les bits de signe — qui
# séparent le décalage arithmétique du logique et `PCMPGTD` de `PCMPEQD` — et
# des valeurs égales entre les deux registres, sans quoi une comparaison
# d'égalité ne rendrait jamais qu'un masque vide.
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
    """Les octets de chaque instruction, par l'assembleur puis objdump."""
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
        out.write("# Ce que le vrai processeur répond sur l'arithmétique SSE2 entière.\n")
        out.write("# Voir scripts/build-x86-simd-oracle.py.\n")
        out.write("# état\t<indice>\t<xmm0 bas>\t<xmm0 haut>\t<xmm1 bas>\t<xmm1 haut>"
                  "\t<rax>\t<drapeaux>\n")
        out.write("# instr\t<indice>\t<octets>\t<mnémonique>\n")
        out.write("# cas\t<instr>\t<état>\t<xmm0 bas>\t<xmm0 haut>\t<xmm1 bas>"
                  "\t<xmm1 haut>\t<rax>\n")
        out.write("#   RSI pointe la fenêtre de 64 octets à 0x30001000, et les\n")
        out.write("#   opérandes mémoire travaillent à +0x20 : ces formes exigent\n")
        out.write("#   l'alignement sur seize. Aucune n'écrit en mémoire, donc la\n")
        out.write("#   fenêtre n'est pas rapportée — mais elle est vérifiée.\n")
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
                raise SystemExit(
                    f"{texts[instruction]} a touché aux drapeaux : "
                    f"{general[16]:x} devenu {after[16]:x}")
            out.write("cas\t%d\t%d\t%x\t%x\t%x\t%x\t%x\n"
                      % (instruction, index,
                         after[17], after[18], after[19], after[20], after[0]))
    print(f"{len(encoded)} instructions, {len(cases)} cas", file=sys.stderr)


if __name__ == "__main__":
    main()
