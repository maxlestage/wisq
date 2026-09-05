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
"$(dirname "$0")/build-app-icon.sh"
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
# **La sortie est gardée**, et pas seulement regardée passer. `xcodebuild`
# écrit des dizaines de milliers de lignes ; les quelques-unes qui portent une
# mesure — le débit de WebKit, le coût du pont — s'y noient, et une mesure
# qu'on ne retrouve pas est une mesure qu'on refait. Elles sont donc extraites
# à la fin, et poussées dans le résumé du job quand il y en a un.
sortie=$(mktemp)
trap 'rm -f "$sortie"' EXIT
# Les mesures survivent au script, dans un fichier que la CI relit à la toute
# fin : `xcodebuild` écrit ensuite des milliers de lignes de compilation, et
# ce qui est au milieu d'un log de cette taille est introuvable en pratique.
mesuresFichier="${RUNNER_TEMP:-/tmp}/wisq-mesures-app.txt"
# **Un fichier, pas un tube.** `xcodebuild | tee` ne se termine pas : les
# démons du simulateur héritent du bout écrivain du tube et le gardent ouvert
# après la fin des tests, donc `tee` attend une fin de fichier qui ne vient
# jamais et le script pend. Mesuré : un pas de quatre minutes qui en a duré
# plus de vingt. Une redirection vers un fichier n'attend personne.
#
# **Et une laisse.** Ce pas dure cinq à onze minutes selon le coureur ; il lui
# est arrivé d'en durer vingt-six sans rien produire, et un job qui pend ne
# rend aucune information — il occupe un coureur jusqu'au délai du service,
# six heures plus tard. Vingt-cinq minutes laissent passer un coureur
# simplement lent et transforment un blocage en rouge lisible, avec le journal
# écrit jusque-là. `timeout` n'existe pas sur macOS de base, d'où le chien de
# garde en arrière-plan.
set +e
xcodebuild test \
  -project Wisq.xcodeproj \
  -scheme Wisq \
  -destination "id=${udid%% *}" \
  CODE_SIGNING_ALLOWED=NO > "$sortie" 2>&1 &
essai=$!
( sleep 1500
  kill -TERM "$essai" 2>/dev/null
  sleep 10
  kill -KILL "$essai" 2>/dev/null ) &
chien=$!
wait "$essai"
issue=$?
kill "$chien" 2>/dev/null
wait "$chien" 2>/dev/null
set -e
cat "$sortie"
if [ "$issue" -ge 128 ]; then
  echo "==> xcodebuild a été arrêté après vingt-cinq minutes (signal $((issue - 128)))." >&2
  echo "    Le journal ci-dessus est ce qu'il avait écrit avant." >&2
fi

# Ce que les sondes ont mesuré, et si elles ont seulement tourné : un test
# sauté ne mesure rien, et « vert » ne doit pas se lire « répondu ».
mesures=$(grep -E "^(WebKit|pont|Metal) [^:]*: |Executed [0-9]+ tests" "$sortie" | tail -30 || true)
if [ -n "$mesures" ]; then
  echo "==> Mesures"
  echo "$mesures"
  printf '%s\n' "$mesures" > "$mesuresFichier"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
      echo "### Ce que l'iPhone simulé a mesuré"
      echo ""
      echo '```'
      echo "$mesures"
      echo '```'
    } >> "$GITHUB_STEP_SUMMARY"
  fi
fi
[ "$issue" -eq 0 ] || exit "$issue"

echo "==> La couche application est vérifiée, pas seulement compilée."
