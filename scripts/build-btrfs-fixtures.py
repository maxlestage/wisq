#!/usr/bin/env python3
"""Refait Tests/WisqVMTests/BtrfsFixtures.swift : un petit btrfs écrit par
btrfs-progs, rangé creux (seuls ses blocs de 4 Kio non nuls), puis compressé
par zstd -19.

    python3 scripts/build-btrfs-fixtures.py DOSSIER

Demande mkfs.btrfs (btrfs-progs 6.6) et zstd. L'UUID change à chaque
passage : les tests ne lisent que sa forme.
"""
import base64, os, shutil, struct, subprocess, sys

out = sys.argv[1]
tree = os.path.join(out, "racine")
shutil.rmtree(tree, ignore_errors=True)
for d in ("etc", "boot/loader/entries", "vide"):
    os.makedirs(os.path.join(tree, d))


def letters(n):
    """Le générateur de `BtrfsVolumeTests.letters`."""
    x, out = 1, bytearray()
    for _ in range(n):
        x = (x * 1103515245 + 12345) & 0x7FFFFFFF
        out.append(97 + (x >> 16) % 26)
    return bytes(out)


def put(path, data):
    with open(os.path.join(tree, path), "wb") as f:
        f.write(data)


put("etc/court", b"wisq lit btrfs\n")
put("etc/vide", b"")
put("boot/noyau", letters(12000))
# Une entrée comme celle de Fedora : les chemins vus depuis la racine du
# btrfs, et la première mise en route déjà réglée.
put("boot/loader/entries/a.conf", b"title Fedora\nlinux /boot/noyau\ninitrd /etc/court\n"
    b"options root=UUID=x rootflags=subvol=root systemd.firstboot=off\n")
os.symlink("../etc/court", os.path.join(tree, "boot/lien-relatif"))
os.symlink("noyau", os.path.join(tree, "boot/lien-local"))
os.symlink("/etc/court", os.path.join(tree, "lien-absolu"))

img = os.path.join(out, "img")
# Un fichier vide plutôt qu'aucun : mkfs.btrfs se plaint sinon de ne pas
# pouvoir l'examiner, avant de le créer quand même.
open(img, "wb").close()
subprocess.run(["mkfs.btrfs", "-q", "--rootdir", tree, "--shrink", "-L", "essai", img], check=True)
d = open(img, "rb").read()
blocks = [i for i in range(len(d) // 4096) if d[i * 4096:(i + 1) * 4096].strip(b"\0")]
sparse = (struct.pack("<QI", len(d), len(blocks)) + b"".join(struct.pack("<I", b) for b in blocks)
          + b"".join(d[b * 4096:(b + 1) * 4096] for b in blocks))
packed = subprocess.run(["zstd", "-q", "-19", "-c"], input=sparse, check=True, capture_output=True).stdout
text = base64.b64encode(packed).decode()
lines = "\n".join(f'        "{text[i:i + 96]}",' for i in range(0, len(text), 96))

swift = os.path.join(os.path.dirname(__file__), "..", "Tests", "WisqVMTests", "BtrfsFixtures.swift")
source = open(swift).read()
head = source[:source.index("    static let sparseImage")]
open(swift, "w").write(head + "    static let sparseImage = [UInt8](Data(base64Encoded: [\n" + lines
                       + "\n    ].joined())!)\n}\n")
print(f"{len(d) >> 20} Mio, {len(blocks)} blocs, {len(packed)} octets en zstd")
