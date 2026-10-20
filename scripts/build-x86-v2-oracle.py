#!/usr/bin/env python3
"""Fabrique le verdict du **vrai processeur** sur ce que x86-64-v2 ajoute.

    scripts/build-x86-v2-oracle.py Tests/Fixtures/x86-v2-oracle.tsv

**Pourquoi.** AlmaLinux 9, Rocky 9 et CentOS Stream 9 sont compilés pour
x86-64-v2 : leur glibc refuse de démarrer sur un processeur qui n'annonce pas
SSE3, SSSE3, SSE4.1, SSE4.2, POPCNT et CMPXCHG16B, et le reste de leurs
binaires emploie ces instructions sans demander. Ce cœur n'annonçait rien
de tout cela.

**Le cadrage vient d'un comptage**, comme pour SSE2 : `objdump` sur chaque ELF
de `/usr` d'AlmaLinux 9.8 (GenericCloud du 5 octobre 2026), les mnémoniques
de ces extensions que le cœur ne savait pas exécuter. Les plus fréquents :

    pinsrq 9490  palignr 4948  pinsrd 1582  pshufb 1581  lddqu 1146
    pminub 776   pmaxsd 493    roundsd 462  pminud 450   pcmpistri 404
    pextrq 371   pblendvb 344  pmaxud 300   pblendw 261  pminsd 236
    movddup 227  pabsd 214     pmovzxwd 190 packusdw 187 pmovzxdq 171

et trente-quatre autres, jusqu'à `phaddsw` (une fois). Ils entrent par
tranches, chacune avec son corpus ; les bits de `CPUID` ne s'allument qu'à la
fin, quand tout y est.

**Ce que ce corpus rapporte en plus de celui de SSE2** : RCX et les drapeaux
— `PTEST` et `PCMPISTRI` en écrivent — et la fenêtre de mémoire, que
`PEXTR*` vers la mémoire écrira. Ce qu'une forme ne doit pas toucher est
vérifié ici, sur la machine, avant d'être exigé du cœur.
"""

import argparse
import re
import subprocess
import sys
import tempfile
from pathlib import Path

DATA = 0x30001000
# Les formes alignées (`PSHUFB m128`…) l'exigent ; les autres l'acceptent.
ALIGNED = 0x20

REGISTERS = [
    "rax", "rcx", "rdx", "rbx", "rsp", "rbp", "rsi", "rdi",
    "r8", "r9", "r10", "r11", "r12", "r13", "r14", "r15",
]


def forms():
    """Les formes à l'essai. Chacune ne touche que xmm0, xmm1, RAX, RCX, les
    drapeaux et la fenêtre de données."""
    out = []
    # **SSSE3.** `PSHUFB` choisit chaque octet de la destination par un octet
    # de la source — et le met à zéro quand le bit 7 de celui-ci est levé :
    # d'où les octets 0x80 et 0xFF des valeurs. `PALIGNR` colle les deux
    # registres en trente-deux octets et en prend seize à partir de
    # l'immédiat : au-delà de seize, il puise dans la seule source, au-delà
    # de trente-deux, il rend zéro.
    for name in ["pshufb", "pabsb", "pabsw", "pabsd", "pmaddubsw", "phaddsw"]:
        out += [f"{name} %xmm1, %xmm0", f"{name} {ALIGNED:#x}(%rsi), %xmm0"]
    for shift in [0, 1, 4, 8, 15, 16, 17, 24, 31, 32, 200]:
        out += [f"palignr ${shift}, %xmm1, %xmm0", f"palignr ${shift}, {ALIGNED:#x}(%rsi), %xmm0"]
    # **Les déplacements de SSE3**, sans arithmétique : `LDDQU` est un
    # `MOVDQU` (non aligné exprès : +0x21), `MOVDDUP` diffuse la moitié basse,
    # `MOVSLDUP` les mots pairs.
    out += ["lddqu 0x21(%rsi), %xmm0",
            "movddup %xmm1, %xmm0", f"movddup {ALIGNED:#x}(%rsi), %xmm0",
            "movddup 0x23(%rsi), %xmm0",
            "movsldup %xmm1, %xmm0", f"movsldup {ALIGNED:#x}(%rsi), %xmm0"]
    # **SSE4.1, l'entier.** Les minimums et maximums signés et sans signe
    # que SSE2 n'avait pas, le resserrement sans signe des mots doubles, la
    # comparaison et les multiplications de SSE4.1.
    for name in ["pminsb", "pmaxsb", "pminuw", "pmaxuw", "pminsd", "pmaxsd", "pminud",
                 "pmaxud", "packusdw", "pcmpeqq", "pmulld", "pmuldq"]:
        out += [f"{name} %xmm1, %xmm0", f"{name} {ALIGNED:#x}(%rsi), %xmm0"]
    # Les mélanges : par l'immédiat (`PBLENDW`), ou par le bit de signe de
    # chaque élément de **xmm0**, implicite (`PBLENDVB`, `BLENDVPS`,
    # `BLENDVPD`). xmm0 étant le masque, la destination est xmm1 ; entre
    # registres, la source est xmm0 lui-même — le masque choisit alors ses
    # propres éléments négatifs.
    for control in [0x00, 0xFF, 0x0F, 0xA5, 0x3C]:
        out += [f"pblendw ${control:#x}, %xmm1, %xmm0", f"pblendw ${control:#x}, {ALIGNED:#x}(%rsi), %xmm0"]
    for name in ["pblendvb", "blendvps", "blendvpd"]:
        out += [f"{name} %xmm0, %xmm0, %xmm1", f"{name} %xmm0, {ALIGNED:#x}(%rsi), %xmm1"]
    # Les élargissements, avec ou sans signe. **Depuis la mémoire, ils ne
    # lisent que ce qu'ils élargissent** : deux octets pour `PMOVZXBQ`. Une
    # lecture de seize octets déborderait sur une page qui peut ne pas
    # exister.
    for kind in ["zx", "sx"]:
        for shape, width in [("bw", 8), ("bd", 4), ("bq", 2), ("wd", 8), ("wq", 4), ("dq", 8)]:
            out += [f"pmov{kind}{shape} %xmm1, %xmm0", f"pmov{kind}{shape} 0x3e(%rsi), %xmm0"]
    # `PTEST` n'écrit que des drapeaux : ZF si la conjonction est nulle, CF si
    # la source sans la destination l'est.
    out += ["ptest %xmm1, %xmm0", f"ptest {ALIGNED:#x}(%rsi), %xmm0", "ptest %xmm0, %xmm0"]
    # Insérer et extraire, depuis et vers un registre général ou la mémoire.
    # Les rangs au-delà de la largeur se replient : seuls les bits bas de
    # l'immédiat comptent.
    for position in [0, 1, 7, 15, 16]:
        out += [f"pinsrb ${position}, %eax, %xmm0", f"pinsrb ${position}, 0x25(%rsi), %xmm0",
                f"pextrb ${position}, %xmm1, %eax", f"pextrb ${position}, %xmm1, 0x25(%rsi)"]
    for position in [0, 1, 3, 4]:
        out += [f"pinsrd ${position}, %eax, %xmm0", f"pinsrd ${position}, 0x24(%rsi), %xmm0",
                f"pextrd ${position}, %xmm1, %eax", f"pextrd ${position}, %xmm1, 0x24(%rsi)",
                f"extractps ${position}, %xmm1, %eax", f"extractps ${position}, %xmm1, 0x24(%rsi)",
                f"extractps ${position}, %xmm1, %rax"]
    for position in [0, 1, 2]:
        out += [f"pinsrq ${position}, %rax, %xmm0", f"pinsrq ${position}, 0x28(%rsi), %xmm0",
                f"pextrq ${position}, %xmm1, %rax", f"pextrq ${position}, %xmm1, 0x28(%rsi)"]
    # `INSERTPS` : le mot que choisissent les bits 7-6 (depuis un registre
    # seulement), posé où disent les bits 5-4, puis les mots que nomment les
    # bits 3-0 mis à zéro.
    for control in [0x00, 0x10, 0x30, 0xC0, 0x4E, 0x91, 0xF8, 0x0F]:
        out += [f"insertps ${control:#x}, %xmm1, %xmm0", f"insertps ${control:#x}, 0x24(%rsi), %xmm0"]
    # **SSE4.2.** La comparaison signée des mots quadruples, et
    # `PCMPISTRI`, le comparateur de chaînes : la longueur de chaque
    # opérande s'arrête à son premier élément nul, et l'immédiat choisit la
    # taille (octets ou mots, avec ou sans signe), l'agrégation (égal à l'un
    # des, intervalles, égal un à un, sous-chaîne), la polarité et le bout
    # d'où l'indice se compte. La glibc d'AlmaLinux n'emploie que 0x1a, 0x3a,
    # 0x02 et 0x12 ; les autres valeurs couvrent ce que ces quatre ne
    # touchent pas.
    out += ["pcmpgtq %xmm1, %xmm0", f"pcmpgtq {ALIGNED:#x}(%rsi), %xmm0"]
    for control in [0x1A, 0x3A, 0x02, 0x12, 0x00, 0x04, 0x08, 0x0C, 0x01, 0x05, 0x09, 0x0D,
                    0x03, 0x06, 0x07, 0x0B, 0x0F, 0x30, 0x40, 0x4C, 0x44, 0x46, 0x29, 0x6D]:
        out += [f"pcmpistri ${control:#x}, %xmm1, %xmm0",
                f"pcmpistri ${control:#x}, {ALIGNED:#x}(%rsi), %xmm0"]
    # Les drapeaux vers AH et retour, qu'un processeur x86-64 des débuts
    # n'avait pas en mode long.
    out += ["lahf", "sahf"]
    # `CMPXCHG16B` : RDX:RAX comparé aux seize octets ; égaux, RCX:RBX y
    # sont rangés ; sinon ils sont relus dans RDX:RAX. Les états où RAX et
    # RDX portent la fenêtre font l'égalité.
    out += [f"lock cmpxchg16b {ALIGNED:#x}(%rsi)", f"cmpxchg16b {ALIGNED:#x}(%rsi)"]
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
    # Un petit compte dans le bas, pour les décalages par registre, et des mots
    # aux deux bords du signe.
    (0x0000000000000003, 0x8001800180017FFF),
    (0x000000000000001F, 0x7FFF00FF80000100),
    # Des octets autour de 0x7F, 0x80 et 0xFF : la saturation et la
    # comparaison signée s'y décident.
    (0x80FF7F0001FE817E, 0x00FF00800080FF7F),
    # Des indices de `PSHUFB` : petits, à bit 7 levé, et au-delà de quinze
    # (seuls les quatre bits bas comptent).
    (0x8F0E1D2C3B4A5968, 0x0102030405060708),
    (0x8000800080008000, 0x7FFF7FFF80018001),
    # Des chaînes, pour `PCMPISTRI` : « wisq lit » terminé tôt, des
    # intervalles « az » et « 09 », et une sous-chaîne présente plus loin.
    (0x74696C2071736977, 0x0000000000000000),
    (0x0000000039307A61, 0x0000000000000000),
    (0x3534333231303938, 0x3D3C3B3A39383736),
    (0x0000000000003534, 0x0000000000000000),
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
        # Un état sur cinq porte dans RDX:RAX les seize octets que
        # `CMPXCHG16B` trouve en mémoire : c'est l'échange réussi.
        if index % 5 == 4:
            general[0], general[2] = 0x3736353433323130, 0x3F3E3D3C3B3A3938
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
            # **Quinze octets par ligne.** Au-delà de sept, objdump continue
            # une instruction sur la ligne suivante, que l'expression ne lit
            # pas : `pinsrq $0, 0x28(%rsi), %xmm0` perdait son immédiat, et
            # le processeur exécutait ce qui venait après.
            ["objdump", "-d", "--insn-width=15", str(obj)],
            capture_output=True, text=True, check=True).stdout

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

    window = ("101112131415161718191a1b1c1d1e1f"
              "202122232425262728292a2b2c2d2e2f"
              "303132333435363738393a3b3c3d3e3f"
              "404142434445464748494a4b4c4d4e4f")
    with open(arguments.output, "w") as out:
        out.write("# Ce que le vrai processeur répond sur ce que x86-64-v2 ajoute.\n")
        out.write("# Voir scripts/build-x86-v2-oracle.py.\n")
        out.write("# état\t<indice>\t<xmm0 bas>\t<xmm0 haut>\t<xmm1 bas>\t<xmm1 haut>"
                  "\t<rax>\t<rcx>\t<drapeaux>\t<rdx>\n")
        out.write("# instr\t<indice>\t<octets>\t<mnémonique>\n")
        out.write("# cas\t<instr>\t<état>\t<xmm0 bas>\t<xmm0 haut>\t<xmm1 bas>"
                  "\t<xmm1 haut>\t<rax>\t<rcx>\t<drapeaux>\t<fenêtre, ou - intacte>\t<rdx>\n")
        out.write("#   RSI pointe la fenêtre de 64 octets à 0x30001000 ; elle part\n")
        out.write("#   des octets 0x10, 0x11… Les drapeaux sont ceux de l'arithmétique.\n")
        for index, (general, vectors) in enumerate(chosen):
            out.write("état\t%d\t%x\t%x\t%x\t%x\t%x\t%x\t%x\t%x\n"
                      % (index, vectors[0][0], vectors[0][1], vectors[1][0], vectors[1][1],
                         general[0], general[1], general[16] & ARITHMETIC_FLAGS, general[2]))
        for index, (hexadecimal, text) in enumerate(zip(encoded, texts)):
            out.write("instr\t%d\t%s\t%s\n" % (index, hexadecimal, text))
        for (instruction, index, general, vectors), verdict in zip(cases, answer):
            fields = verdict.split("\t")
            after = [int(value, 16) for value in fields[50:99]]
            for register in [3] + list(range(8, 16)):
                if after[register] != general[register]:
                    raise SystemExit(
                        f"{texts[instruction]} a écrit dans {REGISTERS[register]}")
            for vector in range(2, 16):
                got = (after[17 + 2 * vector], after[18 + 2 * vector])
                if got != vectors[vector]:
                    raise SystemExit(f"{texts[instruction]} a écrit dans xmm{vector}")
            memory = "-" if fields[99] == window else fields[99]
            out.write("cas\t%d\t%d\t%x\t%x\t%x\t%x\t%x\t%x\t%x\t%s\t%x\n"
                      % (instruction, index, after[17], after[18], after[19], after[20],
                         after[0], after[1], after[16] & ARITHMETIC_FLAGS, memory, after[2]))
    print(f"{len(encoded)} instructions, {len(cases)} cas", file=sys.stderr)


if __name__ == "__main__":
    main()
