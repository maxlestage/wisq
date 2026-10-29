#!/usr/bin/env python3
"""Fabrique le verdict du **vrai processeur** sur les formes VEX.256 qui
calculent par moitiés de cent vingt-huit bits.

    scripts/build-x86-avx256-oracle.py Tests/Fixtures/x86-avx256-oracle.tsv

**Pourquoi.** La glibc de RHEL 10 choisit ses fonctions de chaîne et de
mémoire AVX2 — `memcpy`, `strlen`, `memchr` — dès que le processeur annonce
AVX2 ; elles travaillent sur des YMM entiers. Presque toutes les opérations
de 256 bits font deux fois celle de SSE, une par moitié : c'est ce que le
cœur exécute (`Sources/WisqVM/X86AVX256.swift`), et ce que ce corpus juge.

**Les formes viennent du corpus VEX.128** (`x86-avx128-oracle.tsv`), xmm
récrit en ymm : l'assembleur refuse d'emblée celles qui n'ont pas de forme
de 256 bits (`vmovss`, `vpextrb`, `vcomisd`…) ou dont la forme de 256 bits
change de largeur (`vcvtdq2pd`, `vpmovzxbw`), et elles sont laissées. Deux
retouches :

- le compte d'un décalage par un registre reste un XMM
  (`vpsrld %xmm1, %ymm2, %ymm0`) ;
- un opérande en mémoire est ramené à `0x20(%rsi)` au plus, pour que ses
  trente-deux octets tiennent dans la fenêtre que le harnais rend.

`vpclmulqdq` et `vaes*` sur 256 bits sont des extensions à part (VPCLMULQDQ,
VAES), que ce cœur n'annonce pas : laissées aussi.

**Ce que le fichier porte** : xmm0 à xmm2 entiers, avec le haut de leur YMM,
RAX, RCX, RDX, les drapeaux et la fenêtre de mémoire. Le reste — xmm3 à
xmm15, leurs hauts, les autres registres généraux — doit revenir intact,
vérifié ici, sur la machine.
"""

import argparse
import importlib.util
import re
import subprocess
import sys
from pathlib import Path

ARITHMETIC_FLAGS = (1 << 0) | (1 << 2) | (1 << 4) | (1 << 6) | (1 << 7) | (1 << 11)
REGISTERS = [
    "rax", "rcx", "rdx", "rbx", "rsp", "rbp", "rsi", "rdi",
    "r8", "r9", "r10", "r11", "r12", "r13", "r14", "r15",
]
SHIFT_BY_REGISTER = {"vpsllw", "vpslld", "vpsllq", "vpsrlw", "vpsrld", "vpsrlq", "vpsraw", "vpsrad"}
OTHER_EXTENSIONS = ("vpclmul", "vaes")
# `vcvtps2pd` lit seize octets pour en écrire trente-deux : il traverse les
# moitiés, et attend la tranche de ce qui les traverse.
CROSSING = {"vcvtps2pd"}
# Ce que les corpus SSE n'avaient pas, et que le partage par moitiés doit
# tenir : l'immédiat de `vshufpd`, qui a des bits par moitié ; l'arithmétique
# flottante empaquetée ; les comptes qui sont aussi la destination ; les
# rangements de trente-deux octets.
EXTRA = [
    "vshufpd $0x5, %ymm1, %ymm2, %ymm0", "vshufpd $0xa, %ymm0, %ymm2, %ymm0",
    "vaddps %ymm1, %ymm2, %ymm0", "vsubps %ymm1, %ymm2, %ymm0", "vmulps %ymm1, %ymm2, %ymm0",
    "vdivps %ymm1, %ymm2, %ymm0", "vsubpd %ymm1, %ymm2, %ymm0", "vdivpd 0x10(%rsi), %ymm2, %ymm0",
    "vpsrld %xmm0, %ymm0, %ymm0", "vpslld %xmm2, %ymm1, %ymm2", "vpsrld 0x10(%rsi), %ymm1, %ymm0",
    "vmovdqu %ymm1, 0x8(%rsi)", "vmovups %ymm2, (%rsi)", "vpmovmskb %ymm0, %eax", "vptest %ymm0, %ymm0",
]
# L'image x87 d'un processeur remis à zéro, en quatorze cases : ce que le
# pilote fabrique lui-même pour les lignes plus courtes.
FPU_DEFAULT = [0x037F, 0xFFFF] + [0] * 12


def load(name):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).parent / f"build-x86-{name}-oracle.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def to_ymm(text):
    mnemonic, _, rest = text.partition(" ")
    if mnemonic.startswith(OTHER_EXTENSIONS) or mnemonic in CROSSING:
        return None
    args = load.avx128.operands(rest)
    out = []
    for index, arg in enumerate(args):
        if mnemonic in SHIFT_BY_REGISTER and index == 0 and not arg.startswith("$"):
            out.append(arg)  # le compte : un XMM, ou seize octets de mémoire
            continue
        arg = arg.replace("%xmm", "%ymm")
        found = re.match(r"(-?0x[0-9a-f]+|\d+)?\(%rsi\)", arg)
        if found and found.group(1) and int(found.group(1), 0) > 0x20:
            arg = "0x20(%rsi)"
        out.append(arg)
    converted = f"{mnemonic} {', '.join(out)}"
    return None if converted == text else converted


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output")
    parser.add_argument("--oracle", default="scripts/x86-oracle/oracle")
    arguments = parser.parse_args()

    fixtures = Path(arguments.output).parent
    v2 = load("v2")
    load.avx128 = load("avx128")
    seen, candidates = set(), []
    for line in (fixtures / "x86-avx128-oracle.tsv").read_text().splitlines():
        if line.startswith("instr\t"):
            form = to_ymm(line.split("\t")[3])
            if form and form not in seen:
                seen.add(form)
                candidates.append(form)
    candidates += [form for form in EXTRA if form not in seen]
    texts = [text for text in candidates if load.avx128.assembles(text)]
    print(f"{len(texts)} formes sur {len(candidates)} candidates", file=sys.stderr)
    encoded = v2.assemble(texts)

    # Les états du corpus VEX.128, et un haut pour chaque YMM : xmm0 à xmm2
    # reçoivent des valeurs de la même liste, décalées ; les autres un témoin.
    count = len(v2.VALUES)
    chosen = []
    for index, (general, vectors) in enumerate(list(v2.states())[::2][:40]):
        vectors = list(vectors)
        vectors[2] = v2.VALUES[(index * 5 + 2) % count]
        uppers = [(0xE000_0000_0000_0000 + 2 * i, 0xF000_0000_0000_0000 + 2 * i) for i in range(16)]
        for register in range(3):
            uppers[register] = v2.VALUES[(index * 3 + 7 * register + 1) % count]
        chosen.append((general, vectors, uppers))

    request, cases = [], []
    for instruction, hexadecimal in enumerate(encoded):
        for index, (general, vectors, uppers) in enumerate(chosen):
            values = list(general)
            for low, high in vectors:
                values += [low, high]
            values += FPU_DEFAULT
            for low, high in uppers:
                values += [low, high]
            request.append(hexadecimal + "\t" + "\t".join(f"{v:x}" for v in values))
            cases.append((instruction, index))
    answer = subprocess.run([arguments.oracle], input="\n".join(request) + "\n",
                            capture_output=True, text=True, check=True).stdout.splitlines()
    if len(answer) != len(cases):
        raise SystemExit(f"{len(cases)} cas envoyés, {len(answer)} verdicts reçus")

    window = "".join(f"{0x10 + i:02x}" for i in range(64))
    with open(arguments.output, "w") as out:
        out.write("# Ce que le vrai processeur répond sur les formes VEX.256 qui calculent par moitiés.\n")
        out.write("# Voir scripts/build-x86-avx256-oracle.py.\n")
        out.write("# état\t<indice>\t<xmm0 bas, haut, puis le haut de ymm0 : deux mots>\t<de même pour 1 et 2>"
                  "\t<rax>\t<rcx>\t<drapeaux>\t<rdx>\n")
        out.write("# instr\t<indice>\t<octets>\t<mnémonique>\n")
        out.write("# cas\t<instr>\t<état>\t<douze mots : ymm0, ymm1, ymm2 du bas vers le haut>"
                  "\t<rax>\t<rcx>\t<drapeaux>\t<fenêtre, ou - intacte>\t<rdx>\n")
        for index, (general, vectors, uppers) in enumerate(chosen):
            words = []
            for register in range(3):
                words += [*vectors[register], *uppers[register]]
            out.write("état\t%d\t%s\t%x\t%x\t%x\t%x\n"
                      % (index, "\t".join(f"{w:x}" for w in words),
                         general[0], general[1], general[16] & ARITHMETIC_FLAGS, general[2]))
        for index, (hexadecimal, text) in enumerate(zip(encoded, texts)):
            out.write("instr\t%d\t%s\t%s\n" % (index, hexadecimal, text))
        for (instruction, index), verdict in zip(cases, answer):
            general, vectors, uppers = chosen[index]
            fields = verdict.split("\t")
            after = [int(value, 16) for value in fields[96:191]]
            for register in [3] + list(range(8, 16)):
                if after[register] != general[register]:
                    raise SystemExit(f"{texts[instruction]} a écrit dans {REGISTERS[register]}")
            for vector in range(3, 16):
                if (after[17 + 2 * vector], after[18 + 2 * vector]) != vectors[vector]:
                    raise SystemExit(f"{texts[instruction]} a écrit dans xmm{vector}")
                if (after[63 + 2 * vector], after[64 + 2 * vector]) != uppers[vector]:
                    raise SystemExit(f"{texts[instruction]} a écrit dans le haut de ymm{vector}")
            words = []
            for register in range(3):
                words += after[17 + 2 * register:19 + 2 * register] + after[63 + 2 * register:65 + 2 * register]
            memory = "-" if fields[191] == window else fields[191]
            out.write("cas\t%d\t%d\t%s\t%x\t%x\t%x\t%s\t%x\n"
                      % (instruction, index, "\t".join(f"{w:x}" for w in words),
                         after[0], after[1], after[16] & ARITHMETIC_FLAGS, memory, after[2]))
    print(f"{len(encoded)} instructions, {len(cases)} cas", file=sys.stderr)


if __name__ == "__main__":
    main()
