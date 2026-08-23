#!/usr/bin/env bash
#
# Packages the Rust VM core as WisqVMCore.xcframework.
#
# The switch from the Swift interpreter to the Rust one has been waiting on
# "work that has to be done on a Mac". That was never quite true: it is work
# that has to be done on macOS, and CI has macOS. This is that work, written
# so it runs identically on a runner and on a laptop.
#
# An XCFramework rather than a bare .a because a static library carries no
# platform: linking an iOS slice into a simulator build fails late and
# confusingly, while an XCFramework makes Xcode pick the right one. The
# simulator and macOS slices are fat (arm64 + x86_64) so the result works on
# Apple Silicon and Intel alike.
#
#   scripts/build-xcframework.sh [output-dir]
#
# Needs: Xcode command line tools, and the Rust Apple targets (added below).

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out="${1:-$root/dist}"
staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT

if ! command -v xcodebuild > /dev/null; then
  echo "xcodebuild introuvable : ce script demande macOS et les outils Xcode." >&2
  exit 2
fi

device_target="aarch64-apple-ios"
simulator_targets=("aarch64-apple-ios-sim" "x86_64-apple-ios")
macos_targets=("aarch64-apple-darwin" "x86_64-apple-darwin")
all=("$device_target" "${simulator_targets[@]}" "${macos_targets[@]}")

echo "==> Cibles Rust"
for target in "${all[@]}"; do
  rustup target add "$target" > /dev/null
done

echo "==> Compilation du cœur pour ${#all[@]} cibles"
for target in "${all[@]}"; do
  cargo build --release --target "$target" -p wisq-vm
done

lib() { echo "$root/target/$1/release/libwisq_vm.a"; }

# The headers every slice shares. The module map is what lets Swift write
# `import WisqVMCore` instead of a bridging header the app target would own.
headers="$staging/include"
mkdir -p "$headers"
cp "$root/crates/wisq-vm/include/wisq_vm.h" "$headers/"
cat > "$headers/module.modulemap" <<'MODULE'
module WisqVMCore {
    header "wisq_vm.h"
    export *
}
MODULE

echo "==> Assemblage des tranches"
mkdir -p "$staging/ios-simulator" "$staging/macos"
lipo -create -output "$staging/ios-simulator/libwisq_vm.a" \
  "$(lib "${simulator_targets[0]}")" "$(lib "${simulator_targets[1]}")"
lipo -create -output "$staging/macos/libwisq_vm.a" \
  "$(lib "${macos_targets[0]}")" "$(lib "${macos_targets[1]}")"

rm -rf "$out/WisqVMCore.xcframework"
mkdir -p "$out"
xcodebuild -create-xcframework \
  -library "$(lib "$device_target")" -headers "$headers" \
  -library "$staging/ios-simulator/libwisq_vm.a" -headers "$headers" \
  -library "$staging/macos/libwisq_vm.a" -headers "$headers" \
  -output "$out/WisqVMCore.xcframework"

echo "==> Vérification"
# An xcframework that builds is not an xcframework that contains what it
# should: three slices, and the simulator and macOS ones fat.
slices="$(find "$out/WisqVMCore.xcframework" -name 'libwisq_vm.a' | wc -l | tr -d ' ')"
if [ "$slices" != "3" ]; then
  echo "attendu 3 tranches, trouvé $slices" >&2
  exit 1
fi
find "$out/WisqVMCore.xcframework" -name 'libwisq_vm.a' -print0 | while IFS= read -r -d '' slice; do
  printf '  %s : ' "${slice#"$out/WisqVMCore.xcframework/"}"
  lipo -archs "$slice"
done

echo "==> $out/WisqVMCore.xcframework"
