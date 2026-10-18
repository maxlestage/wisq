#!/usr/bin/env python3
"""Refait Tests/WisqVMTestKit/Ext4Fixtures.swift : deux petits systèmes de
fichiers écrits par e2fsprogs, l'un ext4 (blocs de 4 Kio, extents, 64 bits,
metadata_csum), l'autre ext2 (blocs de 1 Kio, blocs indirects).

    python3 scripts/build-ext4-fixtures.py DOSSIER

Demande mkfs.ext4, mkfs.ext2 et e2fsck (e2fsprogs 1.47). Les identifiants,
la graine du hachage et l'heure sont fixés : deux passages rendent les mêmes
octets. `e2fsck -fD` indexe ensuite les répertoires (htree), ce que
`mkfs -d` ne fait pas.
"""
import base64, os, shutil, subprocess, sys, zlib

out = sys.argv[1]
tree = os.path.join(out, "tree")
shutil.rmtree(tree, ignore_errors=True)
for d in ("boot/grub", "etc", "many"):
    os.makedirs(os.path.join(tree, d))


def pattern(n, seed):
    return bytes(((i * 7 + (i >> 9) + seed) & 0xFF) for i in range(n))


def put(path, data):
    with open(os.path.join(tree, path), "wb") as f:
        f.write(data)


put("boot/vmlinuz-6.1.0-test", pattern(300_000, 1))
put("boot/initrd.img-6.1.0-test", pattern(70_000, 2))
put("boot/grub/grub.cfg", b"menuentry 'Test' {\n\tlinux\t/boot/vmlinuz-6.1.0-test root=/dev/vda1 ro\n"
    b"\tinitrd\t/boot/initrd.img-6.1.0-test\n}\n")
put("etc/hostname", b"wisq\n")
put("boot/reserved", pattern(4096, 3))
# Un fichier creux : six îlots de 4 Kio à 100 Kio d'écart. Six extents ne
# tiennent pas dans l'inode (quatre au plus) : l'arbre a un niveau d'index.
with open(os.path.join(tree, "boot/sparse"), "wb") as f:
    for k in range(6):
        f.seek(k * 100 * 1024)
        f.write(pattern(4096, 10 + k))
    f.truncate(6 * 100 * 1024)
os.symlink("boot/vmlinuz-6.1.0-test", os.path.join(tree, "vmlinuz"))
# Relatif, dans un sous-répertoire : il se lit depuis `boot`, pas depuis la racine.
os.symlink("vmlinuz-6.1.0-test", os.path.join(tree, "boot/current"))
os.symlink("/boot/./grub/../initrd.img-6.1.0-test", os.path.join(tree, "initrd.img"))
os.symlink("../boot/initrd.img-6.1.0-test", os.path.join(tree, "etc/initrd-relative"))
os.symlink("a" * 70, os.path.join(tree, "dangling-long"))  # plus de 60 octets : un lien « lent »
os.symlink("loop-b", os.path.join(tree, "loop-a"))
os.symlink("loop-a", os.path.join(tree, "loop-b"))
for i in range(40):
    put("etc/f%02d" % i, str(i).encode())
# Assez d'entrées pour que le répertoire tienne sur plusieurs blocs et soit indexé.
for i in range(200):
    put("many/entree-numero-%03d-avec-un-nom-assez-long" % i, b"%d\n" % i)

env = dict(os.environ, E2FSPROGS_FAKE_TIME="1790000000")
seed = "hash_seed=6f1c0f3a-6c5e-4b8e-9f8f-1d1f1a1b1c1d,root_owner=0:0"
images = {
    "ext4": ["mkfs.ext4", "-q", "-F", "-b", "4096", "-N", "512", "-U",
             "13223055-e9dd-4810-96ca-8fe4d0ef1d49", "-E", seed, "-L", "wisq-ext4"],
    "ext2": ["mkfs.ext2", "-q", "-F", "-b", "1024", "-N", "512", "-U",
             "2b0f3e8a-1c2d-4e5f-8a9b-0c1d2e3f4a5b", "-E", seed, "-L", "wisq-ext2"],
}
lines = [
    "import Foundation",
    "",
    "// Deux systèmes de fichiers écrits par e2fsprogs 1.47 (`mkfs -d`, puis",
    "// `e2fsck -fD` pour indexer les répertoires), en deflate brut puis base64.",
    "// Ne pas éditer à la main ; pour les refaire : scripts/build-ext4-fixtures.py.",
    "public enum Ext4Fixtures {",
    "    public static let size = 2 << 20",
]
for name, command in images.items():
    image = os.path.join(out, name + ".img")
    if os.path.exists(image):
        os.remove(image)
    subprocess.run(command + ["-d", tree, image, "2M"], check=True, env=env,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    code = subprocess.run(["e2fsck", "-fyD", image], env=env,
                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode
    assert code in (0, 1), code
    if name == "ext4":
        # Quatre blocs réservés mais jamais écrits après le premier, comme les
        # laisse `fallocate` ; ils sont remplis d'octets non nuls, qu'un
        # lecteur qui les croirait écrits rendrait au lieu de zéros.
        for command_line in ("fallocate /boot/reserved 1 4", "sif /boot/reserved size 20480"):
            subprocess.run(["debugfs", "-w", "-R", command_line, image], check=True,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        stat = subprocess.run(["debugfs", "-R", "stat /boot/reserved", image], capture_output=True,
                              text=True).stdout
        first = int(stat.split("[u]):")[1].split("-")[0])
        with open(image, "r+b") as f:
            f.seek(first * 4096)
            f.write(b"\x5a" * 4 * 4096)
        assert subprocess.run(["e2fsck", "-fn", image], stdout=subprocess.DEVNULL,
                              stderr=subprocess.DEVNULL).returncode == 0
        # Où sont, dans l'image, le bloc d'index des extents de `boot/sparse`
        # et l'inode de `etc/hostname` : les tests les abîment exprès.
        stat = subprocess.run(["debugfs", "-R", "stat /boot/sparse", image], capture_output=True,
                              text=True).stdout
        index_block = int(stat.split("(ETB0):")[1].split(",")[0])
        imap = subprocess.run(["debugfs", "-R", "imap /etc/hostname", image], capture_output=True,
                              text=True).stdout
        located = imap.split("located at block ")[1]
        block, offset = located.split(", offset ")
        lines.append("    /// Le bloc d'index des extents de `boot/sparse`, dans `ext4`.")
        lines.append("    public static let sparseIndexBlock = %d" % index_block)
        lines.append("    /// Le décalage de l'inode de `etc/hostname`, dans `ext4`.")
        lines.append("    public static let hostnameInodeOffset = %d" % (int(block) * 4096 + int(offset.split()[0], 0)))
    data = open(image, "rb").read()
    packer = zlib.compressobj(9, zlib.DEFLATED, -15)
    packed = base64.b64encode(packer.compress(data) + packer.flush()).decode()
    lines.append("")
    lines.append("    public static let %s = [" % name)
    lines += ['        "%s",' % packed[i:i + 96] for i in range(0, len(packed), 96)]
    lines.append("    ].joined()")
lines.append("}")
with open(os.path.join(out, "Ext4Fixtures.swift"), "w") as f:
    f.write("\n".join(lines) + "\n")
