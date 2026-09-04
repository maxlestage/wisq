#!/usr/bin/env python3
"""Fabrique le verdict du **vrai processeur** sur la pile et les atomiques.

Ce fichier existe parce qu'un comptage l'a réclamé, et le comptage a d'abord
été mal cadré. Le corpus arithmétique **contient** de la pile : trois de ses
seize programmes empilent, appellent, posent un cadre. Ce qui manque n'est pas
l'instruction, c'est le **témoin** : ce fichier-là ne rend que RAX, RCX, RDX
et les drapeaux. Ni RSP, ni RBP, ni un seul octet de la pile n'y sont
observés — la fenêtre de mémoire est à 0x30001000 et la pile descend depuis
0x30003000, deux pages plus loin. Un cœur qui décale RSP de huit octets de
travers, ou qui écrit son `push` à côté, traverse ces trois programmes sans
rien déclencher.

Or le registre corrompu quand `/init` meurt est **RBP** — celui que `pop %rbp`
et `leave` restaurent en sortant d'une fonction.

Le second trou est net, lui : sur les 389 formes du corpus, dix sont des
atomiques, et **les dix ont un registre pour destination**. Aucune n'a le
préfixe `lock`, aucune n'écrit en mémoire. Le chargeur de la bibliothèque C
de l'invité en compte cent vingt-trois, toutes sur de la mémoire.

    scripts/build-x86-stack-oracle.py Tests/Fixtures/x86-stack-oracle.tsv

**Le harnais a dû grandir pour ça**, d'une seconde fenêtre : soixante-quatre
octets de part et d'autre du sommet de pile. En dessous vit ce qu'un `push`
écrit, au-dessus ce qu'un `pop` relit. La preuve que ça n'a rien changé au
reste est que les trois corpus déjà figés — 10 020 cas arithmétiques, 832
vectoriels, 376 de chaîne — se régénèrent **à l'octet près**.

**Ce fichier rend les seize registres**, et non trois. C'est le seul des
quatre corpus à le faire, pour la raison qui l'a fait naître : quand on
cherche quel registre se fait corrompre, on ne peut pas décider d'avance
lequel regarder.
"""

import argparse
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ARENA = 0x30000000
DATA = ARENA + 0x1000
STACK = ARENA + 0x3000
WINDOW = 64
STACKWIN = 64

REGISTERS = [
    "rax", "rcx", "rdx", "rbx", "rsp", "rbp", "rsi", "rdi",
    "r8", "r9", "r10", "r11", "r12", "r13", "r14", "r15",
]

CF, PF, AF, ZF, SF, OF = 1 << 0, 1 << 2, 1 << 4, 1 << 6, 1 << 7, 1 << 11
ARITHMETIC_FLAGS = CF | PF | AF | ZF | SF | OF


def defined_flags(text):
    """Les drapeaux que l'architecture garantit pour cette forme.

    Même règle que dans `build-x86-oracle.py`, et pour la même raison : figer
    un drapeau que le manuel dit indéfini ferait de ce fichier le portrait
    d'**une** machine. Le préfixe `lock` ne change rien à la question, donc on
    le retire avant de lire le nom."""
    words = text.split()
    name = words[1] if words[0] == "lock" else words[0]
    root = name[:-1] if len(name) > 2 and name[-1] in "bwlq" else name
    # Les bits : seule la retenue, qui porte le bit lu.
    if root in ("bt", "bts", "btr", "btc"):
        return CF
    # ET, OU, OU exclusif : la retenue auxiliaire est indéfinie.
    if root in ("and", "or", "xor"):
        return ARITHMETIC_FLAGS & ~AF
    return ARITHMETIC_FLAGS


# Les formes. Le texte est ce qu'on donne à `as` ; quelques-unes portent à la
# place leurs octets, parce que l'assembleur ne les choisit jamais.
FORMS = [
    # --- Empiler ---------------------------------------------------------
    # Les seize registres, **RSP compris** : `push %rsp` empile la valeur
    # d'avant la soustraction, et c'est le genre de détail qu'un cœur écrit
    # dans le mauvais ordre sans que rien ne le dise.
] + [f"push %{name}" for name in REGISTERS] + [
    # Seize bits : le sommet ne descend que de deux octets. Un cœur qui
    # descend toujours de huit décale tout ce qui suit.
    "pushw %ax", "pushw %bp",
    # Les littéraux, étendus au signe sur soixante-quatre bits.
    "push $0x7f", "push $-1", "push $0x12345678", "push $-2147483648",
    "pushw $0x1234",
    # Depuis la mémoire, et depuis la pile elle-même.
    "push (%rsi)", "push 8(%rsi)", "pushw (%rsi)",
    # --- Dépiler ---------------------------------------------------------
] + [f"pop %{name}" for name in REGISTERS] + [
    "popw %ax", "popw %bp",
    "pop (%rsi)", "popw (%rsi)",
    # `leave` : RSP prend RBP, puis on dépile RBP. Deux effets, et l'état
    # d'entrée met RBP ailleurs que le sommet pour qu'on voie les deux.
    "leave",
    # --- Le seul immédiat de huit octets ---------------------------------
    "movabsq $0x1122334455667788, %rax",
    "movabsq $0xfedcba9876543210, %r10",
    "movabsq $0xffffffff80000000, %rcx",
    # --- Les atomiques sur de la mémoire ---------------------------------
    "lock addq %rcx, (%rsi)", "lock addl %ecx, (%rsi)",
    "lock addw %cx, (%rsi)", "lock addb %cl, (%rsi)",
    "lock subq %rcx, (%rsi)", "lock subl %ecx, (%rsi)",
    "lock orq %rcx, (%rsi)", "lock andq %rcx, (%rsi)", "lock xorq %rcx, (%rsi)",
    "lock incq (%rsi)", "lock decq (%rsi)", "lock incl (%rsi)", "lock decb (%rsi)",
    "lock xaddq %rcx, (%rsi)", "lock xaddl %ecx, (%rsi)", "lock xaddb %cl, (%rsi)",
    "lock cmpxchgq %rcx, (%rsi)", "lock cmpxchgl %ecx, (%rsi)",
    "lock cmpxchgb %cl, (%rsi)",
    "lock btsq %rcx, (%rsi)", "lock btrq %rcx, (%rsi)", "lock btcq %rcx, (%rsi)",
    # `xchg` avec de la mémoire est atomique **sans** préfixe : le processeur
    # verrouille de lui-même, et un cœur qui exigerait le préfixe refuserait
    # une instruction parfaitement licite.
    "xchgq %rcx, (%rsi)", "xchgl %ecx, (%rsi)", "xchgb %cl, (%rsi)",
]

# Ce que l'assembleur ne choisira jamais, donné en octets. Les formes /6 de
# `push` et /0 de `pop` sur un registre existent, encodent la même chose que
# `50+r` et `58+r`, et un décodeur qui ne les connaît pas s'arrête net dessus.
EXPLICIT = [
    ("fff0", "push %rax (forme ff /6)"),
    ("fff5", "push %rbp (forme ff /6)"),
    ("8fc0", "pop %rax (forme 8f /0)"),
    ("8fc5", "pop %rbp (forme 8f /0)"),
    # Et les mêmes sous le préfixe de taille : deux octets, pas huit.
    ("66fff5", "pushw %bp (forme ff /6)"),
    ("668fc5", "popw %bp (forme 8f /0)"),
]


def states():
    """Huit états d'entrée.

    RSP n'en fait pas partie : le pilote le pose lui-même au sommet fixe, pour
    qu'un cas qui déborde n'écrase pas le harnais. RBP est mis **sous** le
    sommet pour que `leave` ait quelque chose à faire, et RSI sur la fenêtre
    de données pour que les atomiques y écrivent."""
    fixed = [0xAAAAAAAAAAAAAAAA + i for i in range(16)]
    # RAX porte tour à tour une valeur quelconque et le contenu exact du
    # premier mot de la fenêtre : c'est la seule façon que `cmpxchg` prenne
    # ses deux branches.
    matching = int.from_bytes(bytes(0x10 + i for i in range(8)), "little")
    accumulators = [0x0123456789ABCDEF, matching, 0, 0xFFFFFFFFFFFFFFFF]
    counts = [1, 65, 0x1F, 0x80]
    for index, (accumulator, count) in enumerate(zip(accumulators, counts)):
        for carry in [0, CF | ZF | SF]:
            state = list(fixed)
            state[0] = accumulator
            state[1] = count
            state[5] = STACK - 32
            state[6] = DATA
            yield state + [carry | 0x002]


def assemble(texts):
    """Les octets de chaque ligne. Une instruction longue tient sur plusieurs
    lignes chez objdump ; les suivantes n'ont pas de mnémonique et se
    rattachent à la précédente."""
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
    started = re.compile(r"^\s*[0-9a-f]+:\t([0-9a-f]{2}(?: [0-9a-f]{2})*) *\t")
    continued = re.compile(r"^\s*[0-9a-f]+:\t([0-9a-f]{2}(?: [0-9a-f]{2})*) *$")
    encoded = []
    for row in listing.splitlines():
        if match := started.match(row):
            encoded.append("".join(match.group(1).split()))
        elif (match := continued.match(row)) and encoded:
            encoded[-1] += "".join(match.group(1).split())
    if len(encoded) != len(texts):
        raise SystemExit(f"{len(texts)} instructions demandées, {len(encoded)} relues")
    return encoded


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output")
    parser.add_argument("--oracle", default="scripts/x86-oracle/oracle")
    arguments = parser.parse_args()

    shapes = [(text, text) for text in FORMS]
    encoded = assemble(FORMS) + [octets for octets, _ in EXPLICIT]
    shapes += [(text, text) for _, text in EXPLICIT]
    chosen = list(states())

    request = []
    cases = []
    for instruction, hexadecimal in enumerate(encoded):
        for index, state in enumerate(chosen):
            request.append(hexadecimal + "\t" + "\t".join(f"{v:x}" for v in state))
            cases.append((instruction, index, state))

    answer = subprocess.run([arguments.oracle], input="\n".join(request) + "\n",
                            capture_output=True, text=True, check=True).stdout.splitlines()
    if len(answer) != len(cases):
        raise SystemExit(f"{len(cases)} cas envoyés, {len(answer)} verdicts reçus")

    data_pristine = "".join(f"{0x10 + i:02x}" for i in range(WINDOW))
    stack_pristine = ("".join(f"{(0xB0 + i) & 0xFF:02x}" for i in range(STACKWIN))
                      + "".join(f"{0x40 + i:02x}" for i in range(STACKWIN)))
    with open(arguments.output, "w") as out:
        out.write("# Ce que le vrai processeur répond sur la pile et les atomiques.\n")
        out.write("# Voir scripts/build-x86-stack-oracle.py.\n")
        out.write("# état\t<indice>\t<seize registres>\t<drapeaux>\n")
        out.write("# instr\t<indice>\t<octets>\t<masque des drapeaux>\t<mnémonique>\n")
        out.write("# cas\t<instr>\t<état>\t<seize registres>\t<drapeaux>"
                  "\t<données>\t<pile>\n")
        out.write("#   RSP part de 0x30003000, posé par le pilote ; RBP de 32 octets\n")
        out.write("#   plus bas ; RSI sur la fenêtre de données de 0x30001000.\n")
        out.write("#   La fenêtre de pile fait 128 octets, de 0x30002fc0 à 0x30003040 :\n")
        out.write("#   le motif 0xb0.. en dessous du sommet, 0x40.. au-dessus.\n")
        out.write("#   « - » quand une fenêtre est restée telle qu'on l'avait posée.\n")
        for index, state in enumerate(chosen):
            out.write("état\t%d\t%s\t%x\n"
                      % (index, "\t".join(f"{v:x}" for v in state[:16]), state[16]))
        for index, hexadecimal in enumerate(encoded):
            out.write("instr\t%d\t%s\t%x\t%s\n"
                      % (index, hexadecimal, defined_flags(shapes[index][0]),
                         shapes[index][1]))
        for (instruction, index, _), verdict in zip(cases, answer):
            fields = verdict.split("\t")
            after = [int(value, 16) for value in fields[18:35]]
            data, stack = fields[35], fields[36]
            out.write("cas\t%d\t%d\t%s\t%x\t%s\t%s\n"
                      % (instruction, index,
                         "\t".join(f"{v:x}" for v in after[:16]),
                         after[16] & ARITHMETIC_FLAGS,
                         "-" if data == data_pristine else data,
                         "-" if stack == stack_pristine else stack))
    print(f"{len(encoded)} formes, {len(cases)} cas", file=sys.stderr)


if __name__ == "__main__":
    main()
