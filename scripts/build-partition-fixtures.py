#!/usr/bin/env python3
"""Refait Tests/WisqVMTests/PartitionFixtures.swift depuis une image cloud.

    curl -LO https://cloud.debian.org/images/cloud/trixie/latest/debian-13-nocloud-amd64.qcow2
    qemu-img convert -O raw debian-13-nocloud-amd64.qcow2 deb.raw
    python3 scripts/build-partition-fixtures.py deb.raw DOSSIER

Ne garde que les octets non nuls des 34 premiers et des 33 derniers secteurs
(MBR protecteur, GPT et sa copie de secours), puis les remet dans un disque
creux de même taille converti en qcow2.
"""
import sys,os,zlib,base64,subprocess
raw,outdir=sys.argv[1],sys.argv[2]
size=os.path.getsize(raw); f=open(raw,'rb')
def runs(base,data):
    out=[];i=0
    while i<len(data):
        if data[i]==0: i+=1; continue
        j=i
        while j<len(data) and (data[j]!=0 or any(data[j:j+8])): j+=1
        out.append((base+i,data[i:j])); i=j
    return out
head=f.read(34*512); f.seek(size-33*512); tail=f.read()
r=runs(0,head)+runs(size-33*512,tail)
# Un disque creux de même taille, avec ces seuls octets, puis en qcow2.
sparse=os.path.join(outdir,'gpt.raw'); g=open(sparse,'wb'); g.truncate(size)
for o,b in r: g.seek(o); g.write(b)
g.close()
q=os.path.join(outdir,'gpt.qcow2')
subprocess.run(['qemu-img','convert','-f','raw','-O','qcow2','-o','cluster_size=4096',sparse,q],check=True)
qb=open(q,'rb').read()
c=zlib.compressobj(9,zlib.DEFLATED,-15); packed=c.compress(qb)+c.flush()
b64=base64.b64encode(packed).decode()
lines=[]
lines.append("import Foundation\n")
lines.append("// La table de partitions de l'image cloud « nocloud » de Debian 13, telle")
lines.append("// que l'écrit l'équipe cloud de Debian : `debian-13-nocloud-amd64.qcow2`, somme")
lines.append("// SHA-512 401ffd04…5bd0df26 publiée dans SHA512SUMS, convertie en brut par")
lines.append("// `qemu-img convert -O raw`. Ne sont gardés que les octets non nuls des 34")
lines.append("// premiers et des 33 derniers secteurs : le MBR protecteur, l'en-tête GPT et")
lines.append("// ses entrées, et leur copie de secours. Ne pas éditer à la main ; pour les")
lines.append("// refaire, voir scripts/build-partition-fixtures.py.")
lines.append("enum PartitionFixtures {")
lines.append("    /// La taille du disque virtuel : 3 Gio.")
lines.append("    static let debianSize: UInt64 = %d\n" % size)
lines.append("    /// Les plages non nulles : décalage, octets en hexadécimal.")
lines.append("    static let debianRuns: [(UInt64, String)] = [")
for o,b in r:
    h=b.hex()
    chunks=[h[i:i+96] for i in range(0,len(h),96)]
    if len(chunks)==1: lines.append('        (%d, "%s"),' % (o,chunks[0]))
    else:
        lines.append('        (%d, [' % o)
        for ch in chunks: lines.append('            "%s",' % ch)
        lines.append('        ].joined()),')
lines.append("    ]\n")
lines.append("    /// Le même disque en qcow2 (`qemu-img convert -O qcow2 -o cluster_size=4096`),")
lines.append("    /// %d octets, en deflate brut puis base64." % len(qb))
lines.append("    static let debianQcow2Size = %d" % len(qb))
lines.append("    static let debianQcow2 = [")
for i in range(0,len(b64),96): lines.append('        "%s",' % b64[i:i+96])
lines.append("    ].joined()")
lines.append("}")
open(os.path.join(outdir,'PartitionFixtures.swift'),'w').write("\n".join(lines)+"\n")
print(len(r), len(qb), len(b64))
