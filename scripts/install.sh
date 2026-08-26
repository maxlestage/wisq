#!/bin/sh
# wisq-agent installer — the daemon that lets wisq on iPhone power VMs on.
#
#   curl -fsSL https://raw.githubusercontent.com/maxlestage/wisq/master/scripts/install.sh | sh
#
# Options (pass after `sh -s --` when piping):
#   --version vX.Y.Z   install a specific release (default: latest)
#   --prefix DIR       install directory (default: /usr/local/bin, else ~/.local/bin)
#   --from-source      build with the local Rust toolchain instead of downloading
#   --service          also install and start a launchd (macOS) / systemd user
#                      (Linux) service
#
# POSIX sh, no bashisms: this runs on stock macOS and minimal Linux alike.
set -eu

REPO="${WISQ_REPO:-https://github.com/maxlestage/wisq.git}"
RELEASES="${WISQ_RELEASES:-https://github.com/maxlestage/wisq/releases}"
VERSION="latest"
PREFIX=""
FROM_SOURCE=0
SERVICE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --version) VERSION="$2"; shift 2 ;;
    --prefix) PREFIX="$2"; shift 2 ;;
    --from-source) FROM_SOURCE=1; shift ;;
    --service) SERVICE=1; shift ;;
    -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
    *) echo "argument inconnu : $1" >&2; exit 2 ;;
  esac
done

fail() { echo "wisq-install: $*" >&2; exit 1; }

# --- where to install ---------------------------------------------------------
if [ -z "$PREFIX" ]; then
  if [ -w /usr/local/bin ] 2>/dev/null; then
    PREFIX=/usr/local/bin
  else
    PREFIX="$HOME/.local/bin"
  fi
fi
mkdir -p "$PREFIX"

# --- what platform this is ----------------------------------------------------
OS="$(uname -s)"
ARCH="$(uname -m)"
# The four names here are the four assets the release workflow publishes, and
# scripts/check-release-matrix.sh fails the build when the two lists stop
# agreeing. They diverged once already: the workflow built x86_64 Linux and
# arm64 macOS, this table asked for exactly those, and everyone else — an ARM
# NAS, a Raspberry Pi, an Intel Mac — fell through to the source build, which
# needs a Rust toolchain the machine has no reason to carry.
#
# `uname -m` on 64-bit ARM Linux says `aarch64` on most distributions and
# `arm64` on a few; both are the same binary.
case "$OS/$ARCH" in
  Darwin/arm64) ASSET_SUFFIX="macos-arm64" ;;
  Darwin/x86_64) ASSET_SUFFIX="macos-x86_64" ;;
  Linux/x86_64) ASSET_SUFFIX="linux-x86_64" ;;
  Linux/aarch64|Linux/arm64) ASSET_SUFFIX="linux-aarch64" ;;
  *) ASSET_SUFFIX="" ;;   # no prebuilt binary: source build below
esac

install_binary() {
  # Resolve "latest" through the GitHub redirect so the asset URL is concrete.
  if [ "$VERSION" = "latest" ]; then
    VERSION="$(curl -fsSLI -o /dev/null -w '%{url_effective}' "$RELEASES/latest" | sed 's|.*/||')"
    case "$VERSION" in v*) ;; *) return 1 ;; esac
  fi
  URL="$RELEASES/download/$VERSION/wisq-agent-$VERSION-$ASSET_SUFFIX.tar.gz"
  echo "téléchargement de $URL"
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  curl -fsSL "$URL" -o "$TMP/agent.tar.gz" || return 1
  tar -C "$TMP" -xzf "$TMP/agent.tar.gz"
  # Run it before installing it. A downloaded binary can be the wrong libc,
  # the wrong architecture, or miss a shared library the machine never had;
  # every one of those looks like a successful install and fails on first
  # use. Failing here instead falls back to the source build below.
  "$TMP/wisq-agent" --help >/dev/null 2>&1 || return 1
  install -m 755 "$TMP/wisq-agent" "$PREFIX/wisq-agent"
}

install_from_source() {
  command -v cargo >/dev/null || fail "aucun binaire pour $OS/$ARCH et pas de toolchain Rust : installez Rust (rustup.rs) puis relancez"
  command -v git >/dev/null || fail "git est requis pour construire depuis les sources"
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  echo "construction depuis les sources ($REPO)…"
  git clone --depth 1 "$REPO" "$TMP/wisq" >/dev/null 2>&1 || fail "clonage impossible : $REPO"
  (cd "$TMP/wisq" && cargo build --release -p wisq-agent >/dev/null)
  install -m 755 "$TMP/wisq/target/release/wisq-agent" "$PREFIX/wisq-agent"
}

if [ "$FROM_SOURCE" = 1 ] || [ -z "$ASSET_SUFFIX" ]; then
  install_from_source
else
  install_binary || {
    echo "binaire publié indisponible ou inutilisable ici : repli sur la construction depuis les sources"
    install_from_source
  }
fi

echo "installé : $PREFIX/wisq-agent"
case ":$PATH:" in
  *:"$PREFIX":*) ;;
  *) echo "note : ajoutez $PREFIX à votre PATH" ;;
esac

# --- optional service ---------------------------------------------------------
if [ "$SERVICE" = 1 ]; then
  case "$OS" in
    Darwin)
      PLIST="$HOME/Library/LaunchAgents/app.wisq.agent.plist"
      mkdir -p "$HOME/Library/LaunchAgents"
      cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>app.wisq.agent</string>
  <key>ProgramArguments</key><array><string>$PREFIX/wisq-agent</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/wisq-agent.log</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/wisq-agent.log</string>
</dict></plist>
PLIST_EOF
      launchctl unload "$PLIST" 2>/dev/null || true
      launchctl load "$PLIST"
      echo "service launchd chargé ; journal : ~/Library/Logs/wisq-agent.log"
      echo "le jeton d'appairage s'y trouve : tail ~/Library/Logs/wisq-agent.log"
      ;;
    Linux)
      UNIT_DIR="$HOME/.config/systemd/user"
      mkdir -p "$UNIT_DIR"
      cat > "$UNIT_DIR/wisq-agent.service" <<UNIT_EOF
[Unit]
Description=wisq host agent

[Service]
ExecStart=$PREFIX/wisq-agent
Restart=on-failure

[Install]
WantedBy=default.target
UNIT_EOF
      if command -v systemctl >/dev/null; then
        systemctl --user daemon-reload
        systemctl --user enable --now wisq-agent
        echo "service systemd (utilisateur) démarré ; jeton : journalctl --user -u wisq-agent"
      else
        echo "unité écrite dans $UNIT_DIR/wisq-agent.service (systemctl introuvable, non démarrée)"
      fi
      ;;
  esac
fi
