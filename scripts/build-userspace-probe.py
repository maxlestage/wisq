#!/usr/bin/env python3
"""Fabrique la sonde d'espace utilisateur : un `/init` statique et son initramfs.

**Ce fichier existe parce que sa recette était en prose.** #304 l'avait décrite
dans le journal — « un ELF statique écrit à la main, 197 octets », « un `newc`
de quatre entrées » — en disant que la recette était là « parce que le conteneur
est éphémère et que la refabriquer coûte une demi-heure ». Le conteneur a été
remplacé, et la refabriquer a coûté une demi-heure : la prose dit *quoi*, pas
*quels octets*. Une recette qu'il faut retraduire n'est pas un instrument.

**Ce que la sonde mesure, et pourquoi elle est si petite.** Le conteneur n'a ni
`busybox` ni `cpio` ; il n'y a donc rien à emprunter. Le `/init` fait deux
appels système et rien d'autre :

    write(1, "WISQ-USERSPACE-OK\\n", 18)
    exit(%eax)

Le second est tout le dispositif de mesure. Le code de retour d'un appel
système se lit **dans la panique du noyau** : `Attempted to kill init!
exitcode=0xXXYY00` porte le statut en `0xXX`. Pas besoin d'instrumenter
l'émulateur — et une sonde qui n'entre pas dans ce qu'elle mesure ne peut pas
le casser. #304 a lu ainsi `0xfb` = 251 = **−5** = −EIO ; #306, après que #305
a rendu au port série ses huit registres et sa ligne quatre, a lu `0x12` = **18**
— le nombre d'octets demandés.

**Et le message lui-même n'apparaît que si une console est nommée sur le
série.** Sans `console=ttyS0`, `/dev/console` est `tty0`, l'écran factice, et
les octets sont acceptés puis jetés. Avec, le relevé porte la ligne entre
« Run /init as init process » et la panique. D'où :

    ./scripts/build-userspace-probe.py /tmp/sonde
    WISQ_RAM=512 WISQ_INITRAMFS=/tmp/sonde/initramfs.cpio \\
      WISQ_CMDLINE=console=ttyS0 WISQ_ROUNDS=30000 WISQ_TURNS=900000 \\
      cargo run -p wisq-vm --release --example kernel-entry -- vmlinux.bin System.map

**Les deux objets sont relus par leurs propres analyseurs avant d'être posés**,
et le `/init` est lancé dans le conteneur : il doit imprimer son message et
sortir avec 18. Une sonde non calibrée qui ne dit rien ne distingue pas « le
noyau n'a pas écrit » de « la sonde ne sait pas écrire ».
"""

import os
import struct
import subprocess
import sys

MESSAGE = b"WISQ-USERSPACE-OK\n"
"""Dix-huit octets, et introuvables ailleurs dans un relevé : le `grep` qui les
cherche ne peut pas tomber sur autre chose."""

BASE = 0x40_0000
"""La base virtuelle du `/init`. Hors du noyau, hors de la page zéro."""


def init_elf() -> bytes:
    """L'ELF64 statique, deux en-têtes et trente-trois octets de code.

    Un seul `PT_LOAD`, lisible et exécutable, couvrant le fichier entier : il
    n'y a ni données inscriptibles ni section à nommer. Le point d'entrée tombe
    donc juste après les deux en-têtes, à `BASE + 0x78` — c'est l'adresse que le
    montage voit l'invité réclamer en anneau trois, et la voir est la preuve que
    l'espace utilisateur s'exécute.
    """
    entry = BASE + 64 + 56
    code = bytes(
        [
            0xB8, 0x01, 0x00, 0x00, 0x00,              # mov $1,%eax   — SYS_write
            0xBF, 0x01, 0x00, 0x00, 0x00,              # mov $1,%edi   — le descripteur 1
            0x48, 0x8D, 0x35, 0x10, 0x00, 0x00, 0x00,  # lea 16(%rip),%rsi
            0xBA, len(MESSAGE), 0x00, 0x00, 0x00,      # mov $18,%edx
            0x0F, 0x05,                                # syscall
            0x89, 0xC7,                                # mov %eax,%edi — le retour devient le statut
            0xB8, 0x3C, 0x00, 0x00, 0x00,              # mov $60,%eax  — SYS_exit
            0x0F, 0x05,                                # syscall
        ]
    )
    # **Le déplacement du `lea` est relatif au RIP d'après l'instruction.** Le
    # message suit le code, à 33 octets de l'entrée ; le RIP d'après le `lea`
    # est à 17. L'écart est donc seize, et une erreur ici ferait écrire des
    # octets quelconques sans que rien ne le dise.
    assert len(code) == 33, len(code)
    assert code[13] == 33 - 17
    body = code + MESSAGE
    total = 64 + 56 + len(body)
    header = (
        b"\x7fELF\x02\x01\x01\x00"
        + b"\x00" * 8
        + struct.pack(
            "<HHIQQQIHHHHHH",
            2,      # ET_EXEC
            0x3E,   # x86-64
            1,
            entry,
            64,     # e_phoff
            0,      # pas de table de sections
            0,
            64,     # e_ehsize
            56,     # e_phentsize
            1,      # un seul en-tête de programme
            64,
            0,
            0,
        )
    )
    program = struct.pack("<IIQQQQQQ", 1, 5, 0, BASE, BASE, total, total, 0x1000)
    assert len(header) == 64 and len(program) == 56
    return header + program + body


def newc(ino: int, mode: int, name: bytes, data: bytes = b"", rdev=(0, 0)) -> bytes:
    """Une entrée `newc` : cent dix caractères hexadécimaux, le nom, les données.

    Le nom et les données sont chacun complétés à un multiple de quatre, et la
    taille du nom **compte son octet nul**. Les deux règles ont l'air de détails
    et ce sont elles qui décident si le noyau lit une archive ou un gravier.
    """
    fields = [
        ino, mode, 0, 0, 1, 0, len(data), 0, 0, rdev[0], rdev[1], len(name) + 1, 0
    ]
    header = b"070701" + b"".join(b"%08X" % value for value in fields)
    assert len(header) == 110, len(header)
    block = header + name + b"\0"
    block += b"\0" * (-len(block) % 4)
    block += data
    block += b"\0" * (-len(block) % 4)
    return block


def archive(init: bytes) -> bytes:
    """Les quatre entrées, et celle qu'on oublie.

    `/dev/console` en **caractère 5:1** n'est pas décoratif : sans lui,
    `console_on_rootfs` n'ouvre aucun descripteur pour `/init`, et le `write`
    sur le descripteur 1 n'a nulle part où aller quoi que fasse le port série.
    La première version l'omettait, et le silence ressemblait au défaut qu'on
    cherchait.
    """
    return b"".join(
        [
            newc(1, 0o100755, b"init", init),
            newc(2, 0o040755, b"dev"),
            newc(3, 0o020600, b"dev/console", rdev=(5, 1)),
            newc(0, 0, b"TRAILER!!!"),
        ]
    )


def reread(blob: bytes) -> list:
    """L'archive relue par son propre analyseur, plutôt que supposée bonne."""
    at, seen = 0, []
    while at + 110 <= len(blob):
        header = blob[at : at + 110]
        assert header[:6] == b"070701", header[:6]
        fields = [int(header[6 + 8 * i : 14 + 8 * i], 16) for i in range(13)]
        mode, size, major, minor, namesize = (
            fields[1], fields[6], fields[9], fields[10], fields[11]
        )
        name = blob[at + 110 : at + 110 + namesize - 1].decode()
        seen.append((name, mode, size, (major, minor)))
        if name == "TRAILER!!!":
            break
        start = at + 110 + namesize
        start += -start % 4
        at = start + size
        at += -at % 4
    return seen


def main() -> int:
    where = sys.argv[1] if len(sys.argv) > 1 else "."
    os.makedirs(where, exist_ok=True)
    init = init_elf()
    init_path = os.path.join(where, "init")
    with open(init_path, "wb") as handle:
        handle.write(init)
    os.chmod(init_path, 0o755)

    # **Calibrée avant d'être posée.** Le même binaire, dans le conteneur, doit
    # imprimer son message et sortir avec le nombre d'octets qu'il a demandés.
    done = subprocess.run([init_path], capture_output=True, check=False)
    if done.stdout != MESSAGE or done.returncode != len(MESSAGE):
        print(
            f"la sonde n'est pas calibrée : {done.stdout!r}, sortie {done.returncode} "
            f"(attendu {MESSAGE!r}, sortie {len(MESSAGE)})",
            file=sys.stderr,
        )
        return 1

    blob = archive(init)
    cpio_path = os.path.join(where, "initramfs.cpio")
    with open(cpio_path, "wb") as handle:
        handle.write(blob)
    seen = reread(blob)
    expected = ["init", "dev", "dev/console", "TRAILER!!!"]
    if [entry[0] for entry in seen] != expected:
        print(f"l'archive ne se relit pas : {seen}", file=sys.stderr)
        return 1
    if seen[0][2] != len(init):
        print(f"le `/init` relu ne fait pas sa taille : {seen[0]}", file=sys.stderr)
        return 1
    if seen[2][3] != (5, 1):
        print(f"`/dev/console` n'est pas en 5:1 : {seen[2]}", file=sys.stderr)
        return 1

    print(f"{init_path} : {len(init)} octets, entrée {BASE + 120:#x}, calibrée")
    print(f"{cpio_path} : {len(blob)} octets")
    for name, mode, size, rdev in seen:
        print(f"  {name:12} mode={oct(mode):9} {size:4} octets  rdev={rdev[0]}:{rdev[1]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
