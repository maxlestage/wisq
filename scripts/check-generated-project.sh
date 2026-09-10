#!/usr/bin/env bash
#
# **Ce que la CI fabrique doit être ce que le dépôt porte.**
#
# `Wisq.xcodeproj/project.pbxproj` et `App/Info.plist` sont écrits par
# `xcodegen generate` **et** commités. Ce choix a une raison — sans eux, un
# dépôt fraîchement cloné n'a pas de projet à ouvrir, et XcodeGen n'est pas
# dans Xcode — et un prix : un fichier engendré sous suivi peut diverger de sa
# spec en silence. C'est exactement la famille de défaut que ce dépôt traque,
# et `App/Info.plist` s'est déjà retrouvé avec huit clés au lieu de dix-neuf
# sans que rien ne le signale.
#
# **Ce qui rend la garde presque gratuite** : la CI régénère de toute façon
# avant de construire. Il ne reste qu'à comparer. Une seule ligne —
# `git diff --exit-code` sur les deux fichiers — après chaque `xcodegen
# generate`, et la dérive devient un rouge au lieu d'une surprise.
#
# **Pourquoi une garde sur la garde.** La ligne de comparaison peut disparaître
# d'un workflow sans que rien ne change de couleur : elle ne sert que le jour
# où il y a une dérive, et ce jour-là elle n'est plus là. Ce script vérifie
# donc que **tout** workflow qui régénère compare aussi. Une exception à
# retenir est une exception qu'on oublie ; il n'y en a pas.
#
# **Il prend une racine, et c'est ce qui le rend éprouvable.** Sans argument il
# vérifie ce dépôt, ce que fait `verify.sh`. Avec un répertoire il vérifie
# celui-là, et c'est ainsi que `site/tests/generated-project.test.ts` le
# regarde refuser. Une garde qui n'a jamais refusé est une garde que personne
# n'a vérifiée.
set -euo pipefail

root="${1:-$(dirname "$0")/..}"
flows="$root/.github/workflows"

if [ ! -d "$flows" ]; then
  echo "introuvable : $flows" >&2
  exit 1
fi

failed=0
grief() {
  echo "$1" >&2
  failed=1
}

# Les deux fichiers qu'`xcodegen generate` écrit et que le dépôt porte. Écrits
# ici plutôt que devinés : c'est la liste que la comparaison doit couvrir, et
# un troisième fichier engendré un jour devra passer par là.
generated="Wisq.xcodeproj/project.pbxproj App/Info.plist"

found=0
for flow in "$flows"/*.yml; do
  [ -f "$flow" ] || continue
  grep -q 'xcodegen generate' "$flow" || continue
  found=$((found + 1))
  name=$(basename "$flow")
  # **La ligne de comparaison elle-même, pas le fichier entier.** Chercher le
  # nom d'un fichier n'importe où acceptait une mention dans un commentaire —
  # et ce commentaire, c'est celui qui explique la garde. Un test l'a montré
  # en retirant le fichier de la comparaison sans le retirer du texte : la
  # garde passait.
  comparison=$(grep 'git diff --exit-code' "$flow" || true)
  if [ -z "$comparison" ]; then
    grief "$name régénère le projet et ne compare pas : une dérive y passerait sans un rouge"
    continue
  fi
  for file in $generated; do
    case "$comparison" in
      *"$file"*) ;;
      *) grief "$name compare, mais pas $file : ce fichier-là pourrait diverger" ;;
    esac
  done
done

# **Zéro workflow trouvé n'est pas un succès.** Si personne ne régénère, la
# comparaison ne protège rien — et le plus probable est que ce script cherche
# au mauvais endroit.
if [ "$found" -eq 0 ]; then
  grief "aucun workflow ne lance « xcodegen generate » : la garde ne garde rien"
fi

if [ "$failed" -eq 0 ]; then
  echo "Projet engendré : $found workflow(s) régénèrent et comparent."
fi
exit "$failed"
