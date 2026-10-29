#!/usr/bin/env python3
"""Fabrique le verdict du **vrai processeur** sur les formes VEX qui
traversent les moitiés d'un YMM : diffusions, insertions et extractions de
128 bits, permutations, mélanges par un masque, décalages par élément,
élargissements sur 256 bits.

    scripts/build-x86-avx2-oracle.py Tests/Fixtures/x86-avx2-oracle.tsv

**Pourquoi.** Elles n'ont pas de forme SSE : le cœur les écrit directement
(`Sources/WisqVM/X86AVX2.swift`), et c'est le processeur qui dit si c'est
juste. Le code compilé pour x86-64-v3 les emploie dès qu'il vectorise une
boucle — `vpbroadcastd` pour une constante, `vinserti128` et `vextracti128`
pour passer d'une moitié à l'autre, `vpermq` pour réordonner.

**Les formes sont écrites ici**, chacune sous plusieurs immédiats et en
mémoire, parce qu'aucun corpus SSE ne les contient. Les états, les colonnes
et les vérifications sont ceux de `build-x86-avx256-oracle.py`, dont ce
script reprend le juge.
"""

import argparse
import importlib.util
import sys
from pathlib import Path


def load(name):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).parent / f"build-x86-{name}-oracle.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def forms():
    out = []
    for size in ["xmm", "ymm"]:
        # Les diffusions, depuis un registre et depuis la mémoire.
        for name, memory in [("vpbroadcastb", "0x3(%rsi)"), ("vpbroadcastw", "0x6(%rsi)"),
                             ("vpbroadcastd", "0x8(%rsi)"), ("vpbroadcastq", "0x10(%rsi)"),
                             ("vbroadcastss", "0x4(%rsi)")]:
            out += [f"{name} %xmm1, %{size}0", f"{name} {memory}, %{size}0", f"{name} %xmm0, %{size}0"]
        # Les permutations dans chaque moitié.
        for immediate in [0x1B, 0xE4, 0x4E, 0x00, 0xB1]:
            out += [f"vpermilps ${immediate:#x}, %{size}1, %{size}0", f"vpermilps ${immediate:#x}, (%rsi), %{size}0"]
        for immediate in [0x0, 0x5, 0xA, 0x3, 0xF]:
            out += [f"vpermilpd ${immediate:#x}, %{size}1, %{size}0"]
        out += [f"vpermilps %{size}1, %{size}2, %{size}0", f"vpermilps (%rsi), %{size}2, %{size}0",
                f"vpermilpd %{size}1, %{size}2, %{size}0", f"vpermilpd %{size}0, %{size}2, %{size}0"]
        # `vpblendd`, et les mélanges par un masque.
        for immediate in [0x00, 0xFF, 0x5A, 0xC3, 0x81]:
            out += [f"vpblendd ${immediate:#x}, %{size}1, %{size}2, %{size}0",
                    f"vpblendd ${immediate:#x}, 0x8(%rsi), %{size}2, %{size}0"]
        for name in ["vblendvps", "vblendvpd", "vpblendvb"]:
            out += [f"{name} %{size}1, %{size}2, %{size}0, %{size}0", f"{name} %{size}0, %{size}1, %{size}2, %{size}0",
                    f"{name} %{size}2, (%rsi), %{size}1, %{size}0"]
        # Les décalages par élément.
        for name in ["vpsllvd", "vpsllvq", "vpsrlvd", "vpsrlvq", "vpsravd"]:
            out += [f"{name} %{size}1, %{size}2, %{size}0", f"{name} %{size}2, %{size}1, %{size}0",
                    f"{name} 0x8(%rsi), %{size}2, %{size}0", f"{name} %{size}0, %{size}0, %{size}0"]
    # Ce qui n'a que 256 bits.
    out += ["vbroadcastsd %xmm1, %ymm0", "vbroadcastsd 0x8(%rsi), %ymm0",
            "vbroadcasti128 0x10(%rsi), %ymm0", "vbroadcastf128 (%rsi), %ymm0"]
    for immediate in [0, 1]:
        for name in ["vinserti128", "vinsertf128"]:
            out += [f"{name} ${immediate}, %xmm1, %ymm2, %ymm0", f"{name} ${immediate}, 0x8(%rsi), %ymm2, %ymm0",
                    f"{name} ${immediate}, %xmm0, %ymm0, %ymm0"]
        for name in ["vextracti128", "vextractf128"]:
            out += [f"{name} ${immediate}, %ymm1, %xmm0", f"{name} ${immediate}, %ymm0, %xmm0",
                    f"{name} ${immediate}, %ymm2, 0x8(%rsi)"]
    for immediate in [0x20, 0x31, 0x01, 0x13, 0x88, 0x08, 0x80, 0x02, 0x30]:
        for name in ["vperm2i128", "vperm2f128"]:
            out += [f"{name} ${immediate:#x}, %ymm1, %ymm2, %ymm0"]
    out += ["vperm2i128 $0x21, (%rsi), %ymm2, %ymm0", "vperm2i128 $0x03, %ymm0, %ymm1, %ymm0"]
    for immediate in [0x1B, 0xE4, 0x4E, 0x00, 0xD8, 0x93]:
        out += [f"vpermq ${immediate:#x}, %ymm1, %ymm0", f"vpermpd ${immediate:#x}, %ymm0, %ymm0"]
    out += ["vpermq $0x39, (%rsi), %ymm0"]
    for name in ["vpermd", "vpermps"]:
        out += [f"{name} %ymm1, %ymm2, %ymm0", f"{name} %ymm2, %ymm1, %ymm0", f"{name} (%rsi), %ymm2, %ymm0",
                f"{name} %ymm0, %ymm0, %ymm0"]
    for kind in ["sx", "zx"]:
        for widen in ["bw", "bd", "bq", "wd", "wq", "dq"]:
            out += [f"vpmov{kind}{widen} %xmm1, %ymm0", f"vpmov{kind}{widen} %xmm0, %ymm0",
                    f"vpmov{kind}{widen} 0x8(%rsi), %ymm0"]
    return out


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output")
    parser.add_argument("--oracle", default="scripts/x86-oracle/oracle")
    arguments = parser.parse_args()
    avx128 = load("avx128")
    avx256 = load("avx256")
    candidates = forms()
    texts = [text for text in candidates if avx128.assembles(text)]
    refused = [text for text in candidates if text not in texts]
    if refused:
        raise SystemExit(f"{len(refused)} formes que l'assembleur refuse : {refused[:8]}")
    print(f"{len(texts)} formes", file=sys.stderr)
    avx256.judge(texts, arguments.output, arguments.oracle,
                 "Ce que le vrai processeur répond sur les formes VEX qui traversent les moitiés d'un YMM.",
                 "scripts/build-x86-avx2-oracle.py")


if __name__ == "__main__":
    main()
