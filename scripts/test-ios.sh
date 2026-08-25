#!/usr/bin/env bash
#
# Boots a real Linux kernel through the Rust core, inside an iPhone.
#
# Every other check on the Apple side proves the code compiles for iOS. That
# is not the question. The question is whether the interpreter — the one that
# is measurably faster than the Swift core — actually runs on the device the
# app ships to, and this answers it by running the C ABI conformance program
# inside a booted simulator rather than on the host.
#
# `simctl spawn` runs the binary with the simulator's runtime and the host's
# filesystem, so the kernel image is reached by its host path.
#
# It also prints the interpreter's throughput, which is the only figure this
# repository has from the Apple toolchain — `wisq-bench` runs on the Linux job
# and measures a Linux build. Read it as an upper bound and a regression
# detector, not as a phone number: a simulator on Apple Silicon is the same
# architecture with no thermal ceiling and no memory pressure, and a shared
# runner's figure moves between runs. There is deliberately no threshold; a
# change that halves it is meant to be visible in the log, and a guest that
# stops reaching its banner fails the job outright.
#
#   scripts/test-ios.sh [kernel-image]
#
# Needs: macOS, Xcode with an iOS simulator runtime, and WISQ_LINUX_IMAGE or
# an image path argument.

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
image="${1:-${WISQ_LINUX_IMAGE:-}}"

if ! command -v xcrun > /dev/null; then
  echo "xcrun introuvable : ce script demande macOS et les outils Xcode." >&2
  exit 2
fi
if [ -z "$image" ] || [ ! -f "$image" ]; then
  echo "image de noyau absente : passez un chemin ou définissez WISQ_LINUX_IMAGE." >&2
  exit 2
fi

# The simulator runs the runner's own architecture: an arm64 slice on Apple
# Silicon, x86_64 on Intel. Picking the wrong one fails at spawn with a
# message that does not mention architecture, so it is chosen explicitly.
case "$(uname -m)" in
  arm64)  target="aarch64-apple-ios-sim"; clang_target="arm64-apple-ios17.0-simulator" ;;
  x86_64) target="x86_64-apple-ios";      clang_target="x86_64-apple-ios17.0-simulator" ;;
  *) echo "architecture hôte non gérée : $(uname -m)" >&2; exit 2 ;;
esac

echo "==> Cœur Rust pour $target"
rustup target add "$target" > /dev/null
cargo build --release --target "$target" -p wisq-vm

echo "==> Programme de conformité pour le simulateur"
binary="$(mktemp -d)/wisq-abi-ios"
xcrun --sdk iphonesimulator clang \
  -target "$clang_target" \
  -isysroot "$(xcrun --sdk iphonesimulator --show-sdk-path)" \
  -O2 -Wall -Wextra \
  -I "$root/crates/wisq-vm/include" \
  "$root/crates/wisq-vm/tests/abi/main.c" \
  -L "$root/target/$target/release" -lwisq_vm \
  -o "$binary"

# An iPhone, whichever the runner image ships. Named devices come and go
# between Xcode releases, so the newest available iPhone is taken rather
# than a model pinned here that a future image will not have.
device="$(xcrun simctl list devices available --json \
  | python3 -c '
import json, sys
devices = json.load(sys.stdin)["devices"]
found = [d for runtime in devices for d in devices[runtime]
         if d.get("isAvailable") and d["name"].startswith("iPhone")]
if not found:
    sys.exit("aucun iPhone disponible dans ce runtime")
print(found[-1]["udid"])
')"
echo "==> Simulateur $device"

xcrun simctl boot "$device" 2> /dev/null || true
xcrun simctl bootstatus "$device" -b > /dev/null

echo "==> Démarrage d'un vrai noyau Linux, dans l'iPhone"
if xcrun simctl spawn "$device" "$binary" "$image"; then
  status=0
  echo "==> Le cœur Rust démarre Linux sur iOS. Le débit ci-dessus vient du"
  echo "    simulateur : une borne haute, pas la vitesse d'un téléphone."
else
  status=$?
  echo "==> Échec dans le simulateur (code $status)." >&2
fi

xcrun simctl shutdown "$device" > /dev/null 2>&1 || true
exit "$status"
