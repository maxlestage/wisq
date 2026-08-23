# Changelog

All notable changes to wisq are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org). Until 1.0.0, minor versions may
break APIs.

## [Unreleased]

## [0.1.0] — pending first release

The scope of the initial pull request, in one line each.

### Added — remote (the VM runs on a host, the iPhone is the client)
- Hand-written RFB 3.8 (VNC) client: handshake, VNC/DES authentication,
  Raw / CopyRect / RRE / Hextile / zlib / ZRLE / Tight (JPEG included)
  encodings over session-lived zlib streams, desktop resize, clipboard.
- Continuous updates (no per-frame polling) and server-side cursor images
  drawn locally.
- Automatic reconnection through network drops: exponential backoff, fresh
  zlib streams per attempt, never retries an authentication failure.
- Phone-first touch model: configurable gestures with inertia, virtual
  cursor on its own layer, 50 ms press/release spacing, ordered input.
- Hardware and software keyboards through a single first responder;
  HID-to-X11-keysym table.
- `wisq-agent` host daemon: dependency-free POSIX HTTP server, libvirt
  (via `virsh`) and demo backends, bearer-token auth, end-to-end tested
  against the app's own client.
- Boot-before-connect: tapping a powered-off VM starts it through the
  agent and resolves the console endpoint late.
- Pairing: `wisq://` deep links printed by the daemon (QR via `qrencode`
  when present), Bonjour discovery, one stored token per agent host.

### Added — local (Linux on the phone itself)
- `WisqVM`: an interpreted rv32ima machine (Swift port of the mini-rv32ima
  semantics) that boots a real Linux 6.1 nommu kernel to a shell in
  seconds, App Store-clean because interpretation needs no JIT.
- Line-oriented terminal view with ANSI filtering; kernel images imported
  through the Files app.
- CI boots the real kernel and reads its banner as a test.

### Added — installation
- One-line installer for the agent (`scripts/install.sh`): release binary
  per platform with source-build fallback, optional launchd/systemd
  service.
- Homebrew formula served from this repository as a tap, `brew services`
  support included.
- Releases attach an unsigned IPA for AltStore/Sideloadly sideloading;
  `scripts/install-ios.sh` builds and installs straight onto a connected
  iPhone with Xcode.

### Security
- Secrets live in the Keychain, never in the machine library JSON.
- The agent v1 speaks plain HTTP behind a mandatory bearer token: trusted
  network or tunnel only, exactly like unencrypted VNC. TLS is tracked in
  the roadmap.
