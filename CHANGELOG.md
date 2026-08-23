# Changelog

All notable changes to wisq are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org). Until 1.0.0, minor versions may
break APIs.

## [Unreleased]

### Changed
- The local Linux VM runs about **three times faster**: 55 → 163 million guest
  instructions a second, measured over a real kernel boot on the same machine.
  Boot to the login prompt went from 0.81 s to 0.27 s, for the same 44.6 M
  instructions — the semantics did not move, only the cost of running them.
  Two changes account for it:
  - the register file moved off a Swift array. `regs` was a public property of
    a class that also calls an opaque bus, so the optimiser could not prove the
    buffer survived the call and reloaded it, bounds check included, after
    every one. That alone was 2.7×.
  - immediates are sign-extended by an arithmetic shift of the instruction word
    instead of a test-and-OR, which removes a branch from the load, store,
    branch and ALU paths — 47 % of a boot is loads and stores.
- Guest RAM is mapped rather than allocated and cleared. Anonymous pages are
  zero by definition, so the 64 MB memset disappears and pages fault in as the
  guest touches them: machine construction went from 33–194 ms to under
  0.1 ms, and the app no longer commits 64 MB before the guest has used a byte.
- The emulation thread now declares `.userInitiated`. Without it the scheduler
  is free to park an interpreter on an efficiency core, which is the one thread
  in the app whose speed the user is watching.
- `ConsoleBuffer` replaces `ANSIFilter`. The old console kept every byte the
  guest ever printed and re-derived the visible text on each arrival, which is
  quadratic in the output: 2 000 lines took 36.7 s of processing against 0.22 s
  now. The new buffer applies each chunk once, keeps its escape-parser state
  between chunks — so a sequence split across two writes is finally handled —
  and bounds scrollback in lines. Console updates are also coalesced, so a
  chatty guest wakes the main actor once per render rather than once per write.
- WFI no longer creeps toward the timer deadline in 64 µs hops: the firing
  moment is already in `mtimecmp`, so the hart jumps to it. This is an
  accounting and battery fix rather than a throughput one — measured, it does
  not move the boot time.
- `LinuxMachine.run(instructionBudget:)` counts instructions the guest actually
  retired. It counted slices offered, so an idle guest could spend a whole
  budget without executing anything.

### Added
- `wisq-bench`: boots a real kernel and reports construction cost, instructions
  retired, wall time and throughput. CI runs it on every change, so a
  regression is visible in the log and a guest that stops reaching its prompt
  fails the job.

## [0.1.1] — 2026-08-23

### Fixed
- The published Linux agent is now statically linked against the Swift
  standard library. The 0.1.0 tarball was dynamically linked, so it needed
  `libswiftCore.so` on the target machine — which a host that has never
  installed a Swift toolchain does not have. Anyone downloading it got a
  binary that died on its first line. macOS ships the Swift runtime in the
  OS and was never affected.
- `scripts/install.sh` runs the downloaded binary before installing it, and
  falls back to the source build if it will not start. A wrong libc, a wrong
  architecture, or a missing shared library all used to look like a
  successful install and fail on first use.

## [0.1.0] — 2026-08-23

### Changed
- The package now builds in the **Swift 6 language mode**
  (`swift-tools-version: 6.0`), warning-free, on Swift 6.3.
- Toolchains moved to the current releases: Swift 6.3, Bun 1.4,
  TypeScript 7, React 19.2, and the current major of every GitHub Action.

### Fixed
- `InflateStream` is now genuinely thread-safe behind a lock, which makes
  `RFBStreams` properly `Sendable`. Swift 6.3 flagged the decoder being sent
  across an isolation boundary — a real finding that older compilers missed.
- A double-resume crash in `NetworkByteStream.open()`: the flag guarding the
  continuation was a captured `var` mutated from `NWConnection`'s state
  handler, which runs on Network's own queue. Two state transitions racing
  would have resumed the continuation twice, which traps. Replaced by
  `ResumeOnce`, a locked once-guard that lives outside the platform guard so
  it is compiled and race-tested on every platform.

### Scope of the initial release

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

### Added — the landing page
- `site/`: React 19 on Bun, no framework, pre-rendered at build time so the
  page paints before its JavaScript loads and still reads without it.
- Mobile-first in the literal sense: base styles target a phone, breakpoints
  only add room, tap targets clear 48 px, wide tables scroll inside their own
  box.
- Bilingual (English/French) from one typed content module; language follows
  the browser and can be switched.
- Twelve tests: server-render both languages, content integrity, built-artefact
  checks (relative asset paths, viewport, readable without JS), and claims
  checked against the repository so page statistics cannot rot.
- Publishes to GitHub Pages from `master`.

### Security
- Secrets live in the Keychain, never in the machine library JSON.
- The agent v1 speaks plain HTTP behind a mandatory bearer token: trusted
  network or tunnel only, exactly like unencrypted VNC. TLS is tracked in
  the roadmap.
