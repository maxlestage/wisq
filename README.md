# wisq

[![CI](https://github.com/maxlestage/wisq/actions/workflows/ci.yml/badge.svg)](https://github.com/maxlestage/wisq/actions/workflows/ci.yml)
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
  a real Linux kernel **on the phone** in well under a second, shell
  included, fully offline. Interpretation needs no JIT, which keeps it
  clean under App Store rules (precedent: iSH).

| | UTM SE (App Store) | wisq |
|---|---|---|
| Execution | local QEMU, interpreted | on the host — or a purpose-built local interpreter |
| Speed | very slow (no JIT on iOS) | network-bound (remote), ~0.3 s to a Linux login prompt (local, see below) |
| App Store | grey area, rule 4.7 | network client + interpreter, both clean |
| License | GPL (QEMU) | no QEMU inside, so no copyleft to carry |

## Speed

The local machine is an interpreter, and it is meant to be a fast one. Boot a
real kernel and measure it yourself:

```sh
swift run -c release wisq-bench --image /path/to/Image
```

On the x86_64 Linux container this was developed on, that is around **160
million guest instructions a second**: the `buildroot login:` prompt arrives
after 44.6 M instructions in about 0.27 s, with guest RAM obtained in under
0.1 ms. CI runs the same benchmark on every change and prints its own figure,
so a regression shows up in the log.

Read those numbers for what they are. They come from a Linux container, not
from a phone — no iPhone has been in this loop, and an A-series core is a
different machine. What carries over is the shape: the same code path runs on
the phone, there is no JIT anywhere in it, and nothing about it needs a
jailbreak or a special entitlement.

## Status

Everything below is implemented, tested (1312 tests across Swift and Rust) and
green in CI, which among other things **boots a real Linux kernel inside the
emulator** as a test. The package builds in the **Swift 6 language mode** with
no warnings. The agent speaks TLS by default: a self-signed certificate whose
SHA-256 fingerprint travels in the pairing link, pinned by the app — no CA to
operate, and `--no-tls` for tunnels that already encrypt.

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
| Agent TLS | done |
| Power a remote VM off from the phone: polite ACPI, then the cord if the guest never answers | done |
| SPICE: send a file from the phone into the guest (agent channel) | done |
| Local machine suspended and resumed as a snapshot — the shell comes back where it was | done |
| Rust VM core by default, compared instruction for instruction with the Swift one in CI | done |
| SPICE: link, main/display/inputs/cursor channels, `.vv` import | done |
| SPICE codecs: LZ, GLZ (with its window), QUIC, LZ4, JPEG, palette forms | done |
| SPICE: clipboard, sound both ways, draw operations, video streams, three caches | done |
| RDP | roadmap |

## Building

```sh
cargo test                   # the Rust side: daemon and VM core
./scripts/verify.sh          # core: strict-concurrency build + full tests
./scripts/verify.sh --app    # + the iOS app (macOS with Xcode)
./scripts/test-rust-core.sh  # both interpreters, on the same kernel, compared
./scripts/test-app.sh        # the app layer, in a simulated iPhone (macOS)
```

`verify.sh` lints first: SwiftLint where it is installed, and
`scripts/check-whitespace.sh` — the text-level rules, reimplemented — always,
because SwiftLint is a Homebrew formula and the Linux side cannot run it.

`verify.sh` builds the Rust agent first, because the cross-language
protocol tests run the real daemon against the app's own client.

The rv32ima interpreter exists twice — once in Swift, once in Rust — and
`test-rust-core.sh` is what keeps the two honest: it boots the same kernel
through both and compares the instructions retired and the console bytes at
every checkpoint. The Rust one is about 8 % faster over a full boot, so it is
the default and the one the app ships with; that means `cargo build --release
-p wisq-vm` has to have run before `swift build`, and on macOS
`scripts/build-xcframework.sh` before the app. Without cargo at all, set
`WISQ_SWIFT_CORE=1` for the Swift interpreter — the manifest stops with that
instruction rather than picking a core for you, because which one ships must
not depend on what happened to be installed.

`test-app.sh` is the answer to a layer that was, for a while, written off as
untestable: `WisqUI` is `#if os(iOS)`, so no Linux runner ever compiles it — and
two defects in the suspend/resume wiring reached a pull request while that was
the story. It needs an iOS runtime, and CI has one, so the real view model is
driven against the real interpreter inside a booted simulator on every change.

The core (protocols, emulator, agent) is Foundation-only and builds on
Linux with Swift 6.3; on Debian/Ubuntu you need `zlib1g-dev` (the official
Swift Docker image has it). The app project is generated: `brew install xcodegen &&
xcodegen generate`.

## Layout

```
Sources/WisqCore     domain model, persistence, Keychain, HID table, pairing codec
Sources/WisqNet      byte transport: TCP/TLS, persistent zlib streams, test pipes
Sources/WisqRemote   RFB/VNC and SPICE clients, reconnection, agent client, RDP slot
Sources/WisqVM       local Linux: interpreted rv32ima core, 64 MB machine, UART
Sources/WisqUI       SwiftUI, phone-first
crates/wisq-agent    host daemon (Rust): HTTP/1.1 server, virsh + demo backends
crates/wisq-vm       rv32ima interpreter (Rust) with a C ABI for the app
site/                the project site: React 19 on Bun, pre-rendered, an installable PWA
docs/                architecture, agent wire protocol, roadmap
```

Two languages, split by what each part actually is. Swift holds the app,
the UI and the remote-desktop client — Apple-shaped work on
Network.framework. Rust holds the parts that are neither: a daemon with no
interface, and an interpreter that is pure computation over a byte array.
Neither has a reason to carry a language runtime, and the daemon's download
went from 58 MB to 1.7 MB by not carrying one.

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

Heroku serves it, and builds it itself from `master` through its GitHub
integration: `Procfile`, `package.json` and `scripts/heroku-build.sh` at the
repository root, and nothing to configure: the server puts the address each
request arrived on into the canonical links, the sitemap and `robots.txt`, so a
deployment does not have to be told its own name. `SITE_URL` still pins the
address when that is wanted — behind a custom domain, say.
`.github/workflows/site.yml` no longer publishes; it typechecks, builds and
tests the site, and exercises the Heroku build path on the same commit, with and
without `SITE_URL`.

## Contributing & security

See [CONTRIBUTING.md](CONTRIBUTING.md) and [SECURITY.md](SECURITY.md).

**No licence has been chosen yet**, so no rights are granted: this is
source-available to read, not to reuse. See [NOTICE](NOTICE) for provenance —
the emulator reimplements mini-rv32ima's semantics (MIT) and the touch design
studies UTM (Apache-2.0); no third-party code is vendored, so nothing here
carries someone else's terms.

## Author

Designed and developed by [Maxime Nathan Lestage](https://github.com/maxlestage).
Copyright 2026 Maxime Nathan Lestage. All rights reserved.
