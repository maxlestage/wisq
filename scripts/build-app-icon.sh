#!/bin/sh
# Écrit le catalogue d'icônes de l'application iOS.
#
#   scripts/build-app-icon.sh
#
# L'icône est **dessinée**, pas commitée : c'est la même marque que celle du
# site, produite par le même code (`site/scripts/icons.ts`). Une seconde
# version dessinée à la main serait une seconde chose à tenir en accord, et ce
# dépôt a déjà payé pour ça.
#
# Deux refus d'Apple sont la raison d'être de ce fichier, et aucun des deux
# n'apparaît à la compilation : un bundle iOS sans icône est rejeté à l'envoi
# (ITMS-90713, la clé `CFBundleIconName` manque), et une icône qui porte un
# canal alpha l'est aussi (ITMS-90717). Le générateur écrit donc du PNG
# opaque, et `xcodegen` doit trouver ce catalogue avant de produire le projet.
set -eu

cd "$(dirname "$0")/.."
command -v bun >/dev/null || {
  echo "bun manquant : https://bun.sh — il dessine l'icône" >&2
  exit 1
}

SET="App/Assets.xcassets/AppIcon.appiconset"
mkdir -p "$SET"

# Le catalogue lui-même : Xcode veut un Contents.json à sa racine.
cat > App/Assets.xcassets/Contents.json <<'JSON'
{
  "info" : { "author" : "wisq", "version" : 1 }
}
JSON

# Une seule taille : depuis Xcode 14, l'icône d'application est un unique
# fichier de 1024 points que le système décline lui-même.
cat > "$SET/Contents.json" <<'JSON'
{
  "images" : [
    {
      "filename" : "icon-1024.png",
      "idiom" : "universal",
      "platform" : "ios",
      "scale" : "1x",
      "size" : "1024x1024"
    }
  ],
  "info" : { "author" : "wisq", "version" : 1 }
}
JSON

bun --cwd site -e '
import { iOSAppIcon } from "./scripts/icons.ts";
await Bun.write("../'"$SET"'/icon-1024.png", iOSAppIcon());
'

echo "icône écrite : $SET/icon-1024.png"
