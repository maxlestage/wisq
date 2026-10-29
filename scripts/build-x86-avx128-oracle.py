#!/usr/bin/env python3
"""Fabrique le verdict du **vrai processeur** sur les formes VEX.128 des
instructions SSE que ce cœur exécute déjà.

    scripts/build-x86-avx128-oracle.py Tests/Fixtures/x86-avx128-oracle.tsv

**Pourquoi.** Compilé pour x86-64-v3, tout le code de RHEL 10 emploie
l'encodage VEX — `vmovdqa`, `vaddsd`, `vpxor` — même là où il ne calcule que
sur cent vingt-huit bits. Ce sont les mêmes opérations que celles de SSE, à
deux différences près : un troisième opérande (`vvvv`) qui sert de première
source sans être écrasé, et le haut du registre YMM de destination mis à
zéro. Le cœur les exécute en passant par les instructions SSE qu'il a déjà.

**Les formes viennent des corpus existants**, et pas d'une liste refaite à
la main : chaque instruction vectorielle de `x86-simd-oracle.tsv`,
`x86-xmm-oracle.tsv`, `x86-float-oracle.tsv` et `x86-v2-oracle.tsv` est
récrite en VEX selon sa famille :

- les formes à deux opérandes (déplacements, conversions vers un registre
  général, extractions, comparaisons qui ne posent que des drapeaux, racines
  et arrondis empaquetés) gardent leurs opérandes ;
- les décalages par un immédiat prennent leur source dans xmm1 et écrivent
  dans `vvvv`, xmm0 ;
- toutes les autres reçoivent xmm2 comme première source, juste avant leur
  destination.

Les mélanges par xmm0 implicite (`blendv*`, `pblendvb`) n'ont pas de forme
VEX semblable — VEX nomme leur masque dans un quatrième registre — et sont
laissés à une tranche à part, comme `crc32`, `lahf`, `sahf` et `cmpxchg16b`,
qui ne sont pas vectoriels.

**Les cas où une source est la destination** sont ajoutés pour chaque forme
à trois registres : `vaddps %xmm0, %xmm2, %xmm0` et `vaddps %xmm1, %xmm0,
%xmm0`. C'est le piège d'une exécution qui recopierait `vvvv` dans la
destination avant de lire l'autre source.

**Ce que le fichier porte** : xmm0, xmm1, xmm2, RAX, RCX, RDX, les drapeaux
et la fenêtre de mémoire. Le reste doit revenir intact — vérifié ici, sur la
machine. Le haut des registres YMM, que le harnais ne lit pas, est tenu par
des tests écrits à la main.
"""

import argparse
import importlib.util
import subprocess
import sys
import tempfile
from pathlib import Path

ARITHMETIC_FLAGS = (1 << 0) | (1 << 2) | (1 << 4) | (1 << 6) | (1 << 7) | (1 << 11)
REGISTERS = [
    "rax", "rcx", "rdx", "rbx", "rsp", "rbp", "rsi", "rdi",
    "r8", "r9", "r10", "r11", "r12", "r13", "r14", "r15",
]

SOURCES = ["x86-simd-oracle.tsv", "x86-xmm-oracle.tsv", "x86-float-oracle.tsv", "x86-v2-oracle.tsv"]

NOT_VECTOR = {"crc32b", "crc32w", "crc32l", "crc32q", "lahf", "sahf", "cmpxchg16b", "lock"}
IMPLICIT_MASK = {"blendvps", "blendvpd", "pblendvb"}
TWO_OPERANDS = {
    "movaps", "movapd", "movups", "movupd", "movdqa", "movdqu", "movd", "movq", "lddqu",
    "movddup", "movsldup", "movshdup", "pshufd", "pshufhw", "pshuflw", "ptest", "pabsb",
    "pabsw", "pabsd", "cvtdq2pd", "cvtdq2ps", "cvtpd2ps", "cvtps2dq", "cvtps2pd", "cvttpd2dq",
    "cvttps2dq", "cvtsd2si", "cvtss2si", "cvttsd2si", "cvttss2si", "comisd", "comiss",
    "ucomisd", "ucomiss", "movmskps", "movmskpd", "pmovmskb", "pextrb", "pextrw", "pextrd",
    "pextrq", "extractps", "sqrtps", "sqrtpd", "roundps", "roundpd", "pcmpistri",
    "pcmpistrm", "pcmpestri", "pcmpestrm", "pcmpestriq", "pcmpestrmq", "movntdqa",
}
IMMEDIATE_SHIFTS = {"psllw", "pslld", "psllq", "psrlw", "psrld", "psrlq", "psraw", "psrad",
                    "pslldq", "psrldq"}


def operands(text):
    """Les opérandes d'une ligne AT&T, sans couper dans les parenthèses."""
    parts, depth, current = [], 0, ""
    for character in text:
        if character == "," and depth == 0:
            parts.append(current.strip())
            current = ""
            continue
        depth += character == "("
        depth -= character == ")"
        current += character
    if current.strip():
        parts.append(current.strip())
    return parts


def to_vex(text):
    """Les formes VEX d'une forme SSE ; aucune quand elle n'en a pas ici."""
    mnemonic, _, rest = text.partition(" ")
    if mnemonic in NOT_VECTOR or mnemonic in IMPLICIT_MASK:
        return []
    args = operands(rest)
    if not args:
        return []
    destination = args[-1]
    memory_destination = "(" in destination
    # Les déplacements vers la mémoire, et les deux opérandes dont la
    # destination est un registre général : rien à ajouter.
    if mnemonic in TWO_OPERANDS or memory_destination:
        return [f"v{mnemonic} {', '.join(args)}"]
    if mnemonic in {"movss", "movsd", "movlps", "movhps", "movlpd", "movhpd"}:
        # Chargés depuis la mémoire, movss et movsd n'ont que deux opérandes ;
        # entre registres, ils fusionnent avec `vvvv`. Les quatre autres
        # chargent toujours en fusionnant.
        if "(" in args[0] and mnemonic in {"movss", "movsd"}:
            return [f"v{mnemonic} {', '.join(args)}"]
    if mnemonic in IMMEDIATE_SHIFTS and len(args) == 2 and args[0].startswith("$"):
        return [f"v{mnemonic} {args[0]}, %xmm1, {destination}"]
    forms = [f"v{mnemonic} {', '.join(args[:-1] + ['%xmm2', destination])}"]
    # Les sources qui sont la destination, quand tout est registre.
    if destination == "%xmm0" and all("(" not in a for a in args):
        source = args[-2]
        if source.startswith("%xmm"):
            forms.append(f"v{mnemonic} {', '.join(args[:-2] + ['%xmm0', '%xmm2', destination])}")
            forms.append(f"v{mnemonic} {', '.join(args[:-2] + [source, '%xmm0', destination])}")
    return forms


def source_forms(fixtures):
    seen, out = set(), []
    for name in SOURCES:
        for line in (fixtures / name).read_text().splitlines():
            if not line.startswith("instr\t"):
                continue
            text = line.split("\t")[-1]
            for form in to_vex(text):
                if form not in seen:
                    seen.add(form)
                    out.append(form)
    return out


def assembles(text):
    with tempfile.TemporaryDirectory() as directory:
        source = Path(directory) / "one.s"
        source.write_text(f".text\n    {text}\n")
        return subprocess.run(["as", "--64", "-o", str(Path(directory) / "one.o"), str(source)],
                              capture_output=True).returncode == 0


def load_v2():
    spec = importlib.util.spec_from_file_location("v2", Path(__file__).parent / "build-x86-v2-oracle.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output")
    parser.add_argument("--oracle", default="scripts/x86-oracle/oracle")
    arguments = parser.parse_args()

    fixtures = Path(arguments.output).parent
    v2 = load_v2()
    candidates = source_forms(fixtures)
    texts = [text for text in candidates if assembles(text)]
    refused = [text for text in candidates if text not in texts]
    if refused:
        print(f"{len(refused)} formes que l'assembleur refuse : {refused[:8]}", file=sys.stderr)
    encoded = v2.assemble(texts)
    # Les états de x86-64-v2, avec xmm2 en plus : une valeur de la même
    # liste, décalée pour ne pas répéter xmm0 ni xmm1.
    chosen = []
    count = len(v2.VALUES)
    # Un état sur deux, et pas plus de quarante : douze cents formes fois
    # soixante-quinze états faisaient quatre-vingts secondes de test en
    # débogage, pour des formes que les corpus SSE couvrent déjà sur tous.
    for index, (general, vectors) in enumerate(list(v2.states())[::2][:40]):
        vectors = list(vectors)
        vectors[2] = v2.VALUES[(index * 5 + 2) % count]
        chosen.append((general, vectors))

    request, cases = [], []
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

    window = "".join(f"{0x10 + i:02x}" for i in range(64))
    with open(arguments.output, "w") as out:
        out.write("# Ce que le vrai processeur répond sur les formes VEX.128 de SSE.\n")
        out.write("# Voir scripts/build-x86-avx128-oracle.py.\n")
        out.write("# état\t<indice>\t<xmm0 bas>\t<xmm0 haut>\t<xmm1 bas>\t<xmm1 haut>\t<xmm2 bas>"
                  "\t<xmm2 haut>\t<rax>\t<rcx>\t<drapeaux>\t<rdx>\n")
        out.write("# instr\t<indice>\t<octets>\t<mnémonique>\n")
        out.write("# cas\t<instr>\t<état>\t<xmm0 bas>\t<xmm0 haut>\t<xmm1 bas>\t<xmm1 haut>\t<xmm2 bas>"
                  "\t<xmm2 haut>\t<rax>\t<rcx>\t<drapeaux>\t<fenêtre, ou - intacte>\t<rdx>\n")
        for index, (general, vectors) in enumerate(chosen):
            out.write("état\t%d\t%x\t%x\t%x\t%x\t%x\t%x\t%x\t%x\t%x\t%x\n"
                      % (index, *vectors[0], *vectors[1], *vectors[2],
                         general[0], general[1], general[16] & ARITHMETIC_FLAGS, general[2]))
        for index, (hexadecimal, text) in enumerate(zip(encoded, texts)):
            out.write("instr\t%d\t%s\t%s\n" % (index, hexadecimal, text))
        for (instruction, index, general, vectors), verdict in zip(cases, answer):
            fields = verdict.split("\t")
            after = [int(value, 16) for value in fields[50:99]]
            for register in [3] + list(range(8, 16)):
                if after[register] != general[register]:
                    raise SystemExit(f"{texts[instruction]} a écrit dans {REGISTERS[register]}")
            for vector in range(3, 16):
                if (after[17 + 2 * vector], after[18 + 2 * vector]) != vectors[vector]:
                    raise SystemExit(f"{texts[instruction]} a écrit dans xmm{vector}")
            memory = "-" if fields[99] == window else fields[99]
            out.write("cas\t%d\t%d\t%x\t%x\t%x\t%x\t%x\t%x\t%x\t%x\t%x\t%s\t%x\n"
                      % (instruction, index, after[17], after[18], after[19], after[20], after[21],
                         after[22], after[0], after[1], after[16] & ARITHMETIC_FLAGS, memory, after[2]))
    print(f"{len(encoded)} instructions, {len(cases)} cas", file=sys.stderr)


if __name__ == "__main__":
    main()
