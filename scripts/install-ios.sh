#!/bin/sh
# Builds wisq and installs it on the iPhone plugged into this Mac — the
# shortest path to the app without an App Store listing.
#
#   ./scripts/install-ios.sh [--team TEAMID]
#
# Requirements: macOS with Xcode 15+, `brew install xcodegen`, an iPhone in
# developer mode connected over USB (and trusted). Without --team, Xcode's
# automatic signing picks your personal team; pass the 10-character team id
# if you have several. Apps signed with a free personal team expire after
# 7 days — re-run this script to refresh.
set -eu

[ "$(uname -s)" = "Darwin" ] || { echo "ce script exige macOS avec Xcode" >&2; exit 1; }
command -v xcodegen >/dev/null || { echo "xcodegen manquant : brew install xcodegen" >&2; exit 1; }

TEAM=""
[ "${1:-}" = "--team" ] && TEAM="$2"

echo "==> Génération du projet"
xcodegen generate

echo "==> Compilation signée pour l'appareil"
# shellcheck disable=SC2086
xcodebuild -project Wisq.xcodeproj -scheme Wisq -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath .build/ios \
  -allowProvisioningUpdates \
  CODE_SIGN_STYLE=Automatic \
  ${TEAM:+DEVELOPMENT_TEAM=$TEAM} \
  build

APP=".build/ios/Build/Products/Release-iphoneos/Wisq.app"
[ -d "$APP" ] || { echo "application introuvable : $APP" >&2; exit 1; }

echo "==> Installation sur l'iPhone connecté"
DEVICE="$(xcrun devicectl list devices --hide-headers 2>/dev/null | awk 'NR==1 {print $NF}')"
[ -n "$DEVICE" ] || { echo "aucun iPhone détecté : branchez-le, déverrouillez-le, activez le mode développeur" >&2; exit 1; }
xcrun devicectl device install app --device "$DEVICE" "$APP"

echo "==> Fait. wisq est sur l'écran d'accueil."
