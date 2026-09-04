#!/usr/bin/env python3
"""Fabrique le verdict du **vrai processeur** sur les branchements.

Ce fichier existe parce qu'un comptage l'a réclamé, et le comptage est sans
appel : dans le chargeur dynamique de l'invité il y a **4 659 `jmp`, 4 436
`call`, 1 851 `ret` et près de neuf mille sauts conditionnels**. Sur les
quatre corpus déjà figés — arithmétique, vectoriel, chaînes, pile —
**aucune forme de branchement**. Les seize programmes du corpus arithmétique
en contiennent, mais trois seulement, et par accident : ils étaient là pour
prouver autre chose.

**Le tableau des conditions, lui, est prouvé** : seize `setcc` et seize
`cmovcc` y sont, et le cœur évalue les conditions d'un saut par la même
fonction. Ce qui n'est prouvé nulle part, c'est **où un branchement
atterrit** : le signe du déplacement, le fait qu'il se compte depuis la
**fin** de l'instruction et non son début, les deux largeurs, et le retour.

    scripts/build-x86-branch-oracle.py Tests/Fixtures/x86-branch-oracle.tsv

**Chaque cas est un programme, pas une instruction.** Un saut ne se lit pas
dans un registre : il faut lui donner plusieurs endroits où atterrir, et
faire écrire à chacun une marque reconnaissable. C'est la marque, au bout,
qui dit où l'on est passé — et le processeur et le cœur doivent rendre la
même.
"""

import argparse
import re
import subprocess
import sys
import tempfile
from pathlib import Path

CF, PF, AF, ZF, SF, OF = 1 << 0, 1 << 2, 1 << 4, 1 << 6, 1 << 7, 1 << 11
ARITHMETIC_FLAGS = CF | PF | AF | ZF | SF | OF

# Les seize conditions, dans l'ordre du bas du code d'opération.
CONDITIONS = ["o", "no", "b", "ae", "e", "ne", "be", "a",
              "s", "ns", "p", "np", "l", "ge", "le", "g"]

# La marque que chaque bras écrit. Des valeurs qu'on ne confond pas.
TAKEN = 0xA1
FALLEN = 0xB2
TOOFAR = 0xC3


def conditional(condition, near):
    """Un saut conditionnel, et deux endroits où atterrir.

    Le remplissage force la forme longue quand on la demande : `as` choisit
    la forme courte dès qu'elle suffit, et sans ça la moitié des cas
    n'essaierait qu'un déplacement d'un octet."""
    padding = [".fill 200, 1, 0x90"] if near else []
    return [
        "movq $0, %rax",
        f"j{condition} 1f",
        f"movq ${FALLEN}, %rax",
        "jmp 2f",
    ] + padding + [
        f"1: movq ${TAKEN}, %rax",
        "2:",
    ]


def backwards(condition):
    """Le même saut, mais **en arrière**, et sorti par un compteur.

    Un déplacement négatif est le cas où un décodeur qui oublie le signe
    part en avant dans le décor, et où un cœur qui compte depuis le début de
    l'instruction au lieu de sa fin se décale d'exactement sa longueur."""
    return [
        f"movq ${TOOFAR}, %rax",
        "movl $3, %ecx",
        f"1: movq ${TAKEN}, %rax",
        "decl %ecx",
        f"j{condition} 3f",
        "jmp 2f",
        "3: cmpl $0, %ecx",
        "jne 1b",
        f"movq ${FALLEN}, %rax",
        "2:",
    ]


PROGRAMS = []


def register(name, lines):
    PROGRAMS.append((name, lines))


for name in CONDITIONS:
    register(f"j{name} court", conditional(name, near=False))
    register(f"j{name} long", conditional(name, near=True))
    register(f"j{name} en arrière", backwards(name))

# Les sauts inconditionnels, sous toutes leurs formes.
register("jmp court", ["movq $0, %rax", "jmp 1f", f"movq ${FALLEN}, %rax",
                       f"1: movq ${TAKEN}, %rax"])
register("jmp long", ["movq $0, %rax", "jmp 1f", f"movq ${FALLEN}, %rax",
                      ".fill 200, 1, 0x90", f"1: movq ${TAKEN}, %rax"])
register("jmp par registre", ["leaq 1f(%rip), %rdx", "jmp *%rdx",
                              f"movq ${FALLEN}, %rax", f"1: movq ${TAKEN}, %rax"])
register("jmp par la mémoire", ["leaq 1f(%rip), %rdx", "movq %rdx, (%rsi)",
                                "jmp *(%rsi)", f"movq ${FALLEN}, %rax",
                                f"1: movq ${TAKEN}, %rax"])
# **Le préfixe de taille ne raccourcit pas un saut proche en mode 64 bits.**
# Un décodeur qui le croirait lirait deux octets de déplacement au lieu de
# quatre et repartirait au milieu d'une instruction.
register("jmp long avec le préfixe de taille",
         ["movq $0, %rax", ".byte 0x66", "jmp 1f", f"movq ${FALLEN}, %rax",
          ".fill 200, 1, 0x90", f"1: movq ${TAKEN}, %rax"])

# L'appel et le retour, sous leurs trois formes d'appel.
register("call et ret", ["call 1f", "jmp 2f", f"1: movq ${TAKEN}, %rax", "ret",
                         f"2: addq ${FALLEN}, %rax"])
register("call par registre et ret",
         ["leaq 1f(%rip), %rdx", "call *%rdx", "jmp 2f",
          f"1: movq ${TAKEN}, %rax", "ret", f"2: addq ${FALLEN}, %rax"])
register("call par la mémoire et ret",
         ["leaq 1f(%rip), %rdx", "movq %rdx, (%rsi)", "call *(%rsi)", "jmp 2f",
          f"1: movq ${TAKEN}, %rax", "ret", f"2: addq ${FALLEN}, %rax"])
# `ret imm16` : dépiler l'adresse **puis** jeter des arguments. C'est ce que
# fait une convention d'appel où l'appelé nettoie la pile.
register("ret qui jette ses arguments",
         ["pushq $0x1111", "pushq $0x2222", "call 1f", "jmp 2f",
          f"1: movq ${TAKEN}, %rax", "ret $16", f"2: addq ${FALLEN}, %rax"])
# Deux appels imbriqués : le second retour doit rendre la main au premier.
register("deux appels imbriqués",
         ["call 1f", "jmp 3f", "1: call 2f", "addq $1, %rax", "ret",
          f"2: movq ${TAKEN}, %rax", "ret", f"3: addq ${FALLEN}, %rax"])

# `loop` et ses variantes, plus le saut sur RCX nul : quatre formes qui lisent
# RCX au lieu des drapeaux, et que rien d'autre n'éprouve.
register("loop", ["movl $4, %ecx", "xorq %rax, %rax",
                  "1: incq %rax", "loop 1b"])
register("loope", ["movl $4, %ecx", "xorq %rax, %rax",
                   "1: incq %rax", "cmpq %rax, %rax", "loope 1b"])
register("loopne", ["movl $4, %ecx", "xorq %rax, %rax",
                    "1: incq %rax", "cmpq %rax, %rax", "loopne 1b"])
register("jrcxz avec rcx nul", ["xorl %ecx, %ecx", "jrcxz 1f",
                                f"movq ${FALLEN}, %rax", "jmp 2f",
                                f"1: movq ${TAKEN}, %rax", "2:"])
register("jrcxz avec rcx non nul", ["movl $7, %ecx", "jrcxz 1f",
                                    f"movq ${FALLEN}, %rax", "jmp 2f",
                                    f"1: movq ${TAKEN}, %rax", "2:"])

REGISTERS = [
    "rax", "rcx", "rdx", "rbx", "rsp", "rbp", "rsi", "rdi",
    "r8", "r9", "r10", "r11", "r12", "r13", "r14", "r15",
]

DATA = 0x30001000


def states():
    """Les états d'entrée : ce sont les **drapeaux** qui comptent ici.

    Chaque combinaison utile des six, pour que chacune des seize conditions
    soit essayée prise et non prise. RSI pointe la fenêtre de données, où les
    sauts indirects par la mémoire vont chercher leur cible."""
    fixed = [0xAAAAAAAAAAAAAAAA + i for i in range(16)]
    flags = [0, CF, ZF, SF, OF, PF, CF | ZF, SF | OF, ZF | SF | OF,
             CF | PF | AF | ZF | SF | OF]
    for value in flags:
        state = list(fixed)
        state[0] = 0
        state[6] = DATA
        yield state + [value | 0x002]


def assemble(lines):
    with tempfile.TemporaryDirectory() as directory:
        source = Path(directory) / "p.s"
        obj = Path(directory) / "p.o"
        binary = Path(directory) / "p.bin"
        with open(source, "w") as out:
            out.write(".text\n" + "".join(f"    {line}\n" for line in lines))
        subprocess.run(["as", "--64", "-o", str(obj), str(source)], check=True)
        subprocess.run(["objcopy", "-O", "binary", "-j", ".text",
                        str(obj), str(binary)], check=True)
        return open(binary, "rb").read().hex()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output")
    parser.add_argument("--oracle", default="scripts/x86-oracle/oracle")
    arguments = parser.parse_args()

    encoded = [assemble(lines) for _, lines in PROGRAMS]
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

    with open(arguments.output, "w") as out:
        out.write("# Ce que le vrai processeur répond sur les branchements.\n")
        out.write("# Voir scripts/build-x86-branch-oracle.py.\n")
        out.write("# état\t<indice>\t<drapeaux>\n")
        out.write("# instr\t<indice>\t<octets>\t<nom>\n")
        out.write("# cas\t<instr>\t<état>\t<rax>\t<rcx>\t<rdx>\t<rsp>\t<drapeaux>\n")
        out.write("#   RAX porte la marque du bras où l'on a atterri :\n")
        out.write("#   a1 pris, b2 tombé à côté, c3 jamais entré dans la boucle.\n")
        out.write("#   RSP dit que la pile est revenue là où elle était.\n")
        for index, state in enumerate(chosen):
            out.write("état\t%d\t%x\n" % (index, state[16] & ARITHMETIC_FLAGS))
        for index, (hexadecimal, (name, _)) in enumerate(zip(encoded, PROGRAMS)):
            out.write("instr\t%d\t%s\t%s\n" % (index, hexadecimal, name))
        for (instruction, index, before), verdict in zip(cases, answer):
            fields = verdict.split("\t")
            after = [int(value, 16) for value in fields[18:35]]
            for register in [3] + list(range(8, 16)):
                if after[register] != before[register]:
                    raise SystemExit(
                        f"{PROGRAMS[instruction][0]} a écrit dans {REGISTERS[register]}")
            out.write("cas\t%d\t%d\t%x\t%x\t%x\t%x\t%x\n"
                      % (instruction, index, after[0], after[1], after[2],
                         after[4], after[16] & ARITHMETIC_FLAGS))
    print(f"{len(encoded)} programmes, {len(cases)} cas", file=sys.stderr)


if __name__ == "__main__":
    main()
