#!/usr/bin/env python3
"""Fabrique le verdict du **vrai processeur** sur les seize registres XMM.

Le noyau d'Alpine s'est arrêté sur `0F 6E` — `MOVD`/`MOVQ` entre un registre
général et un registre SSE — à une adresse d'espace utilisateur : la
bibliothèque C se sert de SSE dans ses fonctions de chaîne, avant même son
premier appel système. Ce fichier est la référence pour ce que wisq doit en
faire, et cette référence est le processeur lui-même.

    scripts/build-x86-xmm-oracle.py Tests/Fixtures/x86-xmm-oracle.tsv

**Seulement le déplacement de bits.** `MOVD`, `MOVQ`, `MOVDQA`/`MOVDQU`,
`MOVAPS`/`MOVUPS`, `MOVAPD`/`MOVUPD`, les entrelacements et les quatre
opérations logiques. Pas une seule instruction de calcul flottant : ce sont
deux décisions différentes, et l'arithmétique n'a pas encore été demandée par
la machine. Écrire un moteur de virgule flottante que rien n'appelle serait
exactement ce que ce dépôt évite.

**Aucun drapeau.** Aucune de ces instructions n'en touche un — c'est même une
propriété qu'il vaut la peine de tenir, donc les drapeaux d'entrée varient et
doivent revenir intacts.
"""

import argparse
import re
import subprocess
import sys
import tempfile
from pathlib import Path

# Là où pointe RSI : la fenêtre de données du harnais, soixante-quatre octets.
DATA = 0x30001000
# Les deux adresses d'essai, **toutes deux dans la fenêtre**. `MOVDQA` et
# `MOVAPS` lèvent sur une adresse qui n'est pas alignée sur seize, et le
# harnais mourrait au lieu de répondre ; l'autre l'est exprès pour que les
# formes non alignées prouvent qu'elles ne s'en soucient pas.
#
# Le premier jet mettait l'adresse alignée à +0x40, c'est-à-dire **juste après**
# la fenêtre : les formes qui écrivent en mémoire n'y laissaient alors aucune
# trace observable, et le fichier les aurait enregistrées comme n'ayant rien
# fait. Un cas sans effet visible n'est pas un cas.
ALIGNED = 0x20
UNALIGNED = 0x11

REGISTERS = [
    "rax", "rcx", "rdx", "rbx", "rsp", "rbp", "rsi", "rdi",
    "r8", "r9", "r10", "r11", "r12", "r13", "r14", "r15",
]


# Les encodages que l'assembleur ne **choisit** pas, mais que le processeur
# exécute et que la bibliothèque C emploie. `movq %xmm1, %xmm0` a deux formes :
# `F3 0F 7E`, que `as` prend toujours, et `66 0F D6`, qui fait la même chose et
# qu'un compilateur émet aussi. Les octets sont donnés à la main **et rien
# d'autre** : c'est toujours le vrai processeur qui dit ce qu'ils font.
EXPLICIT = [
    ("660fd6c8", "movq %xmm1, %xmm0  [66 0F D6, la forme que l'assembleur ne choisit pas]"),
]


def tailForms():
    """Ce qui s'ajoute **après** tout le reste.

    Un numéro d'instruction déjà attribué ne doit pas changer : le fichier
    d'oracle est une référence, et renuméroter ses cas ferait passer une
    simple addition pour une réécriture. Les formes neuves entrent donc en
    queue, après même les encodages explicites.

    `MOVSS` et `MOVSD` portent des noms de virgule flottante et ne calculent
    rien : ils déplacent trente-deux ou soixante-quatre bits. Mais ils ont une
    règle que rien d'autre n'a — **elle dépend de la source**. Depuis la
    mémoire, le reste du registre est mis à zéro ; depuis un autre registre, le
    reste est **laissé tel quel**. Confondre les deux écrase ce que le
    programme voulait garder, et aucune lecture attentive ne remplace la
    réponse du processeur là-dessus.
    """
    out = []
    for name in ["movss", "movsd"]:
        out += [
            f"{name} %xmm1, %xmm0",
            f"{name} {UNALIGNED:#x}(%rsi), %xmm0",
            f"{name} %xmm1, {UNALIGNED:#x}(%rsi)",
        ]
    return out


def forms():
    """Les formes à l'essai. Chacune ne touche que xmm0, xmm1 et RAX."""
    out = []
    # Le pont entre les deux mondes, dans les deux sens et aux deux largeurs.
    # C'est `0F 6E` qui a arrêté le noyau ; `0F 7E` est son retour, et se
    # tromper de largeur laisse les trente-deux bits du haut d'un registre là
    # où le processeur les efface.
    out += [
        "movd %eax, %xmm0",
        "movq %rax, %xmm0",
        "movd %xmm1, %eax",
        "movq %xmm1, %rax",
        "movd (%rsi), %xmm0",
        "movq (%rsi), %xmm0",          # F3 0F 7E : charge et efface le haut
        "movd %xmm1, (%rsi)",
        "movq %xmm1, (%rsi)",          # 66 0F D6
        "movq %xmm1, %xmm0",           # F3 0F 7E entre registres
    ]
    # Les déplacements de cent vingt-huit bits, alignés et non alignés. Les
    # quatre noms font la même chose sur des bits ; les distinguer serait une
    # erreur de lecture, les confondre en serait une autre.
    for name in ["movdqa", "movdqu", "movaps", "movups", "movapd", "movupd"]:
        out += [
            f"{name} %xmm1, %xmm0",
            f"{name} {ALIGNED:#x}(%rsi), %xmm0" if name in ("movdqa", "movaps", "movapd")
            else f"{name} {UNALIGNED:#x}(%rsi), %xmm0",
            f"{name} %xmm1, {ALIGNED:#x}(%rsi)" if name in ("movdqa", "movaps", "movapd")
            else f"{name} %xmm1, {UNALIGNED:#x}(%rsi)",
        ]
    # Les entrelacements : c'est ce qui recompose un registre à partir de deux
    # moitiés, et l'ordre des moitiés est exactement ce qu'un test doit fixer.
    out += [
        "punpcklqdq %xmm1, %xmm0",
        "punpckhqdq %xmm1, %xmm0",
        "punpckldq %xmm1, %xmm0",
        "punpckhdq %xmm1, %xmm0",
        "punpcklbw %xmm1, %xmm0",
        "punpcklwd %xmm1, %xmm0",
        "unpcklpd %xmm1, %xmm0",
        "unpckhpd %xmm1, %xmm0",
        "movhlps %xmm1, %xmm0",
        "movlhps %xmm1, %xmm0",
    ]
    # Les quatre opérations logiques, sur les bits et rien d'autre.
    for name in ["pxor", "por", "pand", "pandn", "xorps", "orps", "andps", "andnps",
                 "xorpd", "orpd", "andpd", "andnpd"]:
        out.append(f"{name} %xmm1, %xmm0")
    out += [f"pxor {ALIGNED:#x}(%rsi), %xmm0", f"pand {ALIGNED:#x}(%rsi), %xmm0"]
    return out


# Les valeurs qui font basculer quelque chose dans un registre de cent
# vingt-huit bits : zéro, tout à un, les deux moitiés séparées, des motifs
# d'octets tous différents pour que l'ordre se voie, et les bits de signe.
VALUES = [
    (0x0000000000000000, 0x0000000000000000),
    (0xFFFFFFFFFFFFFFFF, 0xFFFFFFFFFFFFFFFF),
    (0x0706050403020100, 0x0F0E0D0C0B0A0908),
    (0x1122334455667788, 0x99AABBCCDDEEFF00),
    (0x8000000000000000, 0x0000000000000001),
    (0x00000000FFFFFFFF, 0xFFFFFFFF00000000),
    (0xDEADBEEFCAFEF00D, 0x0123456789ABCDEF),
    (0x5555555555555555, 0xAAAAAAAAAAAAAAAA),
]

# Les valeurs pour RAX : ce que `MOVD` doit tronquer et ce que `MOVQ` doit
# garder entier.
GENERAL = [
    0x0000000000000000,
    0xFFFFFFFFFFFFFFFF,
    0x123456789ABCDEF0,
    0x00000000DEADBEEF,
]

# Deux états de drapeaux : aucune de ces instructions ne doit y toucher.
IN_FLAGS = [0x002, 0x8D5]

# Les six drapeaux de l'arithmétique — CF, PF, AF, ZF, SF, OF — et rien
# d'autre. Le reste appartient au harnais : le bit d'interruption est posé par
# le système et un `popfq` en anneau trois ne l'efface pas, donc l'exiger
# ferait échouer chaque cas pour une raison qui n'est pas l'instruction. Le bit
# réservé, lui, vaut toujours un.
ARITHMETIC_FLAGS = (1 << 0) | (1 << 2) | (1 << 4) | (1 << 6) | (1 << 7) | (1 << 11)


def states():
    """Un étalement, pas un début de produit cartésien : chaque valeur passe
    une fois par xmm0, appariée à une autre pour xmm1."""
    fixed = [0xAAAAAAAAAAAAAAAA + i for i in range(16)]
    count = len(VALUES)
    pairs = [(i, count - 1 - i) for i in range(count)]
    pairs += [(i, (i * 3 + 1) % count) for i in range(count)]
    for index, (first, second) in enumerate(pairs):
        general = list(fixed)
        general[0] = GENERAL[index % len(GENERAL)]
        general[6] = DATA
        # xmm2..xmm15 partent d'une valeur reconnaissable et ne doivent pas
        # bouger : c'est ce qui autorise le fichier à n'en garder que deux.
        vectors = [(0xC000000000000000 + i, 0xD000000000000000 + i) for i in range(16)]
        vectors[0] = VALUES[first]
        vectors[1] = VALUES[second]
        yield general + [IN_FLAGS[index % len(IN_FLAGS)]], vectors


def assemble(texts):
    """Les octets de chaque instruction, par l'assembleur puis objdump — c'est
    `as` qui choisit l'encodage, et `objdump` qui le relit."""
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
    for hexadecimal, name in EXPLICIT:
        encoded.append(hexadecimal)
        texts.append(name)
    tail = tailForms()
    encoded += assemble(tail)
    texts += tail
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
        out.write("# Ce que le vrai processeur répond sur les registres XMM.\n")
        out.write("# Voir scripts/build-x86-xmm-oracle.py.\n")
        out.write("# état\t<indice>\t<xmm0 bas>\t<xmm0 haut>\t<xmm1 bas>\t<xmm1 haut>"
                  "\t<rax>\t<drapeaux>\n")
        out.write("# instr\t<indice>\t<octets>\t<mnémonique>\n")
        out.write("# cas\t<instr>\t<état>\t<xmm0 bas>\t<xmm0 haut>\t<xmm1 bas>"
                  "\t<xmm1 haut>\t<rax>\t<mémoire>\n")
        out.write("#   RSI pointe la fenêtre de 64 octets à 0x30001000. Les formes\n")
        out.write("#   alignées travaillent à +0x20, les autres à +0x11 — les deux\n")
        out.write("#   dans la fenêtre, pour qu'une écriture s'y voie. « - » quand la\n")
        out.write("#   fenêtre est restée telle qu'on l'avait posée.\n")
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
            memory = fields[99]
            # Ce qui n'était pas censé bouger n'a pas bougé. C'est la
            # vérification qui autorise à ne garder que deux registres XMM et
            # un général dans le fichier.
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
            out.write("cas\t%d\t%d\t%x\t%x\t%x\t%x\t%x\t%s\n"
                      % (instruction, index,
                         after[17], after[18], after[19], after[20], after[0],
                         "-" if memory == window else memory))
    print(f"{len(encoded)} instructions, {len(cases)} cas", file=sys.stderr)


if __name__ == "__main__":
    main()
