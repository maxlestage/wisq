#!/usr/bin/env bash
#
# Builds the Rust interpreter and runs the differential test against it: the
# same kernel booted through both cores, compared checkpoint by checkpoint.
#
# This exists rather than a line in a README because of a trap it has to step
# around. SwiftPM does not know that `libwisq_vm.a` is an input — the library
# arrives through a raw `-L` flag, not a dependency — so after `cargo build` it
# happily re-runs the previous test binary, still linked against the previous
# library. The test then passes against the code you just changed, without
# having seen it. Deleting the bundle is what makes the result mean something.
#
# Needs: cargo, a Swift toolchain, and WISQ_LINUX_IMAGE (or the well-known path)
# for the boot comparison; without an image the differential tests skip loudly.
set -euo pipefail

cd "$(dirname "$0")/.."

image="${WISQ_LINUX_IMAGE:-/tmp/wisq-test-linux-image/Image}"
configuration="${WISQ_TEST_CONFIGURATION:-release}"

echo "==> Construction du cœur Rust"
cargo build --release -p wisq-vm

library="target/release/libwisq_vm.a"
if [ ! -f "$library" ]; then
  echo "bibliothèque absente : $library" >&2
  exit 1
fi

# Anything linked before the library was rebuilt is stale by definition.
echo "==> Suppression des binaires de test antérieurs à la bibliothèque"
find .build -name '*.xctest' -not -newer "$library" -print -exec rm -rf {} + 2>/dev/null || true

if [ ! -f "$image" ]; then
  echo "::warning::image Linux absente ($image) : la comparaison des deux cœurs sera ignorée"
fi

# Filtered on the target, not on one class: the target grew a second suite
# (snapshot agreement between the cores) and a filter naming one class
# silently stopped covering it.
echo "==> Les deux cœurs : même noyau, mêmes instantanés"
WISQ_RUST_CORE=1 WISQ_LINUX_IMAGE="$image" \
  swift test -c "$configuration" --filter WisqVMRustTests

echo "==> Les deux interpréteurs sont d'accord."
