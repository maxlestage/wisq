# Changelog

All notable changes to wisq are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org). Until 1.0.0, minor versions may
break APIs.

## [Unreleased]

### Added
- **The local machine can be saved and brought back.** `Machine::snapshot`
  writes RAM, the hart's registers and the keystrokes still queued for the
  UART; `restore` puts them back. The guest is not consulted and
  does not need to be, which is the whole point — the obvious approach, a
  virtio-blk disk, has nobody to talk to: the reference rv32 nommu kernel ships
  the virtio-mmio transport but no block driver, and its entire filesystem list
  is devtmpfs, proc, ramfs and sysfs. Saving underneath the kernel works with
  any image the user imports, needs no driver, and cannot corrupt a filesystem
  on a hard kill.

  Runs of zeros are folded, because a phone has to write this every time the
  app goes to the background: a booted machine saves in **9.2 MB** rather than
  64. A refused restore changes nothing — RAM is filled into a scratch buffer
  that only replaces the live one once the whole snapshot has been read, so a
  truncated file cannot leave a guest holding half of yesterday's memory. Every
  truncation of a valid snapshot is tested, along with a foreign buffer, a
  trailing byte and a snapshot taken at a different RAM size.

  The C ABI carries it too — `wisq_vm_snapshot`, `wisq_vm_free_snapshot` and
  `wisq_vm_restore`. The snapshot is returned as an allocation the caller owns
  rather than written into a caller's buffer, because the size-then-write dance
  would mean building a 15 MB snapshot twice. The conformance program exercises
  the round trip from C, where the app will call it: save, restore into a
  second machine, require the retired counts to agree, and require a buffer of
  rubbish to be refused by name. Proven to bite by swapping two parameters in
  the header and watching the compile fail.

  The test that matters does not check that the machine boots afterwards — a
  snapshot missing a register does that too, then diverges where nobody is
  looking. It runs a machine, saves it, carries the original on, restores the
  copy and runs it the same distance, and requires the two futures to be
  identical: same instructions retired, same console bytes. Verified by
  dropping a single timer register from the format and watching it fail. A
  compile-time assertion on the size of `Core` means a new register cannot be
  added without the format being updated.

- **The app itself says who made it.** `NSHumanReadableCopyright` was missing
  from the bundle, so the one place a person holding the app could read the
  author's name did not have it.

### Fixed
- **The shipped app reported version 0.1.0.** `Info.plist` hard-coded it while
  `project.yml` carried `MARKETING_VERSION` — two sources for one number, and
  the number had already drifted through two releases. The plist now reads the
  build setting, so there is one place to change and nothing to keep in sync.

### Removed
- **The site no longer explains how to install wisq, and neither does the
  repository.** The README's install and try-it sections are gone in both
  languages: the sideload instructions, the one-line agent installer, the
  Homebrew tap and the commands for running a VNC server to point it at.

- **The site is one page now.** The guide, the agent protocol reference, the
  architecture note, the questions, the roadmap and the release history are
  gone, along with the install tabs, every command, the pairing walkthrough
  and the download link. What is left says what wisq is — what it does, why
  not UTM, what is tested — and nothing about how to run it. Twenty
  pre-rendered pages became eight (home, privacy, an offline fallback and a
  404, in two languages), and the sitemap now lists two addresses.

  The tests that asserted the removed pages existed were rewritten rather than
  deleted, because the point they made has inverted: one now renders every
  page in both languages and fails if an install command, a clone line, a
  download link or a pairing section reappears anywhere. Two tests about the
  releases page were dropped outright, with the reason recorded in their
  place — the claim they protected, that the version the site shows matches
  the changelog, is still checked against the built footer.

## [0.3.0] — 2026-08-24

### Removed
- **The site no longer calls wisq open source, or points anyone at its
  sources.** It was not accurate, and the repository is not something to open
  on a website's schedule. Gone: the "open source" badge, the Source link in
  the header and the footer, and the footer links that browsed the repository
  or invited contributions. The changelog moved to the releases page the site
  already serves, and the licence is stated as text instead of a link into the
  tree. A test on the built pages now fails if an "open source" claim or a
  source link comes back, because copy decisions do not survive on good
  intentions. The release download stays — it is how someone installs the
  thing, not an invitation to read the code.

### Changed
- **Everything is Rust now except the phone app, which is hybrid.** The Rust
  interpreter is the default and the one the app ships with:
  about +8 % over a full boot, and held to the Swift core instruction for
  instruction by the differential test, which is what turns a preference into
  a measurement. The price is a second toolchain — `cargo build --release -p
  wisq-vm`, plus `scripts/build-xcframework.sh` for the app — and
  `WISQ_SWIFT_CORE=1` buys back the old behaviour for someone who has Swift
  and nothing else. When the library is missing the manifest stops and prints
  the command to run: falling back quietly would make which interpreter ships
  depend on whether the build machine happened to have cargo, and a release
  cut on such a machine would carry the slower core with nothing to show for
  it. CI builds both ways on both platforms, so the fallback cannot rot
  unnoticed.

### Fixed
- **The Rust core handed the guest a clock that ran behind its own machine.**
  The borrow checker forces the devices to be built apart from the CPU, and the
  bus was built with the timer as it stood *before* the step advanced it. CLINT
  `mtime` reads therefore answered with the previous slice's time — and, worse,
  with the pre-sleep time whenever the hart had just been jumped forward out of
  wait-for-interrupt, which is a jump of the entire idle period rather than of
  64 µs. Kernel log timestamps were visibly wrong against the Swift core.
  `Bus::set_time` now hands the devices the live clock once per step. Found by
  the differential test below on the day it was written, which is the whole
  argument for having written it.

### Added
- **The app can run on the Rust core.** `LocalVMModel` no longer names an
  interpreter: it uses `LocalMachine`, an alias `WISQ_RUST_CORE` points at
  either one. Only the CPU is swapped — the console stays `TerminalGrid`,
  which was never the part worth rewriting. The manifest works out for itself
  how the library arrives, because a bare `.a` carries no platform and linking
  an iOS slice into a simulator build fails late and confusingly: find
  `dist/CWisqVM.xcframework` and it is linked as a binary target with Xcode
  picking the slice, otherwise the plain archive through a `-L`. Both vend a
  module named `CWisqVM`, so the wrapper is one source either way. CI builds
  the app both ways, so neither path can rot unnoticed.
- **Both interpreters are made to prove they agree.** wisq has an rv32ima core
  written twice, and the Rust one is the one the app now runs — which means
  nobody exercises the Swift one any more and a divergence between them stops
  being noticed. `WisqVMRust` wires the Rust core into the Swift package with
  the same public surface as `LinuxMachine` method for method, and a test
  boots the same kernel through
  both and compares them every million instructions: the same count retired,
  the same console bytes. Not "roughly the same output" — the same bytes.
  `scripts/test-rust-core.sh` runs the comparison in one
  command, and deletes any test bundle older than the library first — SwiftPM
  does not know a `-L` archive is an input, so without that the suite happily
  re-runs the previous binary against the previous library and passes without
  having seen the change. That trap cost a false green here before it was
  closed.
- **The Rust core is packaged for Apple, and proven on an iPhone.**
  `scripts/build-xcframework.sh` assembles `CWisqVM.xcframework` — the
  device slice, plus universal simulator and macOS slices — and checks the
  result contains three slices rather than trusting that `xcodebuild`
  succeeded. `scripts/test-ios.sh` boots a real Linux kernel through the C
  ABI *inside a booted iPhone simulator* via `simctl spawn`. Both run in the
  "App iOS" CI job. The question the Rust switch rested on was never "does it
  compile for iOS" — every other check answered that — but "does the
  interpreter run on the device the app ships to", and that now has an answer
  on every commit.
- `crates/wisq-vm/include/wisq_vm.h`, the C ABI as C sees it, with a test that
  compiles it against the real static library and boots a kernel through it.
  A hand-written header is a promise nothing enforces: a signature that drifts
  from `src/ffi.rs` is not a Rust error, not a Swift error, and not a crash
  until memory is already wrong — on a phone. The test was checked by breaking
  the header on purpose and watching it fail.
- **The agent speaks TLS, and the pairing link is the certificate story.** On
  first run the daemon signs itself an ECDSA P-256 certificate and keeps it
  beside its token; the certificate's SHA-256 fingerprint travels in the
  `wisq://` link as `fp=`, and the app pins exactly that certificate — no
  authority to run, no chain, no name checks, because nobody installing a
  daemon on a NAS with one curl line will also operate a CA. The certificate
  never rotates on its own (old links must keep working; deleting the
  `tls-*.der` files is the rotation) and barely expires (year 9999 — under
  pinning, expiry could only strand a phone against a healthy daemon).
  `--no-tls` keeps plain HTTP for pre-0.3 clients and for tunnels that already
  encrypt; a link without `fp=` means plain HTTP, and a malformed fingerprint
  is a parse error, never a silent downgrade. The dependency budget of the
  agent is spent on exactly this and nothing else: rustls and rcgen, both from
  the rustls project, on the ring provider.
- **The local console is a terminal now** (`TerminalGrid`, replacing
  `ConsoleBuffer`). The old console stripped escape sequences and replayed
  carriage returns — readable for a boot log, and not a terminal: an editor,
  a pager or `top` addresses cells, clears regions, scrolls a window and
  repaints in place, and a view with no cells shows repaints as a growing
  smear. The grid implements the dialect Linux console programs actually
  emit: cursor addressing, erases, insert/delete of lines and characters,
  the scroll region, the alternate screen (quitting an editor gives the
  shell back instead of dumping the last frame into the log), save/restore
  cursor, and SGR attributes recorded per cell for a renderer to use.
  Deferred wrap is honoured — writing column 80 does not move the cursor
  until the next character — because without it every full-width repaint
  walks the screen down by one line. Scrollback is what leaves the top of
  the main screen, bounded, and the alternate screen never feeds it. 32
  tests, including the boot-log behaviours the old console's tests held.
- A plain-HTTP client against the TLS port gets an immediate
  `426 Upgrade Required` explaining what to do — https, re-pair, or
  `--no-tls` — instead of a stalled connection. rustls reads `GET /` as a TLS
  record header announcing kilobytes that never arrive; one peeked byte
  settles it, because every TLS session opens with 0x16 and no HTTP method
  does.

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
- The footer carries the mark too, small, beside its wordmark — so the pair a
  reader learns on the landing page is what they see on every other page.
- The landing page's mark is now a **lockup**: the name set large — larger
  than the drawing — with the mark beside it. The mark alone says what the product does and not what it is
  called; the two together are what a reader recognises later. The name is real
  text rather than part of the drawing, so it is selectable, searchable and
  read aloud.
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
- Generating a token on first run read `/dev/urandom` to end-of-file — an end
  that never comes on a random device. The daemon grew a buffer until
  allocation failed before its fallback path could run; masked for two
  releases because every test passes `--token`. It now reads exactly the 32
  bytes it needs.
- A transport-level failure in the agent — a vanished socket, a failed TLS
  handshake — is now closed without an HTTP answer instead of being answered
  with a 400. Writing a response into a failed handshake makes rustls try to
  continue that handshake against a client that is itself blocked reading: a
  deadlock, one leaked thread per outdated client. Connection sockets also
  carry 20 s deadlines, so no client can park a thread forever.
- The hero split into two columns at 40em, which left the text 103 px and the
  headline five lines anywhere between 640 and 900 px — a layout that reads
  correctly at 1280 px and is broken in a range nobody thinks to open. It now
  splits at 60em, once both halves fit. Found by measuring twelve widths rather
  than the two that get looked at.
- The hero overflowed horizontally at 320 px. Both halves of the lockup are now
  sized against the viewport rather than fixed.
- The mark's SVG gradients used fixed ids, so drawing it twice on one page —
  the hero and the footer — produced duplicate ids. Harmless while both copies
  are identical, and a silent wrong-colour bug the day they are not. Each
  instance now derives its own, and a test counts them.
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
