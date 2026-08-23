# wisq

[![CI](https://github.com/maxlestage/wisq/actions/workflows/ci.yml/badge.svg)](https://github.com/maxlestage/wisq/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)
[![Swift](https://img.shields.io/badge/swift-6.3-orange.svg)](Package.swift)
[![Bun](https://img.shields.io/badge/bun-1.4-black.svg)](site/package.json)

Virtual machines on your iPhone, both ways UTM cannot: **remote at full
speed, local within the rules**. *([Version française](README.fr.md) · [site](site/)).*

- **Remote** — the VM runs where the silicon is (a Mac, a PC, a NAS, a
  server); the iPhone is a fast client. iOS grants executable memory only
  to development-signed apps, so any on-device emulation of a desktop OS is
  interpreted and an order of magnitude slow — that is UTM SE's glass
  ceiling, and no amount of better code breaks it. Moving execution off the
  phone does.
- **Local** — an interpreted rv32ima RISC-V machine written in Swift boots
  a real Linux kernel **on the phone** in a couple of seconds, shell
  included, fully offline. Interpretation needs no JIT, which keeps it
  clean under App Store rules (precedent: iSH).

| | UTM SE (App Store) | wisq |
|---|---|---|
| Execution | local QEMU, interpreted | on the host — or a purpose-built local interpreter |
| Speed | very slow (no JIT on iOS) | network-bound (remote), ~1 s to a Linux shell (local) |
| App Store | grey area, rule 4.7 | network client + interpreter, both clean |
| License | GPL (QEMU) | Apache-2.0, all first-party code |

## Status

Everything below is implemented, tested (117 tests) and green in CI, which
among other things **boots a real Linux kernel inside the emulator** as a
test. The package builds in the **Swift 6 language mode** with no warnings. The one deliberate v1 limitation: the host agent speaks plain HTTP
behind a mandatory token — trusted network or tunnel, like unencrypted VNC.

| Component | State |
|---|---|
| RFB 3.8 client: handshake, DES auth, Raw/CopyRect/RRE/Hextile | done |
| Compressed encodings over session-lived zlib: zlib, ZRLE, Tight (+JPEG) | done |
| Continuous updates, server cursor drawn locally, desktop resize, clipboard | done |
| Automatic reconnection (exponential backoff, never on auth failures) | done |
| Touch model: configurable gestures, inertia, 50 ms press/release, ordered input | done |
| Hardware + software keyboards (HID → X11 keysyms) | done |
| `wisq-agent` daemon (libvirt via virsh + demo backend), end-to-end tested | done |
| Boot-before-connect, `wisq://` pairing (QR), Bonjour discovery | done |
| Local Linux: rv32ima emulator, real-kernel boot, terminal view | done |
| Agent TLS · SPICE · RDP | roadmap |

## Install

**iPhone** — two paths until the App Store listing exists:

- *Sideload the release IPA*: grab `wisq-vX.Y.Z-unsigned.ipa` from the
  [latest release](https://github.com/maxlestage/wisq/releases) and install
  it with [AltStore](https://altstore.io) or Sideloadly, which re-sign it
  with your own Apple ID.
- *Build straight onto your phone* (macOS + Xcode, iPhone in developer
  mode): `./scripts/install-ios.sh` generates the project, signs with your
  personal team and installs over USB. Free-team signatures expire after
  7 days; re-run to refresh.

**Mac / Linux (the host agent)** — one line:

```sh
curl -fsSL https://raw.githubusercontent.com/maxlestage/wisq/master/scripts/install.sh | sh -s -- --service
```

It grabs the release binary for your platform (or builds from source when
there is none), installs it, and `--service` keeps it running via launchd
or a systemd user unit — the pairing token lands in the service log.
Homebrew works too, served straight from this repository:

```sh
brew tap maxlestage/wisq https://github.com/maxlestage/wisq.git
brew install maxlestage/wisq/wisq-agent    # --head before the first tag
brew services start wisq-agent
```

## Try it

Any VNC server works for the remote path:

```sh
qemu-system-x86_64 -m 2048 -vnc :1 -hda disk.qcow2   # or: x11vnc -display :0
```

The agent turns "one more VNC client" into "my VMs, from my phone" — a
powered-off VM boots when you tap it:

```sh
swift run wisq-agent --demo    # two fake VMs, no hypervisor needed
swift run wisq-agent           # libvirt via virsh, port 7442
```

It prints `wisq://` pairing links (and a QR code when `qrencode` is
installed); opening one on the iPhone lands in the import screen,
pre-filled. For the local path, import an rv32ima nommu kernel image via
the Files app — ready-made ones live in the
[mini-rv32ima](https://github.com/cnlohr/mini-rv32ima) project.

## Building

```sh
./scripts/verify.sh          # core: strict-concurrency build + full tests
./scripts/verify.sh --app    # + the iOS app (macOS with Xcode)
```

The core (protocols, emulator, agent) is Foundation-only and builds on
Linux with Swift 6.3; on Debian/Ubuntu you need `zlib1g-dev` (the official
Swift Docker image has it). The app project is generated: `brew install xcodegen &&
xcodegen generate`.

## Layout

```
Sources/WisqCore     domain model, persistence, Keychain, HID table, pairing codec
Sources/WisqNet      byte transport: TCP/TLS, persistent zlib streams, test pipes
Sources/WisqRemote   RFB/VNC client, reconnection, agent client, SPICE/RDP slots
Sources/WisqVM       local Linux: interpreted rv32ima core, 64 MB machine, UART
Sources/WisqUI       SwiftUI, phone-first
Sources/WisqAgentKit host daemon: POSIX HTTP server, virsh + demo backends
Sources/wisq-agent   the daemon executable
site/                landing page: React 19 on Bun, pre-rendered, mobile-first
docs/                architecture, agent wire protocol, roadmap
```

`docs/ARCHITECTURE.md` explains the load-bearing decisions — negotiated
pixel format, session-lived zlib dictionaries, the touch model, why JPEG is
gated on a decoder — and `docs/ROADMAP.md` what comes next.

## The landing page

`site/` holds the project page — React 19 on Bun, pre-rendered at build time so
it paints before its JavaScript arrives, and mobile-first in the literal sense
(every base rule targets a phone; breakpoints only add room).

```sh
cd site && bun install && bun run dev
```

It publishes to GitHub Pages from `master` via `.github/workflows/site.yml`;
enable Pages once under Settings → Pages → Source: GitHub Actions.

## Contributing & security

See [CONTRIBUTING.md](CONTRIBUTING.md) and [SECURITY.md](SECURITY.md).
Licensed under [Apache-2.0](LICENSE); see [NOTICE](NOTICE) for provenance
(the emulator reimplements mini-rv32ima's semantics, MIT; the touch design
studies UTM, Apache-2.0 — no third-party code is vendored).
