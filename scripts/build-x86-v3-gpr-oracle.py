#!/usr/bin/env python3
"""Fabrique le verdict du **vrai processeur** sur la part de x86-64-v3 qui
n'emploie que les registres généraux : BMI1, BMI2, LZCNT, TZCNT, MOVBE et ADX.

    scripts/build-x86-v3-gpr-oracle.py Tests/Fixtures/x86-v3-gpr-oracle.tsv

**Pourquoi.** RHEL 10 et ses dérivés sont compilés pour x86-64-v3. Le noyau
de CentOS Stream 10 s'arrêtait ici à sa 13 441ᵉ instruction, sur `andn` :
il ne touche pas aux registres vectoriels, mais il emploie celles-ci sans
rien demander. Le processeur de ce conteneur les a (`bmi1 bmi2 abm movbe`
dans `/proc/cpuinfo`) ; c'est lui la référence.

**Les drapeaux comparés sont ceux que le manuel définit**, forme par forme
— le masque de chaque ligne `instr`. `AF` et `PF` sont indéfinis pour
toutes ; `SF` aussi pour `BEXTR`, `TZCNT` et `LZCNT`, `OF` pour ces deux
derniers. Les formes sans drapeaux (BMI2, sauf `BZHI`, et `MOVBE`) doivent
les laisser **tous** : leur masque est entier.

**Ce que le fichier porte.** RAX, RCX, RDX, les drapeaux et la fenêtre de
mémoire que RSI désigne. Tout le reste doit revenir intact, et ce script le
vérifie sur la machine avant d'écrire.
"""

import argparse
import re
import subprocess
import sys
import tempfile
from pathlib import Path

DATA = 0x30001000

CF, PF, AF, ZF, SF, OF = 1 << 0, 1 << 2, 1 << 4, 1 << 6, 1 << 7, 1 << 11
ALL = CF | PF | AF | ZF | SF | OF

REGISTERS = [
    "rax", "rcx", "rdx", "rbx", "rsp", "rbp", "rsi", "rdi",
    "r8", "r9", "r10", "r11", "r12", "r13", "r14", "r15",
]


def forms():
    """Les formes, avec le masque des drapeaux que le manuel définit."""
    out = []
    logic = ALL & ~(AF | PF)
    for width, (a, c, d) in [(64, ("%rax", "%rcx", "%rdx")), (32, ("%eax", "%ecx", "%edx"))]:
        mem = "0x28(%rsi)" if width == 64 else "0x24(%rsi)"
        # BMI1. `ANDN` : ¬vvvv ∧ r/m. `BLS*` : le bit à un le plus bas.
        out += [(f"andn {c}, {d}, {a}", logic), (f"andn {mem}, {d}, {a}", logic),
                (f"andn {a}, {a}, {a}", logic)]
        for name in ["blsi", "blsmsk", "blsr"]:
            out += [(f"{name} {c}, {a}", logic), (f"{name} {mem}, {a}", logic), (f"{name} {a}, {a}", logic)]
        # `BEXTR` : la commande dans vvvv, départ en bas, longueur au-dessus.
        out += [(f"bextr {c}, {d}, {a}", logic & ~SF), (f"bextr {c}, {mem}, {a}", logic & ~SF)]
        # BMI2. `BZHI` pose ses drapeaux ; les autres n'en touchent aucun.
        out += [(f"bzhi {c}, {d}, {a}", logic), (f"bzhi {c}, {mem}, {a}", logic)]
        for name in ["pdep", "pext"]:
            out += [(f"{name} {c}, {d}, {a}", ALL), (f"{name} {mem}, {d}, {a}", ALL)]
        for name in ["sarx", "shlx", "shrx"]:
            out += [(f"{name} {c}, {d}, {a}", ALL), (f"{name} {c}, {mem}, {a}", ALL)]
        # `MULX` : RDX fois r/m ; le bas dans vvvv, le haut dans reg — et le
        # haut seul quand les deux sont le même registre.
        out += [(f"mulx {c}, {a}, {c}", ALL), (f"mulx {c}, {c}, {a}", ALL), (f"mulx {c}, {a}, {a}", ALL),
                (f"mulx {mem}, {a}, {c}", ALL), (f"mulx {d}, {a}, {c}", ALL)]
        bits = width
        for count in [0, 1, 7, bits - 1, bits, bits + 3, 255]:
            out += [(f"rorx ${count}, {d}, {a}", ALL)]
        out += [(f"rorx $5, {mem}, {a}", ALL)]
    # LZCNT et TZCNT : CF dit la source nulle, ZF le résultat nul.
    count = CF | ZF
    for a, c in [("%rax", "%rcx"), ("%eax", "%ecx"), ("%ax", "%cx")]:
        for name in ["lzcnt", "tzcnt"]:
            out += [(f"{name} {c}, {a}", count), (f"{name} {a}, {a}", count)]
    for name, mem in [("lzcnt", "0x28(%rsi)"), ("tzcnt", "0x28(%rsi)"), ("lzcntl", "0x24(%rsi)"),
                      ("tzcntw", "0x22(%rsi)")]:
        out += [(f"{name} {mem}, %eax" if name.endswith("l") else
                 f"{name} {mem}, %ax" if name.endswith("w") else f"{name} {mem}, %rax", count)]
    # MOVBE : les octets retournés, à l'aller comme au retour.
    for reg, mem in [("%rax", "0x28(%rsi)"), ("%eax", "0x24(%rsi)"), ("%ax", "0x22(%rsi)"),
                     ("%rcx", "0x29(%rsi)")]:
        out += [(f"movbe {mem}, {reg}", ALL), (f"movbe {reg}, {mem}", ALL)]
    # ADX. `ADCX` additionne avec CF et ne pose que CF ; `ADOX` fait de
    # même avec OF. Les deux chaînes de retenues d'OpenSSL passent l'une à
    # côté de l'autre : chacune doit laisser intact le drapeau de l'autre,
    # et le masque entier le vérifie.
    for a, c, mem in [("%rax", "%rcx", "0x28(%rsi)"), ("%eax", "%ecx", "0x24(%rsi)")]:
        for name in ["adcx", "adox"]:
            out += [(f"{name} {c}, {a}", ALL), (f"{name} {mem}, {a}", ALL), (f"{name} {a}, {a}", ALL)]
    return out


# Des valeurs pour les bits : nulles, tout à un, un seul bit à chaque bout,
# des motifs, et des commandes de `BEXTR` (départ, longueur) et des rangs de
# `BZHI` aux bords — 0, 31, 32, 63, 64, 255.
VALUES = [
    0x0000000000000000,
    0xFFFFFFFFFFFFFFFF,
    0x0000000000000001,
    0x8000000000000000,
    0x0000000080000000,
    0x0123456789ABCDEF,
    0xF0F0F0F0F0F0F0F0,
    0x5555555555555555,
    0x00000000FFFF0000,
    0x0000000000000804,
    0x0000000000002010,
    0x0000000000004000,
    0x000000000000FF00,
    0x0000000000000820,
    0x000000000000001F,
    0x0000000000000020,
    0x000000000000003F,
    0x0000000000000040,
    0x00000000000000FF,
    0xDEADBEEFCAFEF00D,
    0x7FFFFFFFFFFFFFFF,
    0x0000000000010000,
]

IN_FLAGS = [0x002, 0x8D7]
# CF seul, puis OF seul.
ONE_CARRY_FLAGS = [0x003, 0x802]


def states():
    """Des triplets (RAX, RCX, RDX) qui font se croiser les valeurs."""
    fixed = [0xAAAAAAAAAAAAAAAA + i for i in range(16)]
    count = len(VALUES)
    triples = [(i, (i * 5 + 3) % count, (i * 7 + 1) % count) for i in range(count)]
    triples += [((i * 3) % count, i, (count - 1 - i)) for i in range(count)]
    triples += [(i, i, i) for i in range(count)]
    for index, (a, c, d) in enumerate(triples):
        general = list(fixed)
        general[0], general[1], general[2] = VALUES[a], VALUES[c], VALUES[d]
        general[6] = DATA
        yield general + [IN_FLAGS[index % len(IN_FLAGS)]]
    # CF et OF séparés : sans eux, `ADCX` qui lirait OF, ou `ADOX` qui
    # lirait CF, passerait, puisque les deux entrent ensemble plus haut.
    for index in range(count):
        general = list(fixed)
        general[0], general[1], general[2] = VALUES[index], VALUES[(index * 5 + 3) % count], VALUES[index]
        general[6] = DATA
        yield general + [ONE_CARRY_FLAGS[index % len(ONE_CARRY_FLAGS)]]


def assemble(texts):
    with tempfile.TemporaryDirectory() as directory:
        source = Path(directory) / "cases.s"
        obj = Path(directory) / "cases.o"
        with open(source, "w") as out:
            out.write(".text\n")
            for text in texts:
                out.write(f"    {text}\n")
        subprocess.run(["as", "--64", "-o", str(obj), str(source)], check=True)
        listing = subprocess.run(["objdump", "-d", "--insn-width=15", str(obj)],
                                 capture_output=True, text=True, check=True).stdout
    line = re.compile(r"^\s*[0-9a-f]+:\t([0-9a-f]{2}(?: [0-9a-f]{2})*) *\t(.*)$")
    encoded = ["".join(match.group(1).split()) for row in listing.splitlines()
               if (match := line.match(row))]
    if len(encoded) != len(texts):
        raise SystemExit(f"{len(texts)} instructions demandées, {len(encoded)} relues")
    return encoded


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output")
    parser.add_argument("--oracle", default="scripts/x86-oracle/oracle")
    arguments = parser.parse_args()

    chosen_forms = forms()
    texts = [text for text, _ in chosen_forms]
    encoded = assemble(texts)
    chosen = list(states())

    request, cases = [], []
    for instruction, hexadecimal in enumerate(encoded):
        for index, general in enumerate(chosen):
            request.append(hexadecimal + "\t" + "\t".join(f"{v:x}" for v in general))
            cases.append((instruction, index, general))
    answer = subprocess.run([arguments.oracle], input="\n".join(request) + "\n",
                            capture_output=True, text=True, check=True).stdout.splitlines()
    if len(answer) != len(cases):
        raise SystemExit(f"{len(cases)} cas envoyés, {len(answer)} verdicts reçus")

    window = None
    with open(arguments.output, "w") as out:
        out.write("# Ce que le vrai processeur répond sur BMI1, BMI2, LZCNT, TZCNT, MOVBE et ADX.\n")
        out.write("# Voir scripts/build-x86-v3-gpr-oracle.py.\n")
        out.write("# état\t<indice>\t<rax>\t<rcx>\t<rdx>\t<drapeaux>\n")
        out.write("# instr\t<indice>\t<octets>\t<masque des drapeaux définis>\t<mnémonique>\n")
        out.write("# cas\t<instr>\t<état>\t<rax>\t<rcx>\t<rdx>\t<drapeaux>\t<fenêtre, ou - intacte>\n")
        out.write("#   RSI pointe la fenêtre de 64 octets à 0x30001000 ; elle part\n")
        out.write("#   des octets 0x10, 0x11… Les drapeaux sont réduits au masque de l'instruction.\n")
        for index, general in enumerate(chosen):
            out.write("état\t%d\t%x\t%x\t%x\t%x\n"
                      % (index, general[0], general[1], general[2], general[16] & ALL))
        for index, ((text, mask), hexadecimal) in enumerate(zip(chosen_forms, encoded)):
            out.write("instr\t%d\t%s\t%x\t%s\n" % (index, hexadecimal, mask, text))
        for (instruction, index, general), verdict in zip(cases, answer):
            fields = verdict.split("\t")
            after = [int(value, 16) for value in fields[18:35]]
            for register in [3] + list(range(5, 16)):
                if after[register] != general[register]:
                    raise SystemExit(f"{texts[instruction]} a écrit dans {REGISTERS[register]}")
            if window is None:
                window = "".join(f"{0x10 + i:02x}" for i in range(len(fields[35]) // 2))
            memory = "-" if fields[35] == window else fields[35]
            mask = chosen_forms[instruction][1]
            out.write("cas\t%d\t%d\t%x\t%x\t%x\t%x\t%s\n"
                      % (instruction, index, after[0], after[1], after[2], after[16] & mask, memory))
    print(f"{len(encoded)} instructions, {len(cases)} cas", file=sys.stderr)


if __name__ == "__main__":
    main()
