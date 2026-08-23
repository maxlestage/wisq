# Changelog

All notable changes to wisq are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org). Until 1.0.0, minor versions may
break APIs.

## [Unreleased]

### Added
- The site is a **site** rather than a landing page: a guide, the agent
  protocol reference, the architecture decisions, questions answered plainly,
  a roadmap and a release history — seven pages, bilingual, each pre-rendered
  into its own address so it arrives readable and a search engine sees a real
  URL. Written pages are data against a small block model, so a missing
  translation is a type error and the two languages are checked block for
  block.
- The site is an **installable progressive web app**: a manifest, a service
  worker that precaches every page, an offline fallback, and an install
  affordance that offers a button where the browser has an API for it and the
  Share-sheet instructions on iOS, which does not. Verified by driving a real
  browser — worker active and controlling, a page read offline after one
  visit, an unknown address falling back, no console errors.
- Icons and the social card are drawn and PNG-encoded at build time
  (`site/scripts/icons.ts`) rather than committed. They are PNG because iOS
  will not put an SVG on the Home Screen.
- `bun run preview` serves the build with real content types, which is what the
  PWA needs and what `bun run dev` cannot give it.
- `sitemap.xml`, `robots.txt`, canonical links, Open Graph and Twitter cards,
  JSON-LD on the landing page only, and a 404 page that can still navigate.
- **A full footer**, on every page: the brand and the version the site was
  built from, then three groups — use it, understand it, contribute to it —
  and a bottom bar carrying the licence, the privacy page and a way back to
  the top. A footer is where a reader goes when the page did not answer their
  question, and one long row of links makes everything equally hard to find.
  A test asserts every page carries the whole thing, that each project link
  points at a file that exists in this repository, and that the version shown
  matches the newest dated section of this changelog.
- **Authorship, stated where it was missing.** `LICENSE` still carried Apache's
  unfilled `Copyright [yyyy] [name of copyright owner]` placeholder, so an
  Apache-2.0 project had no declared copyright holder at all; it now names the
  same holder `NOTICE` always did. The site footer credits the author on every
  page in both languages, with `<meta name="author">` and a `Person` in the
  landing pages' structured data; both crates declare `authors`, the site
  package declares `author` and `license`, and both READMEs gained an author
  section. A test asserts the site and the licence name the same person, so
  they cannot drift apart.
- The credit to other people's work is unchanged and now guarded: a test fails
  if any page stops naming Charles Lohr and mini-rv32ima. Saying what is mine
  must not quietly stop saying what is not.
- **A theme control**: light, dark, or whatever the system says. Three states
  rather than a toggle, because a toggle cannot express "follow my phone" — a
  reader whose device turns dark at sunset wants the site to do the same, and a
  two-way switch silently opts them out of that the first time they touch it.
  The choice is applied by a small inline script in the document head, before
  the first paint: an effect in the bundle runs after the page has painted, so
  a reader who chose light on a dark system would see a flash of dark on every
  navigation. The browser's own chrome colour follows the choice too.
- **Both languages are now published**, not merely written. Every page exists
  twice — `docs/` and `fr/docs/` — each pre-rendered in its own language, with
  its own `<html lang>`, title, description and canonical, and `hreflang`
  alternates naming its counterpart. The French copy was already complete; what
  was missing was any address that could serve it. Before this, the built HTML
  was English for everyone: a French reader's first paint was English, a shared
  link opened in the sender's language rather than the reader's, a reader with
  no JavaScript never saw French at all, and a search engine indexed half the
  site. A language a URL cannot express is a language the web cannot see.
- The language switch is two links rather than two buttons, so each language is
  an address that can be opened in a new tab, bookmarked and followed with no
  JavaScript. A French-speaking browser landing on the English home page is
  still sent to the French one — from the home page only, so a deep link
  someone deliberately shared in English is never redirected — and choosing a
  language explicitly stops that for good.
- The service worker precaches both languages and falls back to the offline
  page matching the address that failed, so losing the network does not also
  lose the language. The sitemap lists every page in both languages with
  `xhtml:link` alternates.
- **The full mark**, on the landing page, beside the wordmark the header
  carries everywhere. `▚` is the site's mark and stays the Home Screen icon
  untouched, because at 60 px anything more becomes mush; the hero has room to
  say what the two quadrants are — a window on a machine somewhere else, the
  phone in your hand, and the link between them. Drawn as inline SVG in
  `site/src/components/Logo.tsx`, so it paints in the first response and costs
  no request. The PNG icons now share its geometry rather than only its idea.
- **A privacy page** that can be checked rather than believed: no analytics, no
  cookies, no third-party requests, the two local-storage keys named, what the
  service worker keeps, what GitHub Pages sees, and the app's own plain-HTTP
  caveat stated rather than buried. Tests assert the built pages reference no
  external stylesheet, script, image or frame, and that neither the CSS nor
  the JavaScript reaches off-origin.

### Fixed
- The dark palette lived only inside a `prefers-color-scheme` media query, so
  it could not be turned off. Choosing light on a device set to dark would have
  appeared to work in one direction and silently failed in the other; the query
  now yields to an explicit choice, and a test asserts both directions.
- The service worker cached *any* navigation response, including 404s and
  500s. A mistyped link or a half-finished deploy was kept and served from the
  cache afterwards, including once the site was fine again — the asset branch
  had always checked `response.ok`, navigations never did. Found by watching
  the cache grow by one entry per unknown address while driving a browser.
- The landing page printed two of its section headings twice: an eyebrow above
  the heading repeating it word for word, which a screen reader read out twice
  and a reader read as a stutter.
- Every link and button now meets the 24 px minimum target size; the wordmark
  was a 20 px-tall link in both the header and the footer. The text stays the
  size it looks best at — the box around it is what got bigger, because the
  box is what gets tapped. Found by measuring every target in a real browser
  at 390 px and 1280 px, not by reading the stylesheet.
- Keyboard focus was invisible: the stylesheet had no `:focus-visible` rule at
  all, so anyone navigating by keyboard could not see where they were.
- The service worker precached the offline page twice. `Cache.addAll` rejects
  the whole list on a duplicate URL and leaves no worker at all, so the site
  kept working and silently stopped being installable — the failure nobody
  notices. Found by driving a browser, and now covered by a test.

### Changed
- **The host agent is Rust.** A daemon that installs on a NAS or a laptop, has
  no interface and no platform framework, had no reason to carry a language
  runtime — and statically linked against the Swift one it was a **58 MB**
  download to serve four routes. It is now **582 KB**, one static musl binary
  that runs on any Linux including Alpine, with nothing installed first. A
  hundred times smaller for the same protocol.
- The protocol is now guarded by a test that crosses both languages: the Swift
  suite launches the real Rust binary on an ephemeral port and queries it with
  the same `AgentClient` the app embeds. That is stronger than what it replaced
  — a Swift server answering a Swift client proved the wire format agreed with
  itself. The daemon's pairing links are parsed back by the app's own parser in
  the same suite.
- `Formula/wisq-agent.rb` and `scripts/install.sh` build with cargo; the
  published asset names are unchanged, so an existing install line still works.
- The token comparison is constant-time. It is a bearer credential on a network
  the daemon does not control, and a byte-at-a-time comparison leaks its prefix
  to anyone patient enough to measure.
- The generated token comes from `/dev/urandom`, and the daemon refuses to start
  rather than invent a weaker one.

### Added
- `crates/wisq-vm`: the rv32ima interpreter in Rust, with a C ABI for the app to
  link. Measured against the Swift core on the same kernel boot, same 44.6 M
  instructions: **170 MIPS against 162**. Not yet linked into the app — CI now
  cross-compiles it for `aarch64-apple-ios` on every change, which is the
  ground-truth that has to hold before that switch is worth making.
- `cargo fmt`, `clippy -D warnings` and `cargo test` are CI gates, on pull
  requests and on the release.

### Removed
- `Sources/WisqAgentKit` and the Swift `wisq-agent` executable, replaced by the
  Rust daemon. Their parsing tests moved to Rust; their end-to-end tests became
  the cross-language ones described above.

## [0.2.0] — 2026-08-23

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
