#!/usr/bin/env python3
"""Fabrique le verdict du **vrai processeur** sur les instructions de chaîne.

Ce fichier existe parce qu'un comptage l'a réclamé : sur les 389 formes du
corpus arithmétique, **aucune** n'est un `MOVS`, un `STOS`, un `SCAS`, un
`CMPS` ni un `LODS`. Les dix-sept correspondances de « movs » qu'on y trouve
sont des `MOVSX` et des `CMOVS` — des extensions de signe et des transferts
conditionnels, pas des chaînes.

Or ce sont exactement les instructions dont un noyau se sert pour recopier
entre son espace et celui d'un programme : `copy_to_user` et `copy_from_user`
sont des `rep movsq` et des `rep movsb`. Une pile initiale de processus — les
arguments, l'environnement, le vecteur auxiliaire, tous des pointeurs — arrive
par là.

    scripts/build-x86-string-oracle.py Tests/Fixtures/x86-string-oracle.tsv

**Un fichier séparé**, comme pour les XMM, et pour la même raison : le corpus
arithmétique ne rend que RAX, RCX, RDX et les drapeaux, alors qu'une chaîne
travaille sur RSI, RDI et RCX. Y ajouter des colonnes changerait dix mille
lignes pour des valeurs que personne ne lirait.

**Le drapeau de direction compte double.** Il décide du sens, et un cœur qui
l'ignore copie à l'envers sans rien signaler. Chaque forme est donc essayée
dans les deux sens, avec des pointeurs placés en conséquence.
"""

import argparse
import re
import subprocess
import sys
import tempfile
from pathlib import Path

# La fenêtre de données du harnais : soixante-quatre octets à cette adresse.
DATA = 0x30001000
WINDOW = 64
# Source et destination, chacune dans sa moitié, pour qu'une copie de
# trente-deux octets tienne entièrement dedans et se voie entièrement.
SOURCE = DATA
TARGET = DATA + 0x20

REGISTERS = [
    "rax", "rcx", "rdx", "rbx", "rsp", "rbp", "rsi", "rdi",
    "r8", "r9", "r10", "r11", "r12", "r13", "r14", "r15",
]

# Le drapeau de direction, et les six de l'arithmétique.
DIRECTION = 1 << 10
ARITHMETIC_FLAGS = (1 << 0) | (1 << 2) | (1 << 4) | (1 << 6) | (1 << 7) | (1 << 11)


def forms():
    """Les formes à l'essai, avec le nombre d'éléments que chacune traite."""
    out = []
    # Les copies, aux quatre largeurs, répétées et une par une. C'est
    # `rep movsq` que `copy_to_user` emploie, et `rep movsb` pour la queue.
    for name, width in [("movsb", 1), ("movsw", 2), ("movsl", 4), ("movsq", 8)]:
        out.append((f"rep {name}", 32 // width))
        out.append((name, 1))
    # Les remplissages : `memset` du noyau, et l'effacement de sa propre BSS.
    for name, width in [("stosb", 1), ("stosw", 2), ("stosl", 4), ("stosq", 8)]:
        out.append((f"rep {name}", 32 // width))
        out.append((name, 1))
    # Les lectures.
    for name in ["lodsb", "lodsw", "lodsl", "lodsq"]:
        out.append((name, 1))
    # Les comparaisons, dans les deux sens du préfixe : elles s'arrêtent sur le
    # drapeau de zéro, et le sens de cet arrêt est ce qu'un test doit fixer.
    for name in ["cmpsb", "cmpsw", "cmpsl", "cmpsq", "scasb", "scasw", "scasl", "scasq"]:
        out.append((f"repe {name}", 8))
        out.append((f"repne {name}", 8))
        out.append((name, 1))
    # **Le cas qui n'exécute rien.** Un `rep` avec RCX à zéro ne doit toucher à
    # rien du tout — ni mémoire, ni pointeurs, ni drapeaux. Un cœur qui ferait
    # un tour de trop écrirait un octet que personne n'a demandé.
    out.append(("rep movsb", 0))
    out.append(("rep stosq", 0))
    out.append(("repe cmpsb", 0))
    return out


# Ce que RAX porte : ce que `STOS` écrit et ce que `SCAS` cherche. La dernière
# valeur est un octet **présent** dans la fenêtre, pour que `SCAS` s'arrête
# quelque part plutôt que d'aller au bout à chaque fois.
ACCUMULATORS = [0x0000000000000000, 0xFFFFFFFFFFFFFFFF,
                0x1122334455667788, 0x0000000000000014]


def states():
    """Un état par sens et par accumulateur. Les pointeurs suivent le sens :
    en arrière, ils partent de la **fin** de leur moitié."""
    fixed = [0xAAAAAAAAAAAAAAAA + i for i in range(16)]
    for backwards in [False, True]:
        for accumulator in ACCUMULATORS:
            state = list(fixed)
            state[0] = accumulator
            state[6] = SOURCE + (0x18 if backwards else 0)
            state[7] = TARGET + (0x18 if backwards else 0)
            yield state + [(DIRECTION if backwards else 0) | 0x002], backwards


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

    shapes = forms()
    encoded = assemble([text for text, _ in shapes])
    chosen = list(states())

    request = []
    cases = []
    for instruction, ((text, count), hexadecimal) in enumerate(zip(shapes, encoded)):
        for index, (state, _) in enumerate(chosen):
            values = list(state)
            values[1] = count  # RCX : le nombre d'éléments de cette forme
            request.append(hexadecimal + "\t" + "\t".join(f"{v:x}" for v in values))
            cases.append((instruction, index, values))

    answer = subprocess.run([arguments.oracle], input="\n".join(request) + "\n",
                            capture_output=True, text=True, check=True).stdout.splitlines()
    if len(answer) != len(cases):
        raise SystemExit(f"{len(cases)} cas envoyés, {len(answer)} verdicts reçus")

    window = "".join(f"{0x10 + i:02x}" for i in range(WINDOW))
    with open(arguments.output, "w") as out:
        out.write("# Ce que le vrai processeur répond sur les instructions de chaîne.\n")
        out.write("# Voir scripts/build-x86-string-oracle.py.\n")
        out.write("# état\t<indice>\t<rax>\t<rsi>\t<rdi>\t<drapeaux>\n")
        out.write("# instr\t<indice>\t<octets>\t<rcx de départ>\t<mnémonique>\n")
        out.write("# cas\t<instr>\t<état>\t<rax>\t<rcx>\t<rsi>\t<rdi>\t<drapeaux>\t<mémoire>\n")
        out.write("#   RSI et RDI pointent les deux moitiés de la fenêtre de 64 octets\n")
        out.write("#   à 0x30001000 ; en arrière ils partent de la fin de leur moitié.\n")
        out.write("#   « - » quand la fenêtre est restée telle qu'on l'avait posée.\n")
        for index, (state, backwards) in enumerate(chosen):
            out.write("état\t%d\t%x\t%x\t%x\t%x\n"
                      % (index, state[0], state[6], state[7], state[16]))
        for index, ((text, count), hexadecimal) in enumerate(zip(shapes, encoded)):
            out.write("instr\t%d\t%s\t%d\t%s\n" % (index, hexadecimal, count, text))
        for (instruction, index, before), verdict in zip(cases, answer):
            fields = verdict.split("\t")
            after = [int(value, 16) for value in fields[18:35]]
            memory = fields[35]
            for register in [3] + list(range(8, 16)):
                if after[register] != before[register]:
                    raise SystemExit(
                        f"{shapes[instruction][0]} a écrit dans {REGISTERS[register]}")
            out.write("cas\t%d\t%d\t%x\t%x\t%x\t%x\t%x\t%s\n"
                      % (instruction, index, after[0], after[1], after[6], after[7],
                         after[16] & ARITHMETIC_FLAGS,
                         "-" if memory == window else memory))
    print(f"{len(encoded)} formes, {len(cases)} cas", file=sys.stderr)


if __name__ == "__main__":
    main()
