#!/usr/bin/env python3
"""Refait Tests/WisqVMTests/XfsFixtures.swift : un petit XFS en version 5,
rempli par le noyau à travers un montage en boucle, rangé creux (seuls ses
blocs de 4 Kio non nuls), puis compressé par zstd -19.

    sudo python3 scripts/build-xfs-fixtures.py DOSSIER

Demande mkfs.xfs (xfsprogs 6.6), zstd et le droit de monter. Le noyau, pas
un fichier prototype : c'est lui qui fait passer un répertoire en blocs,
puis en feuilles, puis en nœuds, et un fichier troué en arbre d'extents.
L'UUID change à chaque passage : les tests ne lisent que sa forme.
"""
import base64, os, struct, subprocess, sys

out = sys.argv[1]
os.makedirs(out, exist_ok=True)


def letters(n):
    """Le générateur de `BtrfsVolumeTests.letters`."""
    x, buf = 1, bytearray()
    for _ in range(n):
        x = (x * 1103515245 + 12345) & 0x7FFFFFFF
        buf.append(97 + (x >> 16) % 26)
    return bytes(buf)


def fill(root):
    def put(path, data):
        with open(os.path.join(root, path), "wb") as f:
            f.write(data)
    for d in ("etc", "boot/loader/entries", "vide", "grand", "immense"):
        os.makedirs(os.path.join(root, d))
    put("etc/court", b"wisq lit xfs\n")
    put("etc/vide", b"")
    put("boot/noyau", letters(12000))
    put("boot/loader/entries/a.conf", b"title openSUSE\nlinux /boot/noyau\ninitrd /etc/court\n"
        b"options root=UUID=x\n")
    # Un octet tous les deux blocs : deux cents extents, bien trop pour
    # l'inode, qui les range dans un arbre.
    with open(os.path.join(root, "boot/troue"), "wb") as f:
        for i in range(200):
            f.seek(i * 8192)
            f.write(bytes([65 + i % 26]))
    # Des blocs réservés mais jamais écrits : ils se lisent en zéros, quoi
    # que porte le disque dessous.
    with open(os.path.join(root, "boot/reserve"), "wb") as f:
        f.write(b"debut")
        f.flush()
        os.posix_fallocate(f.fileno(), 0, 1 << 20)
    os.symlink("../etc/court", os.path.join(root, "boot/lien-relatif"))
    os.symlink("noyau", os.path.join(root, "boot/lien-local"))
    os.symlink("/etc/court", os.path.join(root, "lien-absolu"))
    # Plus long que ce que l'inode peut garder : le lien part dans un bloc.
    os.symlink("./" * 300 + "etc/court", os.path.join(root, "lien-long"))
    for i in range(40):
        put(f"grand/f{i:03d}", b"")
    for i in range(3000):
        put(f"immense/fichier-au-nom-assez-long-{i:05d}", b"")
    put("immense/fichier-au-nom-assez-long-02999", b"le dernier\n")


def build(name, options):
    img = os.path.join(out, name + ".img")
    mnt = os.path.join(out, "montage")
    os.makedirs(mnt, exist_ok=True)
    with open(img, "wb") as f:
        f.truncate(300 << 20)
    subprocess.run(["mkfs.xfs", "-q", "-f", "-L", "essai", *options, img], check=True)
    subprocess.run(["mount", "-o", "loop", img, mnt], check=True)
    try:
        fill(mnt)
    finally:
        subprocess.run(["umount", mnt], check=True)
    d = open(img, "rb").read()
    blocks = [i for i in range(len(d) // 4096) if d[i * 4096:(i + 1) * 4096].strip(b"\0")]
    sparse = (struct.pack("<QI", len(d), len(blocks)) + b"".join(struct.pack("<I", b) for b in blocks)
              + b"".join(d[b * 4096:(b + 1) * 4096] for b in blocks))
    packed = subprocess.run(["zstd", "-q", "-19", "-c"], input=sparse, check=True, capture_output=True).stdout
    text = base64.b64encode(packed).decode()
    lines = "\n".join(f'        "{text[i:i + 96]}",' for i in range(0, len(text), 96))
    print(f"{name} : {len(d) >> 20} Mio, {len(blocks)} blocs, {len(packed)} octets en zstd")
    return f"    static let {name} = [UInt8](Data(base64Encoded: [\n{lines}\n    ].joined())!)\n"


# Les compteurs d'extents sur 64 bits, comme openSUSE.
v5 = build("version5", ["-i", "nrext64=1"])
swift = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Tests", "WisqVMTests", "XfsFixtures.swift")
source = open(swift).read()
head = source[:source.index("    static let version5")]
open(swift, "w").write(head + v5 + "}\n")
