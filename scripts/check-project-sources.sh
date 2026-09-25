#!/usr/bin/env bash
#
# **Les fichiers que la spec déclare, et ceux que le projet référence.**
#
# `Wisq ‣.xcodeproj/project.pbxproj` est écrit par `xcodegen generate` et
# commité. Le jour où quelqu'un ajoute un fichier de test à l'application sans
# régénérer, la spec et le projet cessent de s'accorder — et **rien en local ne
# le voit**. `check-generated-project.sh`, malgré son nom, garde un autre
# sujet : que tout workflow qui régénère compare aussi. Il ne régénère rien.
# Seule la CI d'Apple attrapait donc un projet périmé, une fois la PR ouverte.
#
# C'est arrivé le 25 septembre, sur la tranche qui a ajouté
# `Tests/WisqUITests/IsoDeletionTests.swift` : « les fichiers engendrés par
# xcodegen ne sont pas ceux du dépôt », un cycle de CI pour une ligne que le
# coureur Linux pouvait dire en un dixième de seconde.
#
# **Et ça ne demande pas XcodeGen.** C'est la comparaison habituelle de ce
# dépôt — deux listes qui devraient s'accorder :
#
#   - les `.swift` présents sous chaque `sources: - path:` de `project.yml` ;
#   - les `.swift` que `project.pbxproj` référence.
#
# Les deux sens comptent. Un fichier ajouté et non régénéré manque au projet ;
# un fichier supprimé et non régénéré y traîne, et Xcode échoue alors sur un
# chemin qui n'existe plus.
#
# **Ce que cette garde ne tient pas, et le dire plutôt que le laisser croire.**
# Le projet référence ses fichiers par leur nom de base, la hiérarchie vivant
# dans les groupes ; reconstruire les chemins demanderait un analyseur de
# pbxproj. La comparaison porte donc sur les noms de base — et pour qu'elle ne
# s'affaiblisse pas en silence, **deux fichiers déclarés qui porteraient le
# même nom sont refusés** : la question deviendrait ambiguë, et une garde
# ambiguë ne garde rien. Elle ne remplace pas la régénération de la CI, qui
# compare octet pour octet ; elle attrape le cas qui arrive.
#
# **Il prend une racine**, comme son voisin, et c'est ce qui le rend éprouvable :
# `site/tests/project-sources.test.ts` le regarde refuser sur des arbres
# fabriqués. Une garde qui n'a jamais refusé est une garde que personne n'a
# vérifiée.
set -euo pipefail

root="${1:-$(dirname "$0")/..}"
spec="$root/project.yml"

if [ ! -f "$spec" ]; then
  echo "introuvable : $spec" >&2
  exit 1
fi

# Le nom du bundle vient de la spec, jamais écrit en dur : c'est lui qui a
# changé en #281, et une copie de plus aurait été une vérité de plus.
name=$(sed -n 's/^name: *//p' "$spec" | head -1)
if [ -z "$name" ]; then
  echo "project.yml ne déclare pas de clé « name »" >&2
  exit 1
fi
project="$root/$name.xcodeproj/project.pbxproj"

if [ ! -f "$project" ]; then
  echo "introuvable : $project" >&2
  exit 1
fi

failed=0
grief() {
  echo "$1" >&2
  failed=1
}

# Les racines déclarées : chaque « - path: » qui suit un « sources: ». Suivre
# le bloc plutôt que chercher « path: » partout — la spec en porte deux autres,
# celle du paquet Swift et celle de l'Info.plist, qui ne sont pas des sources.
roots=$(awk '
  /^[[:space:]]*sources:[[:space:]]*$/ { inside = 1; next }
  inside && /^[[:space:]]*-[[:space:]]*path:[[:space:]]*/ {
    sub(/^[[:space:]]*-[[:space:]]*path:[[:space:]]*/, ""); print; next
  }
  { inside = 0 }
' "$spec")

if [ -z "$roots" ]; then
  grief "aucune racine « sources: » lue dans project.yml : cette garde ne garderait rien"
  exit "$failed"
fi

declared=""
for source in $roots; do
  if [ ! -d "$root/$source" ]; then
    grief "project.yml déclare « $source », qui n'est pas un répertoire"
    continue
  fi
  found=$(find "$root/$source" -name '*.swift' -type f -exec basename {} \; | sort)
  declared=$(printf '%s\n%s' "$declared" "$found")
done
declared=$(printf '%s\n' "$declared" | sed '/^$/d' | sort)

if [ -z "$declared" ]; then
  grief "aucun fichier Swift sous les racines déclarées : cette garde ne garderait rien"
  exit "$failed"
fi

# Un nom de base en double rend la comparaison ambiguë. Refusé plutôt
# qu'ignoré : c'est la façon dont cette garde pourrait s'affaiblir sans
# prévenir.
doubles=$(printf '%s\n' "$declared" | uniq -d)
if [ -n "$doubles" ]; then
  while IFS= read -r double; do
    [ -n "$double" ] || continue
    grief "deux fichiers déclarés s'appellent « $double » : la comparaison par nom ne peut plus trancher"
  done <<< "$doubles"
fi

referenced=$(grep -oE 'path = [A-Za-z_][A-Za-z0-9_+-]*\.swift' "$project" \
  | sed 's/^path = //' | sort -u)

missing=$(comm -23 <(printf '%s\n' "$declared" | uniq) <(printf '%s\n' "$referenced"))
if [ -n "$missing" ]; then
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    grief "$file est déclaré par project.yml et absent du projet engendré"
  done <<< "$missing"
fi

stale=$(comm -13 <(printf '%s\n' "$declared" | uniq) <(printf '%s\n' "$referenced"))
if [ -n "$stale" ]; then
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    grief "$file est référencé par le projet engendré et n'existe plus sous les sources déclarées"
  done <<< "$stale"
fi

if [ "$failed" -ne 0 ]; then
  echo "lancer « xcodegen generate » et committer le résultat." >&2
  exit 1
fi

count=$(printf '%s\n' "$declared" | uniq | wc -l | tr -d ' ')
echo "Sources du projet : $count fichiers déclarés, tous référencés."
