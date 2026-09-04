#!/usr/bin/env python3
"""Ce que le vrai processeur fait d'une zone FXSAVE.

Chaque cas donne une image de 512 octets ; le processeur la charge avec
`FXRSTOR` puis la réécrit avec `FXSAVE`. L'aller-retour fixe deux choses que
ce cœur ne pouvait pas deviner :

  * **où** chaque champ vit — et surtout que les huit registres x87 sont rangés
    dans l'ordre de la **pile** (ST(0) d'abord) alors que le mot d'étiquettes
    abrégé est dans l'ordre **physique** ;
  * **ce que le processeur reconstruit** de ce que le format abrège : ce mot n'a
    qu'un bit par registre là où l'état en tient deux.

Les octets 5 à 23 — l'octet réservé, FOP, FIP et FDP — sont mis à zéro dans
l'entrée **exprès**. Ce cœur ne tient pas le pointeur d'instruction de la
virgule flottante, et un corpus qui l'exigerait ne mesurerait qu'un manque déjà
connu au lieu de tenir ce qui est là.

Usage : python3 scripts/build-x86-fxsave-oracle.py > Tests/Fixtures/x86-fxsave-oracle.tsv
"""
import random
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
AREA = 512


def image(control, status, abridged, mxcsr, stack, vectors):
    a = bytearray(AREA)
    a[0:2] = struct.pack('<H', control)
    a[2:4] = struct.pack('<H', status)
    a[4] = abridged
    a[24:28] = struct.pack('<I', mxcsr)
    a[28:32] = struct.pack('<I', 0xFFFF)
    for i, (significand, sign_exponent) in enumerate(stack):
        a[32 + 16 * i:32 + 16 * i + 8] = struct.pack('<Q', significand)
        a[32 + 16 * i + 8:32 + 16 * i + 10] = struct.pack('<H', sign_exponent)
    for i, (low, high) in enumerate(vectors):
        a[160 + 16 * i:160 + 16 * i + 8] = struct.pack('<Q', low)
        a[160 + 16 * i + 8:160 + 16 * i + 16] = struct.pack('<Q', high)
    return a


NOTABLE = [
    (0x0000_0000_0000_0000, 0x0000),  # zéro
    (0x0000_0000_0000_0000, 0x8000),  # zéro négatif
    (0x8000_0000_0000_0000, 0x3FFF),  # un
    (0x8000_0000_0000_0000, 0x7FFF),  # infini
    (0xC000_0000_0000_0000, 0x7FFF),  # NaN silencieux
    (0x8000_0000_0000_0001, 0x7FFF),  # NaN signalant
    (0x0000_0000_0000_0001, 0x0000),  # dénormal
    (0x4000_0000_0000_0000, 0x4001),  # non normalisé : bit de tête absent
]


def cases():
    random.seed(0x5A5E)
    # Les huit valeurs remarquables, chacune seule au sommet.
    for value in NOTABLE:
        yield image(0x037F, 0, 0b0000_0001, 0x1F80,
                    [value] + [(0, 0)] * 7, [(0, 0)] * 16)
    # Chaque sommet possible, avec toutes les étiquettes possibles autour.
    for top in range(8):
        for abridged in (0x00, 0x01, 0x0F, 0xFF, 1 << top, ~(1 << top) & 0xFF):
            yield image(0x037F, top << 11, abridged, 0x1F80,
                        [NOTABLE[i] for i in range(8)],
                        [(0x1111 * i, 0x2222 * i) for i in range(16)])
    # Les quatre modes d'arrondi et les masques d'exception.
    for control in (0x037F, 0x077F, 0x0B7F, 0x0F7F, 0x0300, 0x1F3F):
        for mxcsr in (0x1F80, 0x9FC0, 0x0000, 0x7F80):
            yield image(control, 0, 0xFF, mxcsr,
                        [NOTABLE[i] for i in range(8)],
                        [(0xDEAD_BEEF_0000 + i, 0xFACE_0000 + i) for i in range(16)])
    # Et du hasard, parce qu'un corpus choisi ne surprend jamais.
    for _ in range(200):
        yield image(random.getrandbits(16) & 0x1F3F,
                    (random.getrandbits(3) << 11) | random.getrandbits(8),
                    random.getrandbits(8),
                    random.getrandbits(16),
                    [(random.getrandbits(64), random.getrandbits(16))
                     for _ in range(8)],
                    [(random.getrandbits(64), random.getrandbits(64))
                     for _ in range(16)])


def main():
    inputs = [bytes(case) for case in cases()]
    with tempfile.TemporaryDirectory() as work:
        binary = Path(work) / 'fxsave-oracle'
        subprocess.run(['gcc', '-O1', '-o', str(binary), str(HERE / 'x86-fxsave' / 'oracle.c')],
                       check=True)
        fed = ''.join(case.hex() + '\n' for case in inputs)
        done = subprocess.run([str(binary)], input=fed, capture_output=True,
                              text=True, check=True)
    outputs = done.stdout.split()
    if len(outputs) != len(inputs):
        sys.exit(f"{len(inputs)} cas envoyés, {len(outputs)} rendus")

    print("# Ce que le vrai processeur fait d'une zone FXSAVE.")
    print("# Voir scripts/build-x86-fxsave-oracle.py.")
    print("#")
    print("#   Chaque cas : une image de 512 octets chargée par FXRSTOR, puis")
    print("#   réécrite par FXSAVE. Seuls les 416 premiers octets sont comparés :")
    print("#   FXSAVE ne touche pas les quatre-vingt-seize derniers, et c'est")
    print("#   mesuré — une zone remplie de 0xCC les retrouve intacts.")
    print("#")
    print("# cas\t<entrée, 512 octets>\t<sortie, 416 octets>")
    for index, (before, after) in enumerate(zip(inputs, outputs)):
        print(f"cas\t{index}\t{before.hex()}\t{after[:416 * 2]}")


if __name__ == '__main__':
    main()
