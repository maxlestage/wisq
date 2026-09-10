#!/usr/bin/env bash
#
# **XcodeGen à la version que le dépôt a utilisée pour engendrer.**
#
# `Wisq.xcodeproj/project.pbxproj` et `App/Info.plist` sont écrits par
# `xcodegen generate` et commités, et la CI compare ce qu'elle vient
# d'engendrer à ce que le dépôt porte. Cette comparaison ne veut dire quelque
# chose que si les deux côtés lancent le **même** XcodeGen.
#
# Ce n'est pas une précaution théorique. La garde a rougi le jour de sa
# première exécution réelle, et pas pour la raison qui la justifie : la machine
# qui avait engendré les fichiers avait XcodeGen 2.43.0, `brew install
# xcodegen` sur le runner en a posé 2.46.0, et les deux versions n'écrivent pas
# le même en-tête de projet — `objectVersion` 54 contre 77,
# `compatibilityVersion` retirée, `productRefGroup` ajoutée, les deux cibles de
# test dans l'autre ordre. Rien de tout cela n'est une dérive de `project.yml`.
# Une garde qui rougit sur la date de la dernière mise à jour de Homebrew est
# un rouge que tout le monde apprend à ignorer, et le jour de la vraie dérive
# elle sera ignorée aussi.
#
# **D'où l'épinglage**, dans `.xcodegen-version`, un seul endroit. Les binaires
# publiés par XcodeGen sont universels — x86_64 et arm64 dans le même fichier,
# vérifié sur celui de 2.46.0 — donc épingler ne coûte pas une compilation :
# quatre mégaoctets et une extraction, à peu près ce que coûtait `brew
# install`.
#
# **Changer de version est un geste explicite** : écrire le nouveau numéro
# dans `.xcodegen-version`, régénérer, committer les deux fichiers engendrés
# dans le même commit. C'est exactement ce que la garde demande, et le diff le
# montre.
#
# **Ce qu'il écrit où.** Le **répertoire** qui contient le binaire part sur la
# sortie standard, et rien d'autre ; tout le reste va sur l'erreur standard. Un
# appelant le met donc en tête de son PATH :
#
#     PATH="$(scripts/install-xcodegen.sh):$PATH"
#     xcodegen generate
#
# Un répertoire plutôt que le binaire, et le PATH plutôt qu'une variable, pour
# une raison mesurée : trois gardes de ce dépôt s'ancrent sur la ligne
# littérale `xcodegen generate` — celle qui exige que l'icône soit dessinée
# d'abord, celle qui exige que la CI compare ce qu'elle engendre, et celle qui
# vérifie que `verify.sh` lance ce que la CI lance. Écrire `"$xcodegen"
# generate` les a fait cesser d'inspecter ces fichiers, deux en silence et une
# en rouge. La ligne reste donc ce qu'elle était, et c'est le PATH qui change.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
version=$(tr -d '[:space:]' < "$root/.xcodegen-version")

if [ -z "$version" ]; then
  echo "aucune version dans .xcodegen-version" >&2
  exit 1
fi

# Ce que `xcodegen --version` rend : « Version: 2.46.0 ». On garde le dernier
# mot de la première ligne plutôt que la ligne entière, pour ne pas dépendre
# du libellé.
version_of() {
  [ -x "$1" ] || return 1
  "$1" --version 2>/dev/null | awk 'NR==1 { print $NF }'
}

prefix="${WISQ_XCODEGEN_PREFIX:-$HOME/.wisq/xcodegen}"

# Celui du PATH d'abord : un contributeur qui a déjà la bonne version ne
# télécharge rien.
if existing=$(command -v xcodegen 2>/dev/null) \
  && [ "$(version_of "$existing" || true)" = "$version" ]; then
  echo "XcodeGen $version déjà en place ($existing)" >&2
  dirname "$existing"
  exit 0
fi

pinned="$prefix/bin/xcodegen"
if [ "$(version_of "$pinned" || true)" = "$version" ]; then
  echo "XcodeGen $version déjà posé ($pinned)" >&2
  echo "$prefix/bin"
  exit 0
fi

echo "==> XcodeGen $version depuis la release" >&2
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
curl -fsSL --max-time 180 -o "$work/xcodegen.zip" \
  "https://github.com/yonaskolb/XcodeGen/releases/download/$version/xcodegen.zip"
unzip -oq "$work/xcodegen.zip" -d "$work"

# `install.sh` du zip pose `bin/xcodegen` et `share/xcodegen/SettingPresets`
# sous un préfixe. Les presets comptent : sans eux XcodeGen n'a pas les
# réglages par défaut d'Apple et écrit un autre projet. On passe par le script
# publié plutôt que par un `cp` à nous, pour que la disposition reste celle que
# XcodeGen attend.
mkdir -p "$prefix"
PREFIX="$prefix" bash "$work/xcodegen/install.sh" >&2

got=$(version_of "$pinned" || true)
if [ "$got" != "$version" ]; then
  echo "XcodeGen installé rend « $got » et non « $version »" >&2
  exit 1
fi

# Sur un runner, les pas suivants sont d'autres processus : leur PATH ne vient
# pas d'ici, et `$GITHUB_PATH` est la seule route.
if [ -n "${GITHUB_PATH:-}" ]; then
  echo "$prefix/bin" >> "$GITHUB_PATH"
fi

echo "XcodeGen $version dans $prefix/bin" >&2
echo "$prefix/bin"
