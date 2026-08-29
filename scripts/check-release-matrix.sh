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
#
# **It takes a root, and that is what makes it testable.** Run with no argument
# it checks this repository, which is what CI and `verify.sh` do. Given a
# directory it checks that one instead, which is how
# `site/tests/release-matrix.test.ts` gets to watch it refuse.
#
# That test exists because of a measurement. Three separate breakages of this
# file's own logic — `expect_asset` made never to compare, both `comm` calls
# neutered, `exit "$failed"` turned into `exit 0` — each leave it **green on
# this tree**, so CI would have reported a coherent matrix while the guard was
# doing nothing. A guard only ever run against a tree with nothing wrong in it
# is a guard nobody has checked.
set -euo pipefail

cd "${1:-$(dirname "$0")/..}"

workflow=.github/workflows/release.yml
installer=scripts/install.sh

# The workflow names each published asset once, as the `asset:` key of a matrix
# entry, and interpolates it into both the tarball name and the artifact name.
# Reading the matrix rather than the tarball line is deliberate: the tarball
# line is `${{ matrix.asset }}` and says nothing on its own.
#
# `|| true` because `set -e` kills the script the moment the pipeline fails,
# and an empty match *is* a failure for grep. Without it the two "plus aucun
# asset" branches below are unreachable: the script died at this line, silently,
# with exit 1 — a refusal a reader would have to run `bash -x` to understand.
# Measured, on a workflow with every `- asset:` line deleted.
built=$(grep -oE '^\s*- asset: [A-Za-z0-9_.-]+' "$workflow" | awk '{print $3}' | sort -u || true)

# The installer names each asset it will ask for as an ASSET_SUFFIX. The empty
# one is the deliberate fall-through to a source build, not an asset.
requested=$(grep -oE 'ASSET_SUFFIX="[A-Za-z0-9_.-]+"' "$installer" \
  | sed 's/.*="\(.*\)"/\1/' | sort -u || true)

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

# --- and that each machine is sent the right one -------------------------------
#
# Comparing the two lists as *sets* leaves one mistake invisible: a mapping that
# uses a name which does exist, for the wrong machine. Write
# `Darwin/arm64) ASSET_SUFFIX="macos-x86_64"` and both lists still match
# perfectly, while every Apple silicon Mac downloads an Intel binary. The set
# check cannot see it, because nothing about the set changed.
#
# So the table is exercised rather than read: a fake `uname` on PATH, the real
# installer, and the URL it prints. `--version` is given so it never resolves
# "latest", and both WISQ_RELEASES and WISQ_REPO point nowhere, so this touches
# no network — the installer fails immediately after printing the URL, which is
# the only line being read.
expect_asset() {
  os=$1 machine=$2 want=$3
  fake=$(mktemp -d)
  mkdir -p "$fake/bin" "$fake/prefix"
  cat > "$fake/bin/uname" <<UNAME
#!/bin/sh
case "\$1" in -s) echo "$os" ;; -m) echo "$machine" ;; *) echo "$os" ;; esac
UNAME
  chmod +x "$fake/bin/uname"

  output=$(PATH="$fake/bin:$PATH" \
    WISQ_RELEASES="https://127.0.0.1:1/releases" \
    WISQ_REPO="/wisq-check-release-matrix-nonexistent" \
    sh "$installer" --version v0.0.0 --prefix "$fake/prefix" 2>&1 || true)
  got=$(printf '%s\n' "$output" \
    | sed -n 's|.*/wisq-agent-v0\.0\.0-\(.*\)\.tar\.gz.*|\1|p' | head -n 1)
  rm -rf "$fake"

  [ -n "$got" ] || got="(aucun binaire)"
  if [ "$got" != "$want" ]; then
    echo "$installer envoie $os/$machine vers '$got' au lieu de '$want'" >&2
    return 1
  fi
  printf '  %-16s -> %s\n' "$os/$machine" "$got"
}

# Each call runs in *this* shell rather than inside a `$( )`, and that is not a
# style choice. Written as `mappings=$( ... ) || failed=1`, bash suspends
# `set -e` for the whole `||` list — the subshell included — so a failing
# `expect_asset` in the middle no longer aborts it, and the substitution ends up
# reporting the status of the *last* call. The first draft of this file did
# exactly that: it printed the error and exited 0, which is the one outcome a
# guard must never have.
echo "chaque machine reçoit le bon asset :"
expect_asset Darwin arm64 macos-arm64 || failed=1
expect_asset Darwin x86_64 macos-x86_64 || failed=1
expect_asset Linux x86_64 linux-x86_64 || failed=1
expect_asset Linux aarch64 linux-aarch64 || failed=1
# Most 64-bit ARM distributions say aarch64; a few say arm64. Same binary.
expect_asset Linux arm64 linux-aarch64 || failed=1
# 32-bit ARM and everything else are deliberately not published: the source
# build is the honest answer there, not a missing asset.
expect_asset Linux armv7l "(aucun binaire)" || failed=1
expect_asset FreeBSD amd64 "(aucun binaire)" || failed=1

if [ "$failed" -eq 0 ]; then
  echo "matrice des architectures cohérente :"
  echo "$built" | sed 's/^/  /'
fi

exit "$failed"
