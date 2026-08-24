#!/usr/bin/env bash
#
# Runs the app layer's tests inside a booted iPhone simulator.
#
# `WisqUI` is `#if os(iOS)`: the Linux runner never compiles it, so for a while
# it was described as the part CI could not check — and two defects reached a
# pull request while that was the story. It needs an iOS runtime, and both CI
# and any Mac with Xcode have one. This is that runtime.
#
# Needs: macOS with Xcode, xcodegen, and the VM core available to the manifest
# (`scripts/build-xcframework.sh`, or WISQ_SWIFT_CORE=1 without cargo).
set -euo pipefail

cd "$(dirname "$0")/.."

command -v xcodegen >/dev/null 2>&1 || {
  echo "xcodegen absent : brew install xcodegen" >&2
  exit 1
}

echo "==> Génération du projet"
xcodegen generate

# The runner image drops simulator models between releases, so naming one
# ("iPhone 16") is a test that breaks on someone else's schedule. Ask for
# whatever iPhone is actually installed, newest runtime first.
echo "==> Choix d'un simulateur"
udid=$(xcrun simctl list devices available --json | python3 -c '
import json, sys
devices = json.load(sys.stdin)["devices"]
for runtime in sorted(devices, reverse=True):
    for device in devices[runtime]:
        if device.get("isAvailable") and "iPhone" in device["name"]:
            print(device["udid"], device["name"], runtime.rsplit(".", 1)[-1])
            raise SystemExit
raise SystemExit("aucun iPhone simulé disponible")
')
[ -n "$udid" ] || { echo "aucun iPhone simulé disponible" >&2; exit 1; }
echo "    $udid"

echo "==> Tests de la couche application, dans un iPhone simulé"
xcodebuild test \
  -project Wisq.xcodeproj \
  -scheme Wisq \
  -destination "id=${udid%% *}" \
  CODE_SIGNING_ALLOWED=NO

echo "==> La couche application est vérifiée, pas seulement compilée."
