#!/usr/bin/env bash
# Everything CI would run, in one command.
#
# GitHub Actions is currently unavailable on this repository — every job dies at
# scheduling in ~3 seconds with no runner assigned, on Linux runners as well as
# macOS ones. Until that is unblocked this script is the verification story.
#
#   ./scripts/verify.sh          core only (works on Linux and macOS)
#   ./scripts/verify.sh --app    also builds the iOS app (macOS + Xcode required)
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> Building the core (Swift 6 language mode)"
swift build

echo "==> Running the core tests"
swift test

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
