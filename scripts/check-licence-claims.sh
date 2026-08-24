#!/usr/bin/env bash
#
# No licence has been chosen for wisq, so nothing shipped may claim one.
#
# This exists because removing the claim once was not enough. It was taken out
# of the site, and it survived in two places that ship anyway: the copyright
# string inside the app bundle, and the `license` field of the Homebrew
# formula. Both are read by other software as a statement of what a user may do
# with this code — a statement nobody has made.
#
# The check is deliberately narrow. Naming Apache-2.0 is *correct* in the
# README, in NOTICE and in the roadmap, where it is a fact about UTM, FreeRDP
# and QEMU — other people's projects, which really are under it. Only files
# that declare *this* project's own licence are checked, and the list is short
# on purpose: a grep over the whole tree would have to allow so much that it
# would stop meaning anything.
set -euo pipefail

cd "$(dirname "$0")/.."

# Files whose whole job is to state what this project is licensed under.
declared=(
  App/Info.plist
  Formula/wisq-agent.rb
  Package.swift
  site/src/index.html
)

claims='Apache-2\.0|Apache 2\.0|MIT License|Licence MIT|BSD-[23]|GPL-[23]|apache\.org/licenses|opensource\.org/licenses'

failed=0
for file in "${declared[@]}"; do
  [ -f "$file" ] || continue
  if matches=$(grep -nEi "$claims" "$file"); then
    echo "$file annonce une licence :"
    echo "$matches" | sed 's/^/  /'
    failed=1
  fi
done

# A LICENSE file is the loudest claim of all, and it grants rights by existing.
for file in LICENSE LICENSE.md LICENSE.txt COPYING; do
  if [ -e "$file" ]; then
    echo "$file existe : un fichier de licence accorde des droits que personne n'a décidé d'accorder."
    failed=1
  fi
done

# Cargo publishes its manifest field to crates.io.
while IFS= read -r manifest; do
  if matches=$(grep -nE '^\s*license\s*=' "$manifest"); then
    echo "$manifest annonce une licence :"
    echo "$matches" | sed 's/^/  /'
    failed=1
  fi
done < <(find . -name Cargo.toml -not -path "./target/*" -not -path "./.build/*")

if [ "$failed" -ne 0 ]; then
  echo
  echo "Aucune licence n'a été choisie pour wisq. Quand il y en aura une, c'est ici"
  echo "qu'il faudra le dire — délibérément, plutôt qu'en recopiant un modèle."
  exit 1
fi

echo "Licence : rien n'est annoncé, ce qui est l'état voulu."
