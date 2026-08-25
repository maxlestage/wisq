#!/usr/bin/env bash
# Everything CI would run, in one command — so a contributor can get the same
# answer locally, before pushing, that the pull request will give them.
#
#   ./scripts/verify.sh          core only (works on Linux and macOS)
#   ./scripts/verify.sh --app    also builds the iOS app (macOS + Xcode required)
set -euo pipefail
cd "$(dirname "$0")/.."

# First, because it is instant and because it is the check this script used to
# be missing: CI lints, and a script that claims to run everything CI runs has
# to lint too. A trailing blank line reached a pull request and turned it red
# while this said "everything CI would run".
echo "==> Mise en forme (les règles de texte)"
./scripts/check-whitespace.sh

# Also instant, and also a check that exists because removing something once
# was not enough: the Apache-2.0 claim was taken out of the site and survived
# in the app bundle and in the Homebrew formula.
echo "==> Licence (rien ne doit en annoncer une)"
./scripts/check-licence-claims.sh

if command -v swiftlint > /dev/null 2>&1; then
  echo "==> SwiftLint (strict, comme la CI)"
  # SwiftLint *does* run on Linux, which this script used to claim it did not.
  # What it needs is `libsourcekitdInProc.so`, which ships inside the Swift
  # toolchain and is not on the loader's path; without it the binary dies with
  # "Loading libsourcekitdInProc.so failed" rather than with a lint result.
  #
  # This is worth the six lines. The comment above said "the CI will run it",
  # and the CI did — twice, on changes that were otherwise finished, for a
  # trailing blank line and then for an `.enumerated()` whose index the closure
  # did not use. A gate a contributor cannot run locally is a gate that finds
  # things after the pull request is open.
  if [ "$(uname -s)" = "Linux" ]; then
    swift_lib="$(dirname "$(command -v swift)")/../lib"
    if [ -f "$swift_lib/libsourcekitdInProc.so" ]; then
      LD_LIBRARY_PATH="$swift_lib:${LD_LIBRARY_PATH:-}" swiftlint lint --strict
    else
      echo "    (libsourcekitdInProc.so introuvable ; SwiftLint va probablement échouer)"
      swiftlint lint --strict
    fi
  else
    swiftlint lint --strict
  fi
else
  cat <<'EOF'
==> SwiftLint absent — et la CI, elle, le fera tourner en --strict.

    macOS :  brew install swiftlint
    Linux :  binaire depuis https://github.com/realm/SwiftLint/releases
             (l'archive « swiftlint_linux.zip »), puis mis sur le PATH.
             Il lui faut libsourcekitdInProc.so, qui est dans la toolchain
             Swift ; ce script s'en occupe une fois le binaire trouvé.
EOF
fi

echo "==> Building the Rust side (daemon + VM core)"
cargo build --release

echo "==> Running the Rust tests"
cargo test --release

echo "==> Building the core (Swift 6 language mode)"
swift build

echo "==> Running the core tests"
# The cross-language protocol tests run the real daemon; without this they skip
# loudly and the seam between the two languages goes unchecked.
WISQ_AGENT_BINARY="$PWD/target/release/wisq-agent" swift test

# The rv32ima interpreter exists twice. Running only one of them in the suite
# above is how the other quietly drifts.
./scripts/test-rust-core.sh

# The site is a CI gate too, and its suite is not only about the site:
# `site/tests/claims.test.ts` reads *this repository* and fails when a figure the
# site advertises stops being true — the test count among them.
#
# This is the third time this file has learned the same lesson. It once did not
# lint, and said so in a comment; it once could not run SwiftLint on Linux, and
# said so in a longer one. Both times the cost was a pull request turning red for
# something a contributor could have seen in a second. This time it was the test
# count: a slice was pushed, then the count was updated in the commit after it,
# and the intermediate commit was red on a gate this script claimed to cover.
#
# A gate a contributor cannot run locally is a gate that finds things after the
# pull request is open.
if command -v bun > /dev/null 2>&1; then
  echo "==> Le site (build + suite, dont les chiffres annoncés)"
  (
    cd site
    # The suite reads `dist`, so the build has to have run — and has to have run
    # *after* whatever just changed in the repository.
    bun install --frozen-lockfile > /dev/null
    bun run typecheck
    bun run build > /dev/null
    bun test
  )
else
  cat <<'EOF'
==> bun absent — et la CI, elle, construira le site et lancera sa suite.

    https://bun.sh  (curl -fsSL https://bun.sh/install | bash)

    Ce qui est manqué sans lui n'est pas seulement le site : sa suite lit ce
    dépôt et échoue quand un chiffre annoncé — le nombre de tests, le nombre de
    portes CI — cesse d'être vrai.
EOF
fi

if [[ "${1:-}" == "--app" ]]; then
  if [[ "$(uname)" != "Darwin" ]]; then
    echo "--app requires macOS; the UI layer is UIKit." >&2
    exit 1
  fi
  command -v xcodegen >/dev/null || { echo "xcodegen missing: brew install xcodegen" >&2; exit 1; }

  echo "==> Generating the Xcode project"
  xcodegen generate

  echo "==> Building the iOS app for the simulator"
  xcodebuild build \
    -project Wisq.xcodeproj \
    -scheme Wisq \
    -destination 'generic/platform=iOS Simulator' \
    CODE_SIGNING_ALLOWED=NO
fi

echo "==> OK"
