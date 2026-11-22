#!/usr/bin/env python3
"""Le témoin du cœur ARM64 : des programmes A64 tirés au hasard, exécutés par
`qemu-aarch64`, et ce qu'ils écrivent gardé comme fixture.

    scripts/arm64-oracle.py            # récrit crates/wisq-vm/tests/arm64/

Il faut `aarch64-linux-gnu-as`, `aarch64-linux-gnu-ld`, `aarch64-linux-gnu-objcopy`
et `qemu-aarch64` (Debian, Ubuntu : `binutils-aarch64-linux-gnu qemu-user`). La
CI n'en a pas besoin : elle relit les fixtures, et `tests/arm64.rs` exige que le
cœur de wisq écrive les mêmes octets que qemu.

Chaque programme pose des valeurs au hasard dans x0 à x25 et dans NZCV, puis
enchaîne des blocs d'instructions tirées dans toutes les familles que le cœur
sait exécuter. Après chaque bloc, il écrit sur la sortie standard ses
registres, NZCV et la zone de mémoire qu'il a touchée. x26 sert d'index borné,
x27 de pointeur mobile dans la zone, x28 de base : le hasard ne les vise
jamais, pour que chaque accès reste dans la zone.

Le tirage est fixé par une graine : relancer le script redonne les mêmes
fichiers, et un changement de fixture se lit dans le diff.
"""

import os
import random
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "crates", "wisq-vm", "tests", "arm64")
BASE = 0x400000
# La zone de mémoire du programme, dans sa section `.data` : un ELF dont le
# texte est inscriptible ne se charge pas sous qemu (`-N` désaligne le segment).
DATA = 0x420000
PROGRAMS = 8
BLOCKS = 12
BLOCK = 64
SCRATCH = 1024
CONDS = ["eq", "ne", "cs", "cc", "mi", "pl", "vs", "vc", "hi", "ls", "ge", "lt", "gt", "le", "al"]


def reg(r, wide):
    return f"{'x' if wide else 'w'}{r}"


def any_reg(rng):
    return rng.randrange(0, 26)


def bitmask_immediate(rng, wide):
    """Une valeur que l'encodage logique immédiat peut porter."""
    size = rng.choice([2, 4, 8, 16, 32, 64] if wide else [2, 4, 8, 16, 32])
    run = rng.randrange(1, size)
    element = (1 << run) - 1
    rotation = rng.randrange(0, size)
    element = ((element >> rotation) | (element << (size - rotation))) & ((1 << size) - 1)
    total = 64 if wide else 32
    value = 0
    for at in range(0, total, size):
        value |= element << at
    return value


def instruction(rng, labels):
    """Une instruction (ou un court groupe) au hasard."""
    wide = rng.random() < 0.6
    d, n, m, a = (any_reg(rng) for _ in range(4))
    R = lambda r: reg(r, wide)  # noqa: E731
    top = 63 if wide else 31
    kind = rng.randrange(0, 23)
    if kind == 22:
        # Les drapeaux d'une opération, lus aussitôt : sans ça, un V faux
        # ne se voit que s'il survit jusqu'à la fin du bloc.
        op = rng.choice(["adds", "subs", "adcs", "sbcs", "ands", "bics"])
        if op in ("adds", "subs") and rng.random() < 0.5:
            first = [f"{op} {R(d)}, {R(n)}, #{rng.randrange(0, 4096)}"]
        else:
            first = [f"{op} {R(d)}, {R(n)}, {R(m)}"]
        # Des opérandes aux bornes : au hasard, les valeurs dérivent vers ce
        # qui ne déborde jamais (une écriture W remet le haut à zéro), et V
        # n'était posé que quatorze fois sur six mille instructions.
        def edge():
            size = 64 if wide else 32
            top = 1 << (size - 1)
            pick = rng.choice([top - 1, top, (1 << size) - 1, 0, 1, top - 2, top + 1,
                               rng.getrandbits(size)])
            return pick & ((1 << size) - 1)
        setup = []
        for r in (n, m):
            value = edge()
            setup.append(f"movz x{r}, #{value & 0xffff}")
            for hw in (1, 2, 3):
                setup.append(f"movk x{r}, #{(value >> (16 * hw)) & 0xffff}, lsl #{16 * hw}")
        carry = [f"msr nzcv, x{a}"] if rng.random() < 0.5 else []
        return setup + carry + first + [f"mrs x{a}, nzcv", f"str x{a}, [x28, #{rng.randrange(0, SCRATCH // 8) * 8}]"]
    if kind == 0:
        op = rng.choice(["add", "adds", "sub", "subs"])
        shift = ", lsl #12" if rng.random() < 0.3 else ""
        return [f"{op} {R(d)}, {R(n)}, #{rng.randrange(0, 4096)}{shift}"]
    if kind == 1:
        op = rng.choice(["and", "orr", "eor", "ands"])
        return [f"{op} {R(d)}, {R(n)}, #{bitmask_immediate(rng, wide):#x}"]
    if kind == 2:
        op = rng.choice(["movz", "movn", "movk"])
        hw = rng.randrange(0, 4 if wide else 2) * 16
        return [f"{op} {R(d)}, #{rng.randrange(0, 65536)}, lsl #{hw}"]
    if kind == 3:
        op = rng.choice(["sbfm", "bfm", "ubfm"])
        return [f"{op} {R(d)}, {R(n)}, #{rng.randrange(0, top + 1)}, #{rng.randrange(0, top + 1)}"]
    if kind == 4:
        return [f"extr {R(d)}, {R(n)}, {R(m)}, #{rng.randrange(0, top + 1)}"]
    if kind == 5:
        op = rng.choice(["add", "adds", "sub", "subs"])
        shift = rng.choice(["lsl", "lsr", "asr"])
        return [f"{op} {R(d)}, {R(n)}, {R(m)}, {shift} #{rng.randrange(0, top + 1)}"]
    if kind == 6:
        op = rng.choice(["add", "adds", "sub", "subs"])
        ext = rng.choice(["uxtb", "uxth", "uxtw", "uxtx", "sxtb", "sxth", "sxtw", "sxtx"])
        source = reg(m, ext.endswith("x")) if wide else reg(m, False)
        if not wide and ext.endswith("x"):
            ext = ext[:-1] + "w"
        return [f"{op} {R(d)}, {R(n)}, {source}, {ext} #{rng.randrange(0, 5)}"]
    if kind == 7:
        op = rng.choice(["and", "bic", "orr", "orn", "eor", "eon", "ands", "bics"])
        shift = rng.choice(["lsl", "lsr", "asr", "ror"])
        return [f"{op} {R(d)}, {R(n)}, {R(m)}, {shift} #{rng.randrange(0, top + 1)}"]
    if kind == 8:
        op = rng.choice(["adc", "adcs", "sbc", "sbcs"])
        return [f"{op} {R(d)}, {R(n)}, {R(m)}"]
    if kind == 9:
        op = rng.choice(["ccmp", "ccmn"])
        other = f"#{rng.randrange(0, 32)}" if rng.random() < 0.5 else R(m)
        return [f"{op} {R(n)}, {other}, #{rng.randrange(0, 16)}, {rng.choice(CONDS)}"]
    if kind == 10:
        op = rng.choice(["csel", "csinc", "csinv", "csneg"])
        return [f"{op} {R(d)}, {R(n)}, {R(m)}, {rng.choice(CONDS)}"]
    if kind == 11:
        op = rng.choice(["udiv", "sdiv", "lslv", "lsrv", "asrv", "rorv"])
        return [f"{op} {R(d)}, {R(n)}, {R(m)}"]
    if kind == 12:
        ops = ["rbit", "rev16", "rev", "clz", "cls"] + (["rev32"] if wide else [])
        return [f"{rng.choice(ops)} {R(d)}, {R(n)}"]
    if kind == 13:
        if wide and rng.random() < 0.5:
            op = rng.choice(["smaddl", "smsubl", "umaddl", "umsubl"])
            return [f"{op} x{d}, w{n}, w{m}, x{a}"]
        if wide and rng.random() < 0.5:
            return [f"{rng.choice(['smulh', 'umulh'])} x{d}, x{n}, x{m}"]
        return [f"{rng.choice(['madd', 'msub'])} {R(d)}, {R(n)}, {R(m)}, {R(a)}"]
    if kind == 14:
        # Chargement ou rangement, décalage non signé depuis x28.
        size, op, target = rng.choice([
            (8, "ldr", "x"), (8, "str", "x"), (4, "ldr", "w"), (4, "str", "w"),
            (4, "ldrsw", "x"), (2, "ldrh", "w"), (2, "strh", "w"), (2, "ldrsh", "w"),
            (2, "ldrsh", "x"), (1, "ldrb", "w"), (1, "strb", "w"), (1, "ldrsb", "w"),
            (1, "ldrsb", "x"),
        ])
        offset = rng.randrange(0, SCRATCH // size) * size
        return [f"{op} {target}{d}, [x28, #{offset}]"]
    if kind == 15:
        # Non mis à l'échelle, pré- et post-indexé, depuis x27.
        op, target = rng.choice([("ldr", "x"), ("str", "x"), ("ldr", "w"), ("str", "w"),
                                 ("ldrb", "w"), ("strb", "w"), ("ldrsh", "x"), ("strh", "w")])
        offset = rng.randrange(-256, 256) & ~7
        form = rng.randrange(0, 3)
        reset = f"add x27, x28, #{SCRATCH // 2}"
        if form == 0:
            unscaled = op.replace("ldr", "ldur").replace("str", "stur")
            return [reset, f"{unscaled} {target}{d}, [x27, #{offset}]"]
        if form == 1:
            return [reset, f"{op} {target}{d}, [x27, #{offset}]!"]
        return [reset, f"{op} {target}{d}, [x27], #{offset}"]
    if kind == 16:
        # Registre d'index, borné par x26.
        size, op, target = rng.choice([(8, "ldr", "x"), (8, "str", "x"), (4, "ldr", "w"),
                                       (2, "ldrh", "w"), (1, "strb", "w")])
        shift = {8: 3, 4: 2, 2: 1, 1: 0}[size]
        scaled = f", lsl #{shift}" if rng.random() < 0.5 and shift else ""
        return [f"and x26, x{n}, #0x7f", f"{op} {target}{d}, [x28, x26{scaled}]"]
    if kind == 17:
        # Paires.
        op, target, size = rng.choice([("ldp", "x", 8), ("stp", "x", 8), ("ldp", "w", 4),
                                       ("stp", "w", 4), ("ldpsw", "x", 4)])
        e = (d + 1 + rng.randrange(0, 24)) % 26
        offset = rng.randrange(-32, 32) * size
        form = rng.randrange(0, 3)
        reset = f"add x27, x28, #{SCRATCH // 2}"
        if form == 0:
            return [reset, f"{op} {target}{d}, {target}{e}, [x27, #{offset}]"]
        if form == 1:
            return [reset, f"{op} {target}{d}, {target}{e}, [x27, #{offset}]!"]
        return [reset, f"{op} {target}{d}, {target}{e}, [x27], #{offset}"]
    if kind == 18:
        # Accès exclusifs et ordonnés.
        status = (d + 1) % 26
        value = (d + 2) % 26
        offset = rng.randrange(0, SCRATCH // 16) * 16
        # Un `STXR` réussit après un `LDXR` à la même adresse, et échoue
        # après `CLREX`, à une autre adresse, ou sans `LDXR` devant.
        case = rng.randrange(0, 4)
        load = [f"ldaxr x{d}, [x27]"] if case != 3 else []
        between = ["clrex"] if case == 1 else []
        target = "x27" if case != 2 else "x26"
        return [f"add x27, x28, #{offset}", f"add x26, x27, #16", *load, *between,
                f"stlxr w{status}, x{value}, [{target}]", f"ldar w{value}, [x27]", f"stlr x{d}, [x27]"]
    if kind == 19:
        # Saut conditionnel par-dessus une instruction.
        label = labels.pop()
        test = rng.randrange(0, 4)
        if test == 0:
            jump = f"b.{rng.choice(CONDS[:-1])} {label}f"
        elif test == 1:
            jump = f"{rng.choice(['cbz', 'cbnz'])} {R(n)}, {label}f"
        else:
            jump = f"{rng.choice(['tbz', 'tbnz'])} x{n}, #{rng.randrange(0, 64)}, {label}f"
        return [jump, f"add {R(d)}, {R(d)}, #1", f"{label}:"]
    if kind == 20:
        return [f"mrs x{d}, nzcv", f"eor x{d}, x{d}, x{n}", f"msr nzcv, x{d}",
                f"msr tpidr_el0, x{m}", f"mrs x{a}, tpidr_el0"]
    return [f"adr x{d}, .", f"adrp x{n}, ."]


def program(seed):
    rng = random.Random(seed)
    labels = list(range(1000, 1, -1))
    lines = [".text", ".global _start", "_start:", "adr x28, scratch"]
    for r in range(26):
        value = rng.getrandbits(64)
        lines.append(f"movz x{r}, #{value & 0xffff}")
        for hw in (1, 2, 3):
            lines.append(f"movk x{r}, #{(value >> (16 * hw)) & 0xffff}, lsl #{16 * hw}")
    lines += [f"movz x26, #{rng.getrandbits(4) << 12}, lsl #16", "msr nzcv, x26"]
    for block in range(BLOCKS):
        for _ in range(BLOCK):
            lines += instruction(rng, labels)
        # Ce que le bloc laisse : x0 à x27, NZCV, puis la zone.
        for r in range(28):
            lines.append(f"str x{r}, [x28, #{SCRATCH + 8 * r}]")
        lines += ["mrs x27, nzcv", f"str x27, [x28, #{SCRATCH + 224}]",
                  "mov x0, #1", "mov x1, x28", f"mov x2, #{SCRATCH + 232}", "mov x8, #64", "svc #0"]
    lines += ["mov x0, #0", "mov x8, #93", "svc #0", ".data", ".balign 16", "scratch:", f".space {SCRATCH + 256}"]
    return "\n".join(lines) + "\n"


def tool(name, *args, **kw):
    return subprocess.run([name, *args], check=True, **kw)


def main():
    os.makedirs(OUT, exist_ok=True)
    with tempfile.TemporaryDirectory() as work:
        for index in range(PROGRAMS):
            source = program(0xA64 + index)
            stem = os.path.join(work, f"p{index}")
            with open(stem + ".s", "w") as handle:
                handle.write(source)
            tool("aarch64-linux-gnu-as", "-march=armv8-a", "-o", stem + ".o", stem + ".s")
            tool("aarch64-linux-gnu-ld", "-static", f"-Ttext={BASE:#x}", f"-Tdata={DATA:#x}", "-o", stem + ".elf", stem + ".o")
            tool("aarch64-linux-gnu-objcopy", "-O", "binary", "-j", ".text", stem + ".elf", stem + ".bin")
            ran = tool("qemu-aarch64", stem + ".elf", stdout=subprocess.PIPE)
            name = os.path.join(OUT, f"aleatoire-{index}")
            with open(stem + ".bin", "rb") as handle, open(name + ".bin", "wb") as out:
                out.write(handle.read())
            with open(name + ".attendu", "wb") as out:
                out.write(ran.stdout)
            print(f"{name}: {os.path.getsize(name + '.bin')} octets de code, {len(ran.stdout)} octets attendus")


if __name__ == "__main__":
    sys.exit(main())
