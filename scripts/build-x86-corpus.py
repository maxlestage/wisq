#!/usr/bin/env python3
"""Fabrique l'extrait de corpus x86-64 que `X86CorpusTests` compare au décodeur.

Le décodeur de la tranche 2 du lot 7 se prouve contre un désassembleur de
référence, pas contre lui-même. Ce script est ce qui rend cette preuve
reproductible : il désassemble de vrais binaires avec `objdump`, retient un
représentant par **forme** d'instruction, et écrit le verdict d'objdump —
octets, longueur, mnémonique — dans `Tests/Fixtures/x86-corpus.tsv`.

    scripts/build-x86-corpus.py Tests/Fixtures/x86-corpus.tsv \\
        /bin/ls /bin/bash /usr/lib/x86_64-linux-gnu/libc.so.6

Deux choses méritent d'être dites.

**La forme retenue est exactement ce dont la longueur dépend** : les deux
préfixes de taille, le bit W, la table d'opcode, l'opcode, le champ `mod`, le
champ `reg` (dont `F6`/`F7` font dépendre leur immédiat), et les trois formes de
`rm` ou de base SIB qui changent le déplacement. Garder plus, c'est répéter ;
garder moins, c'est perdre un cas de longueur.

**Les binaires d'un système ne couvrent pas tout.** Ni `moffs`, ni `ENTER`, ni
`RET imm16` ne sortent d'un compilateur moderne. Le fichier assembleur rendu par
`--rares` les fabrique, pour qu'eux aussi passent par objdump plutôt que par une
conviction : assemblez-le puis passez le `.o` à ce script comme les autres.
"""

import argparse
import collections
import re
import subprocess
import sys

LINE = re.compile(r"^\s*([0-9a-f]+):\t([0-9a-f]{2}(?: [0-9a-f]{2})*) *(?:\t(.*))?$")

# Les préfixes hérités, tous groupes confondus.
LEGACY = {0xF0, 0xF2, 0xF3, 0x2E, 0x36, 0x3E, 0x26, 0x64, 0x65, 0x66, 0x67}

RARES = r"""
# Les formes qu'aucun compilateur n'émet, et que le corpus d'un système ne
# contient donc pas. Assembler avec :  as --64 -o rares.o rares.s
.text
_start:
    movabs 0x1122334455667788, %rax
    movabs %rax, 0x1122334455667788
    movabs 0x1122334455667788, %al
    movabs %al, 0x1122334455667788
    enter  $0x1234, $0x05
    ret    $0x0010
    lretq  $0x0010
    testb  $0x42, (%rax)
    testl  $0x11223344, (%rax)
    notq   (%rax)
    negq   (%rax)
    mulq   (%rax)
    imulq  (%rax)
    divq   (%rax)
    idivq  (%rax)
    int    $0x80
    int3
    loop   _start
    jrcxz  _start
    in     $0x60, %al
    out    %al, $0x60
    lodsb
    xlat
    fadds  (%rax)
    fldl   (%rax)
    fnstsw %ax
    leave
    hlt
    cpuid
    rdtsc
    syscall
    ud2
    bswap  %rax
    shld   $0x7, %rax, %rbx
    shrd   $0x7, %rax, %rbx
    btq    $0x7, (%rax)
    cmpxchg %rax, (%rbx)
    xadd   %rax, (%rbx)
    movzbq (%rax), %rbx
    movsbq (%rax), %rbx
    pushq  $0x11223344
    pushw  $0x1122
    pushq  $0x42
    imul   $0x11223344, (%rax), %rbx
    imul   $0x42, (%rax), %rbx
    movw   $0x1122, (%rax)
    movl   $0x11223344, (%rax)
    movq   $0x11223344, (%rax)
    movabs $0x1122334455667788, %rax
    movw   $0x1122, %ax
    addw   $0x1122, %ax
    stc
    cld
"""


def instructions(path):
    """(octets, mnémonique) pour chaque instruction qu'objdump a su lire.

    objdump coupe les octets bruts à sept par ligne ; les lignes de
    continuation n'ont pas de mnémonique et sont recollées à la précédente.
    """
    output = subprocess.run(
        ["objdump", "-d", path], capture_output=True, text=True, check=True
    ).stdout
    current = None
    for line in output.splitlines():
        match = LINE.match(line)
        if not match:
            if current:
                yield current
                current = None
            continue
        raw, text = match.group(2).split(), (match.group(3) or "").strip()
        if text == "" and current is not None:
            current = (current[0] + raw, current[1])
            continue
        if current:
            yield current
        current = (raw, text)
    if current:
        yield current


def shape(byte):
    """Ce dont la longueur de l'instruction dépend, et rien d'autre."""
    index = 0
    prefixes = set()
    while index < len(byte) and byte[index] in LEGACY:
        prefixes.add(byte[index])
        index += 1

    wide = vector = None
    table = 0
    if index < len(byte) and byte[index] in (0xC4, 0xC5, 0x62):
        kind = byte[index]
        if kind == 0xC5:  # VEX à deux octets : toujours la table 0F.
            vector, table = "vex2", 1
            index += 2
        elif kind == 0xC4:  # VEX à trois octets : mmmmm désigne la table.
            table = byte[index + 1] & 0x1F if index + 1 < len(byte) else 0
            wide = (byte[index + 2] >> 7) & 1 if index + 2 < len(byte) else 0
            vector = "vex3"
            index += 3
        else:  # EVEX : quatre octets, mmm sur les mêmes tables.
            table = byte[index + 1] & 0x07 if index + 1 < len(byte) else 0
            wide = (byte[index + 2] >> 7) & 1 if index + 2 < len(byte) else 0
            vector = "evex"
            index += 4
    elif index < len(byte) and 0x40 <= byte[index] <= 0x4F:
        wide = (byte[index] >> 3) & 1
        index += 1

    if index >= len(byte):
        return None
    if vector is None:
        if byte[index] == 0x0F:
            index += 1
            if index < len(byte) and byte[index] in (0x38, 0x3A):
                table = 2 if byte[index] == 0x38 else 3
                index += 1
            else:
                table = 1
        else:
            table = 0
    if index >= len(byte):
        return None

    opcode = byte[index]
    index += 1
    mod = reg = rm = base = None
    if index < len(byte):
        mod, reg, rm = byte[index] >> 6, (byte[index] >> 3) & 7, byte[index] & 7
        if mod != 3 and rm == 4 and index + 1 < len(byte):
            base = byte[index + 1] & 7
    return (
        0x66 in prefixes,
        0x67 in prefixes,
        wide,
        vector,
        table,
        opcode,
        mod,
        reg,
        None if rm is None else rm == 4,
        None if rm is None else rm == 5,
        None if base is None else base == 5,
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", nargs="?", help="le fichier .tsv à écrire")
    parser.add_argument("binaries", nargs="*", help="les binaires à désassembler")
    parser.add_argument(
        "--rares", action="store_true",
        help="écrire sur la sortie standard le fichier assembleur des formes rares")
    arguments = parser.parse_args()

    if arguments.rares:
        print(RARES.strip())
        return 0
    if not arguments.output or not arguments.binaries:
        parser.error("il faut un fichier de sortie et au moins un binaire")

    kept = collections.OrderedDict()
    read = 0
    for path in arguments.binaries:
        for raw, text in instructions(path):
            if not text or text.startswith("(bad)"):
                continue
            read += 1
            key = shape([int(b, 16) for b in raw])
            if key is None or key in kept:
                continue
            kept[key] = (raw, text.split()[0])

    with open(arguments.output, "w") as out:
        out.write("# Le verdict d'objdump sur de vraies instructions x86-64,\n")
        out.write("# un représentant par forme. Voir scripts/build-x86-corpus.py.\n")
        out.write("# octets\tlongueur\tmnémonique\n")
        for raw, mnemonic in kept.values():
            out.write("%s\t%d\t%s\n" % ("".join(raw), len(raw), mnemonic))

    print(f"{read} instructions lues, {len(kept)} formes retenues", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
