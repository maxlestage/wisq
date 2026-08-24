#!/usr/bin/env bash
# Everything CI would run, in one command — so a contributor can get the same
# answer locally, before pushing, that the pull request will give them.
#
#   ./scripts/verify.sh          core only (works on Linux and macOS)
#   ./scripts/verify.sh --app    also builds the iOS app (macOS + Xcode required)
set -euo pipefail
cd "$(dirname "$0")/.."

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
