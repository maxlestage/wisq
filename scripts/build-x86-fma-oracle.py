#!/usr/bin/env python3
"""Fabrique le verdict du **vrai processeur** sur FMA, F16C et les
conversions qui changent de largeur sur 256 bits.

    scripts/build-x86-fma-oracle.py Tests/Fixtures/x86-fma-oracle.tsv

**Pourquoi.** La glibc de RHEL 10 exige FMA et F16C avec AVX2 avant de
démarrer quoi que ce soit, et le code compilé pour x86-64-v3 emploie FMA
dans la moindre boucle flottante. Un `a × b + c` fusionné n'arrondit qu'une
fois : le seul moyen de savoir si le cœur arrondit comme le processeur est
de le lui demander, sur des états qui mêlent NaN, infinis, zéros signés et
sous-normales — ceux du corpus x86-64-v2, que reprend le juge du corpus
VEX.256.

**Les formes sont écrites ici** : les quatre familles de FMA dans leurs
trois ordres, empaquetées sur 128 et 256 bits et scalaires, `fmaddsub` et
`fmsubadd`, chacune entre registres, avec la destination pour source, et
depuis la mémoire ; `vcvtph2ps` et `vcvtps2ph` sous les huit immédiats
d'arrondi ; les cinq conversions de largeur sur 256 bits.
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
    for family in ["fmadd", "fmsub", "fnmadd", "fnmsub", "fmaddsub", "fmsubadd"]:
        for order in ["132", "213", "231"]:
            for kind in ["ps", "pd"]:
                name = f"v{family}{order}{kind}"
                for size in ["xmm", "ymm"]:
                    out += [f"{name} %{size}1, %{size}2, %{size}0", f"{name} %{size}0, %{size}0, %{size}0",
                            f"{name} %{size}2, %{size}0, %{size}1", f"{name} (%rsi), %{size}2, %{size}0"]
            if family in ("fmaddsub", "fmsubadd"):
                continue
            for kind, memory in [("ss", "0x4(%rsi)"), ("sd", "0x8(%rsi)")]:
                name = f"v{family}{order}{kind}"
                out += [f"{name} %xmm1, %xmm2, %xmm0", f"{name} %xmm0, %xmm2, %xmm0", f"{name} {memory}, %xmm2, %xmm0"]
    for size in ["xmm", "ymm"]:
        out += [f"vcvtph2ps %xmm1, %{size}0", f"vcvtph2ps %xmm0, %{size}0", f"vcvtph2ps (%rsi), %{size}0"]
        for immediate in range(8):
            out += [f"vcvtps2ph ${immediate}, %{size}1, %xmm0", f"vcvtps2ph ${immediate}, %{size}0, %xmm0"]
        out += [f"vcvtps2ph $0, %{size}2, 0x8(%rsi)"]
    out += ["vcvtps2pd %xmm1, %ymm0", "vcvtps2pd %xmm0, %ymm0", "vcvtps2pd (%rsi), %ymm0",
            "vcvtdq2pd %xmm1, %ymm0", "vcvtdq2pd 0x8(%rsi), %ymm0",
            "vcvtpd2ps %ymm1, %xmm0", "vcvtpd2ps %ymm0, %xmm0", "vcvtpd2psy (%rsi), %xmm0",
            "vcvttpd2dq %ymm1, %xmm0", "vcvttpd2dqy 0x8(%rsi), %xmm0",
            "vcvtpd2dq %ymm1, %xmm0", "vcvtpd2dq %ymm2, %xmm0", "vcvtpd2dqy (%rsi), %xmm0"]
    return out


def edge_states():
    """Des simples aux bords de la demi-précision : les égalités d'arrondi
    (un bit de garde, avec ou sans bits collants), les sous-normales et leur
    seuil, le plus grand fini et ce qui déborde, sous les deux signes — et
    les mêmes passés aux FMA, qui y trouvent des produits exacts et des
    annulations."""
    values = [
        0x3F800000, 0x3F801000, 0x3F802000, 0x3F803000, 0x3F801001, 0x3F800FFF,  # 1, 1 + égalités
        0x477FE000, 0x477FEFFF, 0x477FF000, 0x477FF001, 0x47800000, 0x7F7FFFFF,  # 65 504 et au-delà
        0x38800000, 0x387FC000, 0x33800000, 0x33000000, 0x33000001, 0x337FFFFF,  # 2⁻¹⁴, sous-normales
        0x00000001, 0x007FFFFF, 0x2F800000, 0x38000000, 0x3E2AAAAB, 0x40490FDB,  # très petits, ⅙, π
        0x7F800000, 0x7FC00000, 0x7F800001, 0x7FBFFFFF, 0x00000000, 0x3FFFFFFF,
        0x46FFFE00, 0x46FFFF00, 0x477FDFFF, 0x387FE000, 0x38FFF000, 0x3A800800,
    ]
    signed = values + [v | 0x80000000 for v in values]
    states = []
    for start in range(0, len(signed), 8):
        chunk = (signed + signed)[start:start + 24]
        words = [chunk[2 * i] | chunk[2 * i + 1] << 32 for i in range(12)]
        states.append(words)
    return states


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
                 "Ce que le vrai processeur répond sur FMA, F16C et les conversions de largeur sur 256 bits.",
                 "scripts/build-x86-fma-oracle.py", extra=edge_states())


if __name__ == "__main__":
    main()
