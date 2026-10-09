#!/usr/bin/env bash
#
# **La chaîne que demande le front du site, installée en un seul endroit.**
#
# Depuis que `crates/wisq-site` est en Yew, construire le site demande plus que
# Bun : la cible `wasm32-unknown-unknown`, `wasm-bindgen` pour emballer le
# module, et `wasm-opt` pour le réduire. La CI et Heroku en ont tous les deux
# besoin, donc ils appellent ce script au lieu d'en porter chacun une copie.
#
# **La version de wasm-bindgen est lue, pas écrite.** L'outil et la bibliothèque
# doivent être de la même version, sinon l'emballage échoue sur un message
# obscur. La version est donc dérivée de `Cargo.lock`, qui est la seule chose
# qui la décide. L'écrire ici en aurait fait une seconde copie — la faute que ce
# dépôt passe son temps à corriger ailleurs.
#
# **Le binaire est téléchargé, pas compilé.** `cargo install wasm-bindgen-cli`
# prend environ quatre minutes ; l'archive préconstruite en prend trois
# secondes, mesuré. Sur un déploiement que personne ne peut déboguer depuis un
# téléphone, c'est la différence entre une attente et un délai d'expiration.
#
# Il prend une racine, comme ses voisins, pour être éprouvable ailleurs que sur
# cet arbre-ci.
set -euo pipefail

root="${1:-$(dirname "$0")/..}"
cd "$root"

if [ ! -f Cargo.lock ]; then
  echo "Cargo.lock introuvable dans $PWD : impossible de savoir quelle version de wasm-bindgen installer." >&2
  exit 1
fi

# La version qui suit `name = "wasm-bindgen"` dans le verrou. `-A 1` plutôt
# qu'une recherche libre : le fichier contient aussi `wasm-bindgen-backend`,
# `wasm-bindgen-macro` et leurs versions, qui ne sont pas celle-là.
version=$(awk '/^name = "wasm-bindgen"$/ { getline; gsub(/[^0-9.]/, "", $0); print; exit }' Cargo.lock)
if [ -z "$version" ]; then
  echo "aucune version de wasm-bindgen dans Cargo.lock : le front est-il toujours en Yew ?" >&2
  exit 1
fi
echo "==> wasm-bindgen $version, d'après Cargo.lock"

if ! command -v rustup >/dev/null 2>&1; then
  echo "==> Installation de rustup"
  curl -fsSL https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain stable
  # shellcheck disable=SC1091
  . "$HOME/.cargo/env"
fi
export PATH="$HOME/.cargo/bin:$PATH"

echo "==> Cible wasm32-unknown-unknown"
rustup target add wasm32-unknown-unknown

# Déjà à la bonne version : rien à faire. C'est le cas de tout conteneur de
# développement qui vient d'en construire un.
if command -v wasm-bindgen >/dev/null 2>&1 && \
   [ "$(wasm-bindgen --version | awk '{print $2}')" = "$version" ]; then
  echo "==> wasm-bindgen $version déjà présent"
  exit 0
fi

archive="wasm-bindgen-${version}-x86_64-unknown-linux-musl"
echo "==> Téléchargement de $archive"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
curl -fsSL "https://github.com/rustwasm/wasm-bindgen/releases/download/${version}/${archive}.tar.gz" \
  | tar xz -C "$tmp"
mkdir -p "$HOME/.cargo/bin"
install -m 0755 "$tmp/$archive/wasm-bindgen" "$HOME/.cargo/bin/wasm-bindgen"
echo "==> wasm-bindgen $(wasm-bindgen --version | awk '{print $2}') installé"
