#!/usr/bin/env bash
#
# **Le démon pèse ce que le dépôt annonce qu'il pèse.**
#
# Huit textes au présent donnent la taille du binaire statique que la release
# publie : les deux langues de la page « protocole » du site, le document du
# protocole, les deux README, le guide de contribution, le commentaire de
# `Package.swift` qui explique pourquoi le démon a quitté Swift, et celui du
# workflow de release. Aucun n'était tenu, et ça se voyait : le 28 septembre
# 2026 ils portaient **trois chiffres différents pour un seul binaire** —
# 1,7 Mo au document et aux README, 582 Ko au site et au guide de
# contribution, 454 Ko au manifeste. Les deux derniers avaient été vrais, avant
# le TLS et avant l'appairage.
#
# **Et le nombre était produit à chaque exécution de la CI, puis jeté.** Le job
# Rust construit exactement ce binaire et en imprime la taille par un `ls -l`
# que personne ne lit. C'est la onzième façon de se tromper consignée au
# JOURNAL : un instrument qui connaît la réponse à une question que le dépôt
# pose ailleurs, sans savoir qu'il la pose. Ce script est le fil entre les deux.
#
# **L'unité est décimale, et il a fallu la trancher.** « Mo » et « MB » valent
# 10^6 octets ; le mébioctet s'écrit Mio. La question ne se posait pas au
# 2 septembre — 1 737 424 octets font 1,7 dans les deux lectures — et elle s'est
# posée dès que le démon a grossi : 1 778 384 octets font 1,8 Mo et 1,7 Mio. Un
# chiffre publié dont l'unité se lit de deux façons n'est pas un chiffre publié.
#
# **La décimale est la bonne granularité, et c'est mesuré.** Deux constructions
# de la même source ne rendent pas le même nombre d'octets : ce conteneur donne
# 1 778 384, le coureur de la CI 1 770 192 — 8 192 octets d'écart, versions de
# rustc et des dépendances. Une garde qui épinglerait l'octet exact aurait été
# rouge dès sa première exécution en CI, pour un binaire parfaitement sain. La
# comparaison porte donc sur le chiffre publié, à la décimale, qui est aussi ce
# qu'un lecteur du site peut vérifier.
#
# **Et l'écart vient de la chaîne, pas de la machine.** Le 8 octobre 2026 ce
# conteneur et le coureur ont rendu **1 749 840 octets tous les deux**, au
# même octet, l'un et l'autre sous rustc 1.99.0 — et 1 749 840 est à 160 octets
# d'une frontière d'arrondi, donc le moindre écart se serait vu. Les 8 192
# octets ci-dessus séparaient deux versions de rustc, pas deux machines. La
# conséquence est utile le jour où cette garde rougit près d'une frontière :
# avant de soupçonner sa résolution, comparer les chaînes. Si elles
# s'accordent, le chiffre est le même partout et c'est bien le texte qui a
# vieilli.
#
# **Il prend une racine**, comme ses voisins, et c'est ce qui le rend éprouvable :
# `site/tests/agent-size.test.ts` le regarde refuser sur des arbres fabriqués,
# avec un binaire de taille choisie. Une garde qui n'a jamais refusé est une
# garde que personne n'a vérifiée.
#
# **Ce qu'il ne tient pas.** La taille aarch64 (« ~1,4 MB on aarch64 », dans le
# même commentaire de release.yml) demande une chaîne croisée que ce script n'a
# pas le droit de supposer présente. Elle reste une mesure datée.
set -euo pipefail

root="${1:-$(dirname "$0")/..}"
binary="$root/target/x86_64-unknown-linux-musl/release/wisq-agent"

if [ ! -f "$binary" ]; then
  cat >&2 <<EOF
introuvable : $binary

    rustup target add x86_64-unknown-linux-musl
    sudo apt-get install -y musl-tools   # ring, la dépendance C que TLS a amenée
    cargo build --release --target x86_64-unknown-linux-musl -p wisq-agent
EOF
  exit 1
fi

bytes=$(stat -c %s "$binary" 2>/dev/null || stat -f %z "$binary")
measured=$(awk -v b="$bytes" 'BEGIN { printf "%.1f", b / 1000000 }')

failed=0
grief() {
  echo "$1" >&2
  failed=1
}

# Chaque lecteur **lève** quand son motif ne trouve rien, et il lève aussi quand
# il en trouve deux. Un lecteur qui ne lit rien ne se distingue pas d'un lecteur
# qui lit la bonne chose, tant que les deux côtés de la comparaison sont vides —
# c'est le trou que le JOURNAL a mesuré sur la garde des versions.
announced() {
  local label="$1" file="$2" pattern="$3"
  local found count
  found=$(grep -oE "$pattern" "$root/$file" || true)
  count=$(printf '%s' "$found" | grep -c . || true)
  if [ "$count" -ne 1 ]; then
    grief "$label : le motif trouve $count occurrence(s) dans $file, il en faut une. Le texte a changé de forme, ou le fichier a bougé."
    return
  fi
  local value
  value=$(printf '%s' "$found" | grep -oE '[0-9]+[.,][0-9]+' | tr ',' '.')
  if [ "$value" != "$measured" ]; then
    grief "$label annonce $value, le binaire fait $bytes octets, soit $measured Mo ($file)."
  fi
}

announced "le site, en anglais" \
  "site/src/pages/protocol.ts" "it is now [0-9]+[.,][0-9]+ MB"
announced "le site, en français" \
  "site/src/pages/protocol.ts" "il en fait [0-9]+[.,][0-9]+ Mo"
announced "le document du protocole" \
  "docs/AGENT-PROTOCOL.md" "il en fait aujourd'hui \*\*[0-9]+[.,][0-9]+ Mo\*\*"
announced "le manifeste du paquet" \
  "Package.swift" "it is now [0-9]+[.,][0-9]+ MB"
announced "le workflow de release" \
  ".github/workflows/release.yml" "[0-9]+[.,][0-9]+ MB on x86_64"
announced "le README anglais" \
  "README.md" "from 58 MB to [0-9]+[.,][0-9]+ MB"
announced "le README français" \
  "README.fr.md" "de 58 Mo à [0-9]+[.,][0-9]+ Mo"
announced "le guide de contribution" \
  "CONTRIBUTING.md" "from 58 MB to [0-9]+[.,][0-9]+ MB"

if [ "$failed" -ne 0 ]; then
  echo "" >&2
  echo "Le démon a changé de taille et les textes ne l'ont pas appris." >&2
  exit 1
fi

echo "Taille du démon : $bytes octets, soit $measured Mo — les huit textes s'accordent."
