#!/usr/bin/env bash
#
# The installer asks for an asset by name; the release workflow produces assets
# by name. Nothing connected the two, and they drifted apart in the quiet
# direction: the workflow built `linux-x86_64` and `macos-arm64`, the installer
# asked for exactly those, and every other machine — an ARM NAS, a Raspberry
# Pi, an Intel Mac — fell silently through to `install_from_source`, which
# needs a Rust toolchain. Nobody sees that failure but the person installing.
#
# The direction that matters is the installer asking for something the workflow
# does not build, because that is a 404 mid-install. But this checks both ways,
# because the other direction is not harmless either: an asset built, uploaded
# and attached to every release that no installer will ever request is a build
# minute and a download nobody can use, and it looks like coverage.
#
# Both lists are read from the files that actually decide, rather than from a
# third list that would then need its own guard.
set -euo pipefail

cd "$(dirname "$0")/.."

workflow=.github/workflows/release.yml
installer=scripts/install.sh

# The workflow names each published asset once, as the `asset:` key of a matrix
# entry, and interpolates it into both the tarball name and the artifact name.
# Reading the matrix rather than the tarball line is deliberate: the tarball
# line is `${{ matrix.asset }}` and says nothing on its own.
built=$(grep -oE '^\s*- asset: [A-Za-z0-9_.-]+' "$workflow" | awk '{print $3}' | sort -u)

# The installer names each asset it will ask for as an ASSET_SUFFIX. The empty
# one is the deliberate fall-through to a source build, not an asset.
requested=$(grep -oE 'ASSET_SUFFIX="[A-Za-z0-9_.-]+"' "$installer" \
  | sed 's/.*="\(.*\)"/\1/' | sort -u)

if [ -z "$built" ]; then
  echo "$workflow ne déclare plus aucun asset (clé 'asset:' du matrix)" >&2
  exit 1
fi
if [ -z "$requested" ]; then
  echo "$installer ne demande plus aucun asset (ASSET_SUFFIX)" >&2
  exit 1
fi

failed=0

missing=$(comm -13 <(echo "$built") <(echo "$requested"))
if [ -n "$missing" ]; then
  echo "$installer demande des assets que $workflow ne construit pas :" >&2
  echo "$missing" | sed 's/^/  /' >&2
  failed=1
fi

unused=$(comm -23 <(echo "$built") <(echo "$requested"))
if [ -n "$unused" ]; then
  echo "$workflow publie des assets que $installer ne demande jamais :" >&2
  echo "$unused" | sed 's/^/  /' >&2
  failed=1
fi

if [ "$failed" -eq 0 ]; then
  echo "matrice des architectures cohérente :"
  echo "$built" | sed 's/^/  /'
fi

exit "$failed"
