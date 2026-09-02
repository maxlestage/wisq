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

# CI runs this one and this script did not — the third time this file has had
# exactly that bug, after SwiftLint and after the Rust gates, both recorded
# above. It takes two seconds and it guards the one failure nobody here can
# see: an installer asking for an asset the release never built, on a machine
# nobody who works on this owns.
echo "==> Matrice des architectures (installateur ↔ release)"
./scripts/check-release-matrix.sh > /dev/null

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

# CI runs these two and this script did not, so a run could come back green on
# a branch CI would refuse — which is exactly what happened: a `cargo fmt`
# difference in a new test file, found by CI and not here. The point of this
# script is that its green means something.
echo "==> Rust formatting and lints (what CI checks first)"
cargo fmt --all --check
cargo clippy --all-targets --all-features -- -D warnings

echo "==> Building the Rust side (daemon + VM core)"
cargo build --release

# The agent ships as a static musl binary so it runs on any Linux, Alpine
# included, with nothing to install first. That is a different link than the
# host build above, and it is where a new C dependency shows up — TLS already
# brought one. Conditional on the target being installed, the same shape as
# SwiftLint below: a gate that demands a toolchain nobody has is a gate people
# stop running.
if rustup target list --installed 2>/dev/null | grep -q x86_64-unknown-linux-musl; then
  echo "==> L'agent, statique (musl), et il démarre sans environnement"
  cargo build --release --target x86_64-unknown-linux-musl -p wisq-agent
  env -i target/x86_64-unknown-linux-musl/release/wisq-agent --help > /dev/null
else
  cat <<'EOF'
==> Cible musl absente — et la CI, elle, construira l'agent statiquement.

    rustup target add x86_64-unknown-linux-musl
    puis, pour ring (la dépendance C que TLS a amenée) : musl-tools
EOF
fi

echo "==> Running the Rust tests"
cargo test --release

echo "==> Building the core (Swift 6 language mode)"
swift build

echo "==> Running the core tests"
# The cross-language protocol tests run the real daemon; without this they skip
# loudly and the seam between the two languages goes unchecked.
#
# CI also sets WISQ_LINUX_IMAGE here and this does not, and that difference was
# measured rather than assumed: it changes nothing. `LinuxBootTests` and
# `DifferentialBootTests` read the variable *or* fall back to the well-known
# path themselves, so both runs came back with the same single skip. Adding it
# would have looked like closing a hole and closed none.
WISQ_AGENT_BINARY="$PWD/target/release/wisq-agent" swift test

# The manifest tells anyone without cargo to set this, and CI builds it to check
# the sentence is worth printing. A fallback nothing compiles is a fallback that
# has already rotted — and this script did not compile it.
echo "==> Le cœur Swift, l'échappatoire que le manifeste conseille"
WISQ_SWIFT_CORE=1 swift build

# CI boots a real kernel and prints the throughput. There is no threshold — a
# shared runner cannot hold one — but the job fails outright when the guest
# stops reaching its prompt, and that failure belongs here too. Conditional on
# the image, like CI's own step: absent, it says so rather than failing.
if [ -f "${WISQ_LINUX_IMAGE:-/tmp/wisq-test-linux-image/Image}" ]; then
  echo "==> Banc : démarrage jusqu'à l'invite"
  WISQ_LINUX_IMAGE="${WISQ_LINUX_IMAGE:-/tmp/wisq-test-linux-image/Image}" \
    swift run -c release wisq-bench
else
  echo "==> Image Linux absente : banc ignoré (la CI, elle, la télécharge)"
fi

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

  # The build Heroku actually runs, from the repository root and through the
  # root package.json — a different entry point from the one above, and
  # nothing else here would notice if it broke. Twice, because the two
  # configurations are different code paths and the deployment uses the first:
  # without SITE_URL the build stamps the sentinel the server rewrites per
  # request; with it, the address is pinned and no sentinel is left.
  # The pinned build FIRST and the per-request build LAST, and the order is a
  # measured landmine, not a style choice: each of these rewrites `site/dist`,
  # and the suite above reads it. Ending on the pinned build left the tree
  # stamped with wisq.example, and the next `bun test` on that tree failed its
  # eleven request-origin cases — a red that had nothing to do with anything
  # the contributor changed. Ending on the sentinel build leaves `dist` exactly
  # as the suite tested it.
  echo "==> La construction que Heroku lancera, adresse épinglée"
  SITE_URL=https://wisq.example/ npm run heroku-postbuild > /dev/null
  echo "==> La même, adresse résolue par requête — en dernier : elle laisse dist dans l'état testé"
  npm run heroku-postbuild > /dev/null
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
  "$(dirname "$0")/build-app-icon.sh"
  xcodegen generate

  echo "==> Building the iOS app for the simulator"
  xcodebuild build \
    -project Wisq.xcodeproj \
    -scheme Wisq \
    -destination 'generic/platform=iOS Simulator' \
    CODE_SIGNING_ALLOWED=NO
fi

echo "==> OK"
