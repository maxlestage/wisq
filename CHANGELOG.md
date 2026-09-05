# Changelog

All notable changes to wisq are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org). Until 1.0.0, minor versions may
break APIs.

## [Unreleased]

### Added
- **`wisq-agent bureau` : d'une image d'installation à un bureau, en une
  commande.** wisq affichait un bureau distant depuis longtemps ; ce qui
  manquait, c'était la machine à afficher. Écrire un domaine libvirt à la main
  demande de connaître le modèle de carte qui va avec son compositeur, l'ordre
  d'amorçage, le canal de l'agent invité et le mot de passe SPICE — quatre
  occasions de se tromper, dont trois donnent un écran noir sans message. La
  commande crée le disque qcow2, écrit le domaine, le définit et le démarre,
  puis affiche ce qu'il faut taper dans wisq. Le domaine amorce l'image avant
  le disque, monte l'image en lecture seule (elle n'est jamais modifiée),
  déclare la tablette USB (des coordonnées absolues, ce qu'un doigt produit),
  le son ich9 et le canal `com.redhat.spice.0` — les trois choses que wisq sait
  afficher —, et choisit son accélérateur dans `virsh capabilities` : KVM sous
  Linux, HVF sur un Mac, l'interprète sinon, en le disant. Le bureau SPICE
  porte **toujours** un mot de passe tiré de `/dev/urandom` : il écoute sur une
  adresse que le téléphone atteint, et sans mot de passe ce serait un écran et
  un clavier offerts au réseau. Le domaine engendré est validé par le schéma
  RelaxNG de libvirt lui-même — un test le confronte à `virt-xml-validate`, et
  c'est ce test, seul, qui a attrapé une balise hors de `<devices>` qu'aucune
  assertion de texte ne pouvait voir.
- **`SPICELiveDesktopTests` : le client de wisq contre un vrai serveur SPICE.**
  Le même motif que le test RDP en direct, et il manquait. Rien dans ce dépôt
  n'avait jamais montré la pile SPICE parler à autre chose qu'à elle-même : les
  tests unitaires injectent leur propre transport et leur propre chiffreur de
  ticket. Ce test ouvre de vraies sockets, s'authentifie, et vérifie que le
  bureau arrive et que des pixels le peignent. Mesuré ici contre QEMU 8 servant
  une ISO Alpine : poignée de main en 0,33 s, bureau de 1280×800, pixels reçus
  en 0,73 s.

### Fixed
- **Aucun bureau SPICE protégé par mot de passe n'était joignable.** Le ticket
  bourrait le clair à 128 octets avant RSA-OAEP-SHA1. Or 128 est la taille du
  **chiffré** — celle d'un module RSA de 1024 bits — et OAEP-SHA1 ne laisse
  passer que 128 − 2×20 − 2 = 86 octets de clair. `SecKeyCreateEncryptedData`
  refusait, le client rendait `ticketUnavailable`, et la session mourait avant
  le premier pixel. Le client de référence chiffre `strlen(passwd) + 1` octets,
  et c'est ce que wisq fait maintenant. Rien ne l'avait vu parce que rien
  n'avait jamais parlé à un serveur : le fichier qui porte la couture dit
  pourtant, en toutes lettres, qu'elle existe pour qu'un coureur Linux puisse
  passer au rouge. Il n'avait jamais couru ; il court, et il l'a trouvé du
  premier coup.

### Changed
- **The local disk is read from its file, and what the guest writes is kept
  beside it — durably, on both cores.** The virtio block device held its
  image whole in a `[UInt8]`, and that one fact ruled everything downstream:
  a size ceiling tied to the phone's memory, an import refusal for anything
  above it (the 5.8 GiB installer image someone actually brought), and the
  screen text explaining both. The device now reads through a `DiskStore`:
  the imported file is opened read-only and read in place, sector by sector,
  and every sector the guest writes goes to a sparse `writes` file plus a
  one-bit-per-sector `writes.map`, both written **before the device answers
  the guest** — so an app killed without notice loses nothing already written,
  and the imported file never changes. Suspension adds an `fsync`. The
  snapshot no longer carries the image for such a disk: it carries a
  "content lives elsewhere" mark, and the restore puts the store the app
  re-opened back under the restored registers; a snapshot with the image
  inside (yesterday's) still restores as before. The Rust core writes
  exactly the same two files (`store.rs`, with `wisq_vm_attach_disk_file`,
  `wisq_vm_flush_disk`, `wisq_vm_disk_bytes_written`), and a differential
  test has both cores run the same guest write and compares the overlays
  byte for byte. The ceiling is gone (`LocalDisk.maximumBytes` and its
  refusal); the one refusal left is a file under one sector. Deleting a
  disk from the library discards its overlay; the storage report counts the
  overlay's allocated blocks, not its apparent size. In-memory disks remain
  for tests and for snapshots already on phones.

### Fixed
- **The interrupt controller ignored its own priority rule.** A real 8259 will
  not deliver a line while one of equal or higher priority is in service —
  that is, until the handler sends its end-of-interrupt. Ours delivered
  whatever was unmasked whenever the interrupt flag was up. That is not
  decorative: a handler re-enables interrupts before it is done (Linux runs
  its softirqs that way), and without the rule the same line interrupts it
  again, on its own stack, for as long as the condition lasts. A kernel stack
  is sixteen kilobytes; what lies below it belongs to someone else. Fixing it
  exposed a second defect in the same place: Linux sends a **specific**
  end-of-interrupt (`0x60 + irq`), naming the line to retire, and we always
  retired the most urgent one — which, once the service bits mattered, would
  have left a line in service forever and starved everything below it.
- **An instruction that faults must leave no flag behind, and four of them
  did.** `XADD` writing its register before its memory was one member of a
  family; the flags are another. An instruction that reads a location,
  computes and writes it back set its flags *before* the store — and for
  `ADC`, `SBB`, `RCL` and `RCR` the carry is an **input**: when the store
  faulted on a page `fork()` had just shared, the kernel copied the page,
  replayed the instruction, and it read back the carry it had just written.
  Measured in four lines: `stc ; adcl $1,(%rbx)` on 0x10 must give 0x12 and
  gave 0x11; `sbb` gave 0x0F for 0x0E; `rcl` 0x20 for 0x21. And an
  `addl $1,(%rbx)` on 0xFFFFFFFF that faults left the flags at 0x87 instead
  of 0x02, so the frame the kernel pushes would have carried flags the
  instruction had no right to set. The fix is what the processor does: check
  **both** accesses before changing anything. `probeWrite` translates the
  write address before the instruction computes, on the eight families that
  read and write the same location — and not on `CMP` or `BT`, which write
  nothing, since checking those would fault a comparison against a read-only
  page, which no processor does.
- **`UCOMISS` with a scalar prefix was executed instead of refused.** In Swift
  a `where` written after a list of patterns guards only the last one, so
  `case 0x2E, 0x2F where !single && !doubleWide` left `f3 0f 2e` — which is
  not an instruction — going through the comparison path and setting flags. The
  condition is now written on both patterns. The neighbouring `0x2C, 0x2D` arm
  had the same shape but a guard inside its body, which does cover both: the
  redundant `where` is gone and the guard stays.

### Added
- **The PCI bus, and a disk on it.** The kernel probes ports 0xCF8/0xCFC at
  every boot and used to conclude "PCI: Fatal: No config space access function
  found" — so it answers now. It is not enough to answer: `pci_sanity_check`
  walks all thirty-two slots and demands a host bridge, a VGA card, or an
  Intel/Compaq vendor before it believes the bus, so slot zero presents the
  440FX bridge QEMU presents. Measured after: « PCI: Using configuration type
  1 », « pci 0000:00:03.0: [1af4:1001] type 00 class 0x010000 », and the
  kernel assigning our device its I/O window at 0x1000.
- **A disk for the rv32 machine, and the two things that were missing before
  it could exist.** This was written off on the roadmap, and the reasoning was
  right on the facts and wrong on the conclusion: rv32 nommu kernels do often
  lack a block driver, but wisq was offering nothing to find. The machine had
  no interrupt line a device could pull — `RV32Core` knew only the timer, bit 7
  of `mip` — and its device tree was a frozen blob patched at two byte offsets,
  where no node could grow. Both are gone: the machine external line is bit 11
  with cause `0x8000000B`, outranking the timer, waking a parked hart and
  standing the clock-jump down while a device waits; and `DeviceTree` builds
  the tree in the open, with the reference blob kept as the witness a test
  compares against node by node. The 54-character cap on the kernel command
  line went with the blob — it was never a rule of the machine, only the room
  the blob happened to have.

  The device is the one the PC machine already had, made common to both rather
  than written twice, at `0x1000_1000` — the address QEMU's `virt` board uses.
  Both cores have it, and their snapshots are compared byte for byte, the disk
  and the bytes the guest wrote into it included.

  What wisq still cannot do is put the block driver into a kernel someone
  brings. The device counts its requests, so when nothing has touched it by the
  end of a session the machine says so, instead of leaving a silent disk that
  looks exactly like a broken one.

- **A disk for the x86-64 machine: virtio over MMIO.** A PCI disk would have
  needed a PCI bus first — configuration space through ports 0xCF8/0xCFC, BARs
  to place, an interrupt table — all before the first sector. The MMIO
  transport needs no bus: the kernel takes the address and the interrupt line
  from its own command line (`virtio_mmio.device=0x200@0xd0000000:5`) and the
  driver above is the same one. The device implements version 2 of the
  transport, one queue, and read, write and get-id requests; a sector beyond
  the disk is an error, not a page of zeros, and an unknown request type is
  answered rather than met with silence, which would leave the driver waiting
  forever. It lives behind memory rather than inside it: its registers answer
  at addresses no RAM covers, which is exactly the path that used to raise
  "outside memory", so an ordinary address never meets it.
- **The x86-64 machine takes keystrokes, and the boot test holds it to an
  answer.** A console that writes without reading is a log; this one is a
  terminal. The boot test runs the guest in rounds: each round ends when the
  machine has nothing left to do, and that is when it types. By default it
  types one line into Alpine's rescue shell and requires the answer to come
  back twice — the terminal's echo, then the shell's reply. `WISQ_PC_INPUT`
  replaces the lines (separated by `;;`) for measurements that need to ask
  the guest something.

## [0.4.0] — 2026-09-04

### Added
- **A second local architecture: an x86-64 core that runs a stock Alpine
  kernel and its initramfs.** The core is held by nine hardware corpora — the
  reference is this machine's own processor, asked what it produced for the
  same bytes on the same state: arithmetic, XMM, strings, stack, branches,
  SSE2 integer, scalar float, the x87 stack and the 512-byte FXSAVE area, over
  24 000 cases. Measured on the same kernel and initramfs as QEMU: zero
  segfaults, zero non-canonical addresses, zero of 27 413 ring transitions
  returning a corrupted stack. Getting there took the defects below, each
  found by measurement rather than by reading the code.

### Fixed
- **`PUSH` decremented the stack pointer before translating the address it
  was about to write.** A page fault restarted the instruction with the
  pointer already moved, and it moved again: eight bytes lost for good. That
  is what killed `/init`.
- **`FXSAVE` wrote zeros where the sixteen XMM registers belong, and `FXRSTOR`
  never read them back.** The comment explaining why that was acceptable had
  stopped being true, and the two tests covering it required the wrong
  behaviour: they held the defect in place.
- **An instruction was fetched by translating only its first byte**, then
  reading up to fourteen more contiguously in physical memory. The physically
  next frame is almost never the virtually next page, so an instruction
  straddling a page boundary decoded from someone else's bytes.
- **`RDTSC` stood still while the machine slept.** It returned the count of
  *retired* instructions, which does not move during `HLT`; the 8253 counts
  idle turns too. The kernel had picked the TSC as its clock source and
  calibrated it against the 8253 at boot, then found it frozen every time a
  tick woke it: a twelve-second timeout cannot expire on a clock that does not
  advance. Both now read the same time.
- **The serial port failed the 8250 driver's existence test**, so the kernel
  never registered `ttyS0` as a terminal and user space had no console —
  `printk` wrote the port directly, which is why the kernel's own lines never
  hinted at it. The port models the 16550's eight registers, passes the
  driver's probe (« ttyS0 at I/O 0x3f8 (irq = 4) is a 16550A », as under
  QEMU), and its transmitter interrupts on line four, which is how the driver
  moves user-space output at all. Init's own « * Mounting boot media: » now
  appears on the console.
- **`XADD` wrote its source register before writing memory, and `POP` to
  memory moved the stack pointer before writing.** When the memory write
  faulted — the page had just been shared by `fork()` and was no longer
  writable — the kernel copied the page and replayed the instruction with
  the register already overwritten: the replay added the destination to
  itself. Measured on the lock word of musl's `__unlock`, cycle after cycle:
  0x9FFFFFFF → 0x3FFFFFFE, 0xBFFFFFFF → 0x7FFFFFFE, 0xFFFFFFFF → 0xFFFFFFFE —
  always v + v, never v + 0x7FFFFFFF. That is how nlplug-findfs came to sleep
  on `futex(lock, WAIT, -1)`, a value impossible by construction, with nobody
  left to wake it. Both instructions write memory first now, and a test
  faults each of them on a read-only page and replays it, as the kernel
  does. With the three fixes above, Alpine's init ends on « Mounting boot
  media: failed. » and launches the initramfs emergency shell — exactly
  where QEMU ends on the same images, after 4 billion instructions.
- **A VM identifier reached `virsh` with no validation at all.** `service.rs`
  took the path segment straight from the URL and handed it to
  `backend.get/start/stop`, which passes it to `virsh` as an argument.

  Two clean negatives first, both probed rather than assumed: there is **no
  command injection** — `Command::new(virsh).args([...])` is argv, never a
  shell, so an id of `; rm -rf /` is one harmless argument virsh cannot find —
  and **no JSON injection**, because `vm::escape` covers quote, backslash,
  `\n\r\t` and everything below 0x20.

  What is real is **argument injection**: an identifier beginning with a dash is
  not a name to an option parser, it is an option. Probed end to end, all
  answering 200:

  ```
  /v1/vms/-c/start        -> backend received "-c"
  /v1/vms/--version/start -> backend received "--version"
  ```

  It needs the bearer token, so it is escalation inside an authenticated session
  — from "drive this host's VMs" to "run virsh with flags of your choosing" —
  rather than a way in. The path is not percent-decoded, so a `/` cannot appear
  in a segment and a full `--connect=qemu+ssh://…` URI is not reachable this
  way; exactly which flags are depends on virsh's option set, which is not
  installed here, so no specific exploit is claimed. The class is closed
  regardless.

  Identifiers are now checked once, at the routing boundary, against an
  allowlist: non-empty, at most 255 bytes, no leading dash, and letters, digits,
  dot, dash or underscore only. An allowlist rather than a denylist because
  "characters virsh dislikes" is a guess about another program's parser.

### Added
- **The token and the TLS private key existed world-readable, briefly.** Both
  were written with `fs::write` and narrowed to `0600` on the *next* syscall.
  `fs::write` creates a file at the default mode — **0644** under the usual
  `umask 022` — so each secret spent a window readable by any local account, and
  the state directory at 0755 did not cover it. Measured on this project's own
  container: 644, then 600.

  The mode now goes in the `open`, where the kernel applies it before the file
  exists to anyone, and the state directory is 0700 as a second line.

  **The window is not narrow.** A thread stating the file while the writer runs
  counted **747 observations at a mode other than 0600 in 100 rounds** of the old
  shape — roughly seven stats wide — and **zero** for the new one, at 100, 1 000
  and 10 000 rounds.

  The part worth keeping: `tls.rs` already had a test named
  `the_key_is_not_world_readable`, and it **passes with the race intact.** It
  reads the mode after the write finishes, and both shapes end at 0600, so it
  could never see a window in the middle — a guard giving more confidence than it
  earned. Confirmed rather than assumed: with the race reinstated, that test
  still passes and only the new watching test fails.

- **The agent answered 200 for requests whose body it had thrown away.** Its
  hand-written HTTP parser framed bodies by `Content-Length` and ignored
  everything else, so a `Transfer-Encoding: chunked` request — what any HTTP
  client sends the moment it decides to stream — arrived with an **empty body**
  and was acted on as though the caller had sent none. That is the worst
  available answer: the client is told its request succeeded.

  Three more, all demonstrated with a probe before anything was changed rather
  than inferred from reading:

  | request | before | now |
  | --- | --- | --- |
  | `Transfer-Encoding: chunked` | body silently empty, 200 | 501 |
  | repeated `Content-Length` | last wins, body truncated | 400 |
  | `Content-Length: +5` | accepted — `usize::from_str` allows a leading `+` | 400 |
  | `Content-Length` **and** `Transfer-Encoding` | length used, encoding ignored | 501 |

  The last three are the request-smuggling primitives. This daemon closes every
  connection after one exchange, so it cannot be desynchronised on its own — but
  it is exactly the sort of daemon someone puts behind a reverse proxy on a NAS,
  and then a pair of parsers disagreeing is the whole attack. The file's own
  docstring already said what it wanted to be: "deliberately strict — a daemon
  that accepts sloppy requests is a daemon whose behaviour nobody can predict".

  Whitespace around a `Content-Length` is still accepted, because RFC 9112 puts
  optional whitespace around every field value. That case caught the first draft
  of the *test* rather than the code, and both directions are now pinned: eight
  tests drive real sockets, each defect reintroduced one at a time fails tests,
  and so does over-correcting into refusing what is legal.

  The app cannot be broken by this: `AgentClient` sets `URLRequest.httpBody`,
  which URLSession frames with `Content-Length`.

### Added
- **The decode path's copies are counted, and held by a test.** The last item on
  the optimisation list was the decoders' hot loops. The structural work turned
  out to be already done, and the instrument matters as much as the finding:
  buffer identity, not a stopwatch. Two addresses are equal or they are not, and
  the answer does not change because another process woke up — a timing taken in
  a shared container says nothing, which is why **no speed-up is claimed
  anywhere in this work**.

  Measured: a decoded frame crosses `rowsTopDown` at the same address when the
  stream is already top-down (zero copies on the common path), changes address
  exactly once when it must be flipped, and survives the
  `(pixels:width:height:)` hand-off unchanged. `SpiceLZ.decompress` reserves the
  exact final size before its loop, so the back-reference copy never grows the
  array.

  `SpiceDecodeCopyTests` holds this. It is a guard, not an observation:
  `rowsTopDown` rewritten as an unconditional row loop stays *correct*, passes
  every orientation test, and silently allocates and copies a full frame for
  every image a top-down server sends — which is most of them. Sabotaged that
  way, two tests fail; sabotaged into never flipping, seven; with the
  truncated-frame guard removed, the run traps outright.

  What remains — unsafe pointers, NEON intrinsics — needs an iPhone to judge,
  and `docs/ROADMAP.md` says so rather than pretending otherwise.

- **Decisions written down for the two lots that need an Apple machine.** Lot 3
  (RDP) gains a fourth point settled in advance: RDP decoding must not reuse
  SPICE's surfaces, which already carry SPICE's ROP3s, masks and image cache —
  the shared layer, if it ever exists, is the draw target, not the decoder. Lot
  6 gains three: the indirect pointer overlays the remote cursor rather than
  replacing it, multi-window means one session per scene because SPICE channels
  carry per-connection state that cannot be doubled without lying to the server,
  and a Siri shortcut names a machine without carrying its token.

### Changed
- **The preview server sends the cache headers a real host should.** It claimed
  to serve the site "the way a real host would" and sent `no-store` on
  everything — reliably fresh, and unlike any host that has ever existed: nobody
  serves a content-hashed asset with `no-store`. Three classes now, with
  `tests/serve.test.ts` holding each: hashed `chunk-<hash>.{js,css}` are
  `immutable` for a year, `sw.js` is `no-cache` because a cached service worker
  freezes the site at whatever it last installed, and everything else is
  `no-cache` — which keeps the copy and revalidates it, unlike `no-store`.

  None of this reaches the deployed site, which GitHub Pages serves with its own
  headers and no way to set them. That is written down rather than implied: the
  caching that decides what a returning reader downloads is the service worker,
  which this project does control and which already does the right thing.

  `scripts/serve.ts` now exports its handler and only listens when it is the
  entry point, so the tests put a `Request` through it without opening a port.

- **The site stopped shipping React.** Its pages were already pre-rendered, so
  React's only remaining job in a browser was hydrating four behaviours: a
  redirect on the English home page, the memory of a language choice, the theme
  switch, and the install banner. Measured, that cost **65 794 bytes gzipped**
  on every page. Written against the DOM instead, the same four cost **1 062** —
  a 98% cut in JavaScript, on a project whose own roadmap says the network is
  the budget.

  React stays as the authoring language and the pre-renderer; only the delivery
  changed. What is lost is the ability to add an interactive component by
  writing JSX: anything genuinely interactive now belongs in `src/main.ts` as
  DOM code, or behind a dynamic import only the pages needing it pay for. That
  is written into the site's README rather than left to be discovered.

  Two guards keep it: the budget in `tests/build.test.ts` drops from 240 000 raw
  and 80 000 gzipped to 8 000 and 3 000, and a new test fails if React appears in
  the shipped script at all. A ceiling sized for a hydrating bundle would have
  waved through the one regression that matters — importing a component back
  into `main.ts` — so the number had to move with the code.

  `tests/behaviour.test.ts` is the other half, and the more important one: it
  loads the real built page, runs the real shipped module against it and presses
  the buttons. Every test above checks the bundle's *size*; a script that weighs
  nothing and does nothing would pass all of them. Each of the four behaviours
  was then broken on purpose, nine ways, and the tests caught all nine.

- **A written page no longer carries its text twice.** Each one embedded its
  document as JSON beside the markup because hydration had to read exactly what
  the build rendered. Nothing hydrates, so the payload has no reader. It was
  cheap — the two copies sat inside gzip's window — and measuring says so:
  5 472 bytes gzipped across all twenty pages, about 300 per page.

### Added
- **The agent is published for four architectures instead of two.** The release
  built Linux x86_64 and macOS arm64; `scripts/install.sh` asked for exactly
  those two. The two halves agreed with each other, which is why the gap was
  quiet — an ARM NAS, a Raspberry Pi or an Intel Mac fell through to the source
  build, which needs a Rust toolchain those machines have no reason to carry.

  Linux aarch64 is cross-built against musl and smoke-tested under
  `qemu-aarch64-static`: 1.4 MB, statically linked, `--help` returns 0. macOS
  x86_64 is cross-built on the arm64 runner and checked with `file` rather than
  run, because GitHub's macOS runners carry no Rosetta — an asymmetry written
  into the workflow so it does not read later as an oversight.

  `scripts/check-release-matrix.sh`, run by the **Lint** job, now fails the
  build when the list the workflow produces and the list the installer requests
  stop matching, in either direction. The release workflow only ever ran when a
  release was cut, so this gap was previously discoverable only by installing on
  a machine nobody had thought about.

  It checks two different things, because comparing the two lists as *sets*
  leaves one mistake invisible: a mapping that uses a name which does exist, for
  the wrong machine. Swap `Darwin/arm64` and `Darwin/x86_64` in the installer
  and both sets stay identical while every Apple silicon Mac downloads an Intel
  binary. So the table is also exercised — a fake `uname`, the real installer,
  and the URL it prints — for all five supported pairs plus two that correctly
  fall through to the source build.
- **The release workflow can be run without publishing.** A `dry_run` input
  builds every asset, runs both test gates and packages the IPA, then stops
  before creating the release. On a tag push the input does not exist, so the
  publish step runs exactly as before.
- **The clipboard's protocol is encoded and decoded.** It does not travel on
  the inputs channel — the guess a reader makes — but through the agent running
  *inside* the guest: the clipboard is the guest's, so it goes to the program
  rather than to the virtual hardware, wrapped in `AGENT_DATA` on the main
  channel.

  **These structures do not have one layout; they have four.** Two optional
  prefixes appear or vanish with what the two ends negotiated: `selection`,
  which is **four bytes** — one of selection and three reserved, padded to a
  word — not one; and `serial`, on the grab message only, under a different
  capability again.

  Read the selection as a single byte and every field after it shifts by three,
  while the payload still decodes into *something*. A client that assumes one
  layout works against the server it was written for and misreads every
  clipboard message from the next. The layout is computed from the negotiated
  capabilities rather than fixed, and a test reads the same bytes under both
  agreements to show they mean different things.

  Text that is not valid UTF-8 yields nothing rather than replacement
  characters: pasting `\u{FFFD}\u{FFFD}\u{FFFD}` into a document is worse than
  pasting nothing. A trailing NUL — which some agents include — is trimmed,
  since otherwise every paste ends with an invisible character.

### Fixed
- `scripts/install.sh --help` said `--from-source` builds with the local Swift
  toolchain. The daemon has been Rust since it left Swift; it needs cargo.
- `CONTRIBUTING.md` described that same Swift toolchain, and listed two release
  assets where there are now four.
- **SPICE asked for the channel list with the wrong message number, and could
  never have connected to a real server.** `ATTACH_CHANNELS` is 104; the client
  sent 101, which is `CLIENT_INFO`. The main channel's client messages number
  from 101 in declaration order — `client_info`, `migrate_connected`,
  `migrate_connect_error`, then this — and the first is the one an eye lands
  on.

  The effect against a real server is total: the channel list never arrives,
  `bringUp` runs to its limit and throws, and every channel built on top is
  unreachable. Everything else in this protocol had been built above a
  handshake that does not complete.

  **Nothing caught it, and both reasons are worth keeping.** The test asserted
  that what went out equalled the constant — true however wrong the constant
  is; a number checked against itself is not checked. And the scripted server
  sent its channel list whether or not it had been asked, so a wrong request
  looked exactly like a right one.

  The assertion is a literal now, with the protocol's own numbering written
  beside it, and a new test pins the whole family of message numbers against
  the specification rather than against the constants that produce them.

### Added
- **`rgba` and `xxxa` decode, and LZ is complete.** They are **two LZ streams
  end to end in one payload**: the colour pass, then an alpha pass over the
  same pixels touching only their fourth byte, reading on from where the first
  stopped.

  That is why they were refused rather than decoded. The single-pass loop would
  have read the colour pass, declared the image finished, and left every pixel
  opaque while half the payload sat unread — a picture, and a wrong one.

  `xxxa` is the alpha pass alone: its colour bytes are never transmitted, so
  they come back as zero rather than as whatever the buffer held. In C that is
  uninitialised memory reaching the screen.

- **LZ's palette forms decode: PLT8, PLT4 and PLT1, both orders each.** Three
  of the rules here produce an *image* when written backwards rather than an
  error, which is the kind of wrong that ships: a 4-bit `LE` byte gives the low
  nibble first and `BE` the high one; a 1-bit `LE` byte starts at bit 0 and
  `BE` at bit 7; and the palette is little-endian while the LZ stream header
  immediately above it is big-endian, because the palette belongs to the
  display channel's message and the stream to the codec.

  Backwards, each gives a picture — mirrored in pairs, mirrored in groups of
  eight, or in the wrong colours. All three were checked against the reference
  decoder's own output **before** the decoder was written, which is the only
  order in which that check means anything. `scripts/spice-lz-fixtures/genplt.c`
  is the harness.

### Fixed
- **The decompression loop counted one output unit per pixel.** For a 4-bit
  image an eight-pixel row is four bytes, not eight, so every palette stream
  looked truncated. And rows start on byte boundaries: a five-pixel 1-bit row
  spends one byte and wastes three bits — read straight through, everything
  after the first row shears.

### Changed
- **`verify.sh` runs SwiftLint on Linux now, instead of saying it cannot.** It
  can: the binary needs `libsourcekitdInProc.so`, which ships inside the Swift
  toolchain and is not on the loader's path, and without it the process dies
  with a loader error rather than a lint result. Six lines of `LD_LIBRARY_PATH`
  and the gate a contributor can run locally is the same gate CI runs.

  This is the second time the missing check found something after a pull
  request was open — a trailing blank line, and now an `.enumerated()` whose
  index the closure never used. The script's own comment said "the CI will run
  it", and that was true and not good enough. When SwiftLint is absent
  entirely, the message now says where to get it for each platform rather than
  shrugging.

### Added
- **The pointer, on a connection of its own.** So it keeps moving while the
  display channel is sending a screenful of pixels — on a phone that is the
  difference between a cursor that follows the finger and one that lags a
  repaint.

  Two widths here would have been written wrong from memory, and both produce a
  cursor rather than an error: **`cursor_flags` is sixteen bits where
  `cursor_type` is eight**, so a guess puts the header two bytes off; and the
  position is a `Point16` — two *signed sixteen-bit* values, not the two 32-bit
  ones the display channel uses.

  Three absences are kept distinct, because conflating them shows a wrong
  pointer rather than raising an error: the `NONE` flag, a cursor named from a
  cache this client does not keep, and a form that is not decoded (mono,
  palette). An empty cursor means "hide the pointer", so forwarding one for "I
  do not have it" does the opposite of what the server asked.

  A failure on this channel ends the cursor and nothing else. Losing the
  pointer is losing the pointer; tearing down a working screen for it would
  trade a lot for a little.

- **SPICE takes input.** A third connection, presenting the same session
  identifier as the display one. `SpiceInputs` was already encoded and tested;
  what it needed was a socket of its own, because sending keystrokes down the
  display socket is a protocol error dressed up as a shortcut.

  Best effort on purpose: a server offering no inputs channel still gives a
  usable session. The screen is worth having without the keyboard, and refusing
  to start would trade something for nothing.

  Each channel counts its own serials. One shared counter across two
  connections hands each of them a sequence full of holes, and a server that
  acknowledges by serial would be right to complain.

- **SPICE connects.** `SessionFactory` returns a SPICE session where it used to
  throw `unsupportedProtocol`. The shape that separates SPICE from RFB next
  door: **one TCP connection per channel** — the main one first, because it is
  the only one that learns the session identifier, and every channel after it
  must present that identifier as its connection ID. Without it the server sees
  an unrelated client and gives it a display of its own: a black screen that
  looks exactly like a broken decoder. Driven against a scripted two-socket
  server, with the identifier read straight back out of the display channel's
  link message.

  Two defects found in the wiring, neither by an existing test:

  The pump handled **256 messages before reporting anything**. A first frame of
  three messages would have sat unpainted waiting for the two hundred and
  fifty-third — on a quiet desktop, never. The default is one message per call
  now, and the caller publishes damage as it happens.

  The serial did not survive between calls and nothing checked it. A `defer`
  meant to carry it was dead code: a `defer` runs after the return value has
  been copied, so it cannot change what comes back. Confirmed with a five-line
  program rather than reasoned about. Removed, and a test holds it now.

- **The display channel runs: messages in, pixels out.** A `struct` over a
  `ByteStream` like the main channel, so it can be driven against a scripted
  server with no socket — which is how its ordering rules get asserted rather
  than hoped for.

  `INIT` goes before the compression preference, and that order is the
  protocol's rather than a taste: the server does not draw until `INIT`
  arrives, and a preference sent first can reach a server that has not yet
  decided this client exists.

  **"Not implemented yet" is not "malformed", and the difference is the whole
  design.** An encoding wisq cannot decode leaves that part of the screen alone
  and is counted; a message that makes no sense stops the pump. Conflating them
  disconnects a phone because a server sent one JPEG. Unhandled messages are
  counted by type — a client that ignores half a protocol should be able to say
  which half, and that number is what says what to build next.

  A ping is answered rather than counted as ignored: a server that pings and
  hears nothing concludes the client is gone.

- **Draws reach pixels: SPICE surfaces, with the clipping rules tested.** Where
  the three finished pieces meet — the display channel says where, the LZ
  decoder says what, this puts it somewhere. Each was correct alone and none of
  them showed anything. One test crosses every seam: a stream from SPICE's own
  encoder comes out as pixels on a surface at the box's origin.

  The two cuts are different cuts and both apply. The box says where the server
  means to draw; the clip says which parts of that it still wants visible.
  Honour only the box and a window that should have stayed covered gets painted
  over. And a clip changes **which** pixels are written, never **which source
  pixel** each comes from — computing the source from the clipped rectangle
  slides the image sideways wherever something overlaps it.

  Worth being exact about how this fails, because it differs from the C the
  protocol grew up in: there, an over-running blit writes the next row and the
  picture shears, invisibly. Here the array is bounds-checked, so the same
  mistake traps — the app dies rather than misdraws. Removing the cut does not
  fail the tests, it takes the process down with signal 4. Neither outcome is
  acceptable when the numbers came off a socket.

- **wisq now asks the server for the codec it can actually decode.** A SPICE
  server picks its image encoding from its own configuration, and the usual
  default is "automatic" — QUIC for photographic content, GLZ for graphic.
  Neither is decoded here. Without asking, a client holding an LZ decoder and
  nothing else watches most of the screen arrive in an encoding it must skip.

  `SPICE_MSGC_DISPLAY_PREFERRED_COMPRESSION` requests `LZ` — not `AUTO_LZ`,
  which would leave the server free to send QUIC for photographic content,
  since that is what "automatic" means. And only when the server has advertised
  `SPICE_DISPLAY_CAP_PREF_COMPRESSION`: a message the other end has said it
  does not understand is noise, not a request.

  A capability is a **bit position**, not a value. Read as a value the check
  would be wrong in a way that happens to be right for capabilities 1 and 2 —
  the kind of error that survives a casual test.

  This reorders the work that is left: porting QUIC, some two thousand lines of
  predictive coding, becomes an optimisation *after* rather than a prerequisite
  *before*.

- **LZ's 16-bit form decodes too.** Its two stream bytes land in memory the
  other way round: the codec reads a pixel as `(first << 8) | second` and
  stores it as a machine word, so on the little-endian machines wisq ships to
  the order flips. Written out explicitly rather than left to whatever the host
  does, so the output is the same everywhere and a test can say what it should
  be — and its match length is biased by two where the 24- and 32-bit forms use
  one. Both facts are sabotage-checked against reference streams.

  Found while adding it: the fixture harness printed four bytes a pixel for
  every type, which reads past what a 16-bit decode writes and reports zeroed
  memory as pixels. The harness was wrong, not the codec.

- **SPICE's LZ codec decodes, checked against SPICE's LZ encoder.** The first
  of the compressed forms the display channel stopped at. LZ before QUIC and
  before JPEG for a reason about this repository rather than about the codec:
  it is integer work on bytes with no platform behind it, so a Linux runner
  that costs nothing can exercise every branch. JPEG would mean `ImageIO` on
  Apple and nothing on Linux — the shape of `WisqNet.SHA256`, which returns
  empty `Data` without CryptoKit and therefore agrees with itself about
  nothing.

  Two things here would have been written wrong from memory, and both were,
  before the fixtures caught them: **the stream header is big-endian**, inside
  a protocol that is little-endian everywhere else; and **the lengths are
  biased differently per pixel type** — one for 32-bit, two for 16-bit, three
  for the palette forms. A missed bias makes every match a pixel short, which
  produces an image that is almost right.

  A third: `rgb32` transmits three bytes a pixel and writes a fourth zero byte
  of padding that was never sent. Reading four takes the next pixel's blue as
  this one's padding and shears the whole image.

- **The fixtures come from the reference implementation.** `spice-common`'s own
  `lz.c` is linked into a harness that compresses images built to contain flat
  bands, a repeating pattern and noise, so literal runs, short matches, long
  matches and the two-byte far distance all occur. A fixture written by hand
  could only confirm that the same person made the same assumptions twice —
  all three mistakes above would have survived it. The harness is committed at
  `scripts/spice-lz-fixtures/` so the fixtures can be rebuilt rather than
  trusted.

  One branch stayed uncovered even so: the far-distance boundary — a match
  whose low distance byte is 255 while the control byte's five distance bits
  are not all ones — does not come out of the encoder at these sizes. That
  stream is crafted by hand and then **validated against the reference
  decoder**, not against an expectation. Removing the condition now fails a
  test; before that fixture existed it did not.

- **A `DRAW_COPY` carrying an LZ image comes out as pixels**, with one test
  crossing the seam. Structure and codecs stay apart — that is what lets each
  be checked against its own reference — so exactly one test joins them.

  GLZ is refused despite having the same stream format. Its matches reach back
  into a dictionary built from *earlier images on the channel*, so decoding one
  alone assembles a picture from whatever was lying around. Sharing the entry
  point would be the kind of mistake that shows a plausible image.

### Added
- **The SPICE display channel is decoded.** Geometry, clips, surfaces, image
  descriptors, `DRAW_FILL` and `DRAW_COPY` — written with the specification
  open rather than from memory, which is why it did not exist before. The trap
  it was waiting on: **a SPICE pointer is a `uint32` holding an offset from the
  start of the message**, not from the field that carries it and not a length.
  Zero is null; an offset at or past the end is an error, not a clamp. A
  decoder that guesses at that produces a plausible parser reading the wrong
  bytes.

  The other layouts that would have been guessed wrong: a rectangle is
  `top, left, bottom, right`, which is not the order anyone assumes and
  transposes every rectangle if assumed; and the clip is **inline**, not behind
  a pointer — the specification's `@to_ptr` describes the C struct, not the
  wire, and reading it as a pointer would treat a rectangle count as an offset.

  An unknown clip type is refused rather than treated as "no clip", which would
  paint over the part of the screen the server asked to be left alone. An
  unknown surface format is named rather than assumed, because assuming means
  every pixel after it is wrong in a way that still fills the screen.

  What it does not do, and says so: it does not draw, and it stops at the
  compressed payloads. QUIC, LZ, GLZ and JPEG are each their own work, and
  claiming them here would mean a decoder that says it understood an image it
  cannot produce one pixel of.

### Changed
- **Two guards were written and removed after a sabotage showed they did
  nothing.** A bound on the rectangle count did not change the outcome: the
  decoder appends one at a time and reserves nothing, so a count of four
  billion ends on the first read past the end either way — the safety is in not
  reserving, exactly as with the channel list earlier. A third guard, against
  following an offset already on the path, stayed, with a note saying honestly
  that no path can cycle today and that it is there for `DRAW_ROP3` and
  `DRAW_OPAQUE`. Its first test passed with the guard deleted — it had agreed
  with the guarded code for an unrelated reason — and was rewritten against
  `follow` itself.

- **A failing decoder test crashed the run instead of failing it.** The clip
  test subscripted a rectangle list after asserting its count, so a wrong
  decoder killed the process and took seventeen other results with it. It
  compares the list as a whole now.

### Added
- **A connection file opens as a machine.** `.vv` and `.rdp` had readers and
  nothing called them; the menu now has "Ouvrir un fichier .vv ou .rdp", and
  what comes back opens in the editor rather than landing in the library
  unseen. A connection file is somebody else's description of a machine — its
  name is a host, its port came from a server, its password is often a ticket
  good for one connection — and the user should see all of that before it is
  theirs.

  The picker allows every file type rather than declaring `.vv` and `.rdp`.
  These arrive from Mail and AirDrop with whatever name the sender chose, and
  a picker that greys out `connexion.txt` refuses a file wisq reads perfectly
  well. What the file *is* gets decided by reading it, which is the only thing
  that can decide it — and it means the sender does not get to pick which
  parser runs on their file.

- **Connection files saved by Windows are read.** Its Remote Desktop client
  writes `.rdp` as UTF-16 little-endian with a byte order mark. Read as UTF-8
  those bytes are not the file, every line fails to parse, and the import
  fails on what is probably the commonest `.rdp` in existence.

  A branch for the UTF-8 mark was written alongside it and then removed: it
  turned out to be dead code, because Foundation strips that one itself. The
  test stayed. What it guards now rests on Foundation rather than on wisq's
  own code, and it runs in the simulator as well as on Linux — Foundation on
  Darwin and Foundation on Linux are two implementations, and the phone is
  where the file actually gets opened.

- **Every way a connection file can fail has a sentence in French.** They live
  beside the readers rather than in the view, because a view writing them
  would have to know which failures exist and would quietly stop covering
  them the day a reader gained one. A test walks all eleven and fails on any
  that falls through to `localizedDescription` — which, for a Swift enum, is
  a type name and a case name in English.

### Fixed
- **An imported password was dropped on save.** The editor writes a secret only
  when its field was *edited*, so that opening an existing machine and saving
  does not wipe the password it already has. A password from a connection file
  arrives filled in and is never touched, which is exactly the shape that rule
  drops — the machine would have been created with no credential, and
  connecting would have asked for a password the user does not have and cannot
  guess, because it was a one-shot ticket issued by a server. The draft now
  records that its password came from a file, and the simulator tests say so.

- **The Apache-2.0 claim was still shipping.** It was removed from the site,
  and it survived in the two places that state a licence to *other software*:
  the copyright string inside the app bundle, and the `license` field of the
  Homebrew formula, which is published through the tap. No licence has been
  chosen for wisq, so both were claims nobody had made.

  `scripts/check-licence-claims.sh` now fails the build on any of them, plus a
  `license` field in any `Cargo.toml` and the reappearance of a `LICENSE` file.
  It is deliberately narrow: naming Apache-2.0 is *correct* in the README, in
  NOTICE and in the roadmap, where it is a fact about UTM, FreeRDP and QEMU —
  other people's projects, which really are under it.

- **A second kernel called `Image` inherited the first one's saved machine.**
  Saved machines were filed under the kernel's *name*, and `Image` is what
  almost every kernel image downloaded from anywhere is called. Two different
  ones imported a week apart shared a file, so the second resumed a session
  that had run under a kernel it had never seen.

  They are filed under the image's bytes now. The name stays in front of the
  digest, but only so a person looking in the directory can tell the files
  apart — it is not the key.

  The digest is an FNV-1a 64 written in `WisqVM` rather than `WisqNet`'s
  `SHA256`, which returns empty `Data` on any platform without CryptoKit —
  which is the platform every test here runs on. Every image would have
  digested to the same nothing, the tests would have passed, and the phone
  would have done something else. A hash that only works where it is not
  tested is worse than no hash. It is checked against a single flipped byte at
  six positions including the last, and against an appended zero.

  A first version also mixed the image length in, on the theory that trailing
  zeros could make a long image collide with a short one. Removing that step
  broke no test, which is how it was found to be doing nothing — FNV-1a
  already folds every byte in, zeros included. It is gone.

### Added
- **The two readers are wired to the model.** `ConnectionImport` turns a parsed
  file into a `Machine`. Its own type rather than an initialiser, because every
  line of it is a decision about a value wisq did not choose.

  The password comes back *beside* the machine and never inside it: `Machine`
  is `Codable` and is written to disk, so a secret reaching it would be
  persisted in the clear next to the host it opens. A test serialises the
  machine and asserts the secret is absent. The credential reference stays nil
  until someone has actually stored the secret — a machine pointing at a
  credential that was never written fails at connect time instead of asking.

  An `.rdp` import claims no transport, because the file states none: RDP
  negotiates its TLS inside the connection. And the file's geometry is not
  carried — it describes the monitor of whoever saved it, which on a phone is
  somebody else's screen. `DisplaySettings` has no field for it, and adding one
  would have been growing the model to satisfy a file rather than a user.

- **`.rdp` connection files are read too.** The ones Windows, Azure Bastion and
  every RDP gateway hand out. One option per line, `key:type:value`, and the
  value keeps every colon it has — which is what makes
  `full address:s:[2001:db8::1]:3390` a legal line and this a parser rather
  than a `split(separator: ":")`.

  An IPv6 literal in brackets has five colons and only the last separates a
  port; cutting at any other gives a host of `[2001` and a connection to
  nowhere. A *bare* IPv6 literal carries no port at all, and taking its last
  group for one would silently truncate the address. Port 3389 applies when
  none is given, never in place of one that could not be read. An `i` field
  holding text is refused rather than guessed.

  The saved password blob is encrypted to the machine that wrote the file and
  would be useless here even if it were read. It is not decoded, not stored and
  not carried, and a test walks the parsed value's fields to say so.

- **`.vv` connection files are read.** The one virt-manager, oVirt and Proxmox
  hand out when you click "console": host, port, transport, and a one-shot
  ticket nobody could retype. The user has already done the work; retyping any
  of it is a chance to get it wrong.

  Options this client has no use for are ignored rather than refused — real
  files are mostly those options, and failing on the first would reject good
  ones for saying something extra. What is malformed is refused: a port that is
  not a number would otherwise be replaced by a default and connect somewhere
  the file never named. `tls-port` wins over `port`, since a file offering both
  is offering a choice and the encrypted one is the answer. A second section
  ends the reading, so an appended one cannot quietly redirect the connection.

  The password never appears in the type's description. That description is
  what ends up in a log or a crash report, and the synthesised one would carry
  a live console ticket into it.

- **The SPICE inputs channel, and the scancode table it needs.** RFB takes X11
  keysyms; SPICE takes PC AT scancodes. `InputEvent.key` claimed in its own
  comment that its keysym was "as used by both RFB and SPICE" — it is not, and
  a backend forwarding one unchanged to a SPICE guest would type nothing
  recognisable. `SpiceScancode` is the conversion, and the comment is corrected
  alongside it.

  14 tests, spot-checked against the set-1 layout rather than against the
  table's own output. They hold: the `0xE0` prefix on extended keys, without
  which the arrows become the numeric keypad; an unknown key sending nothing
  rather than a guess, because a keyboard that lies is worse than one that is
  incomplete; the wheel staying out of the held-button mask while a drag's
  button stays in it; and a negative coordinate clamped rather than wrapped to
  four billion.

- **The SPICE link, and the main channel up to its list of channels.**
  `SpiceLink` runs the handshake over any byte stream; `SpiceMainChannel` reads
  `MAIN_INIT`, asks for the channel list, and answers pings and acknowledgement
  windows on the way. 17 tests, driven by a scripted server in memory.

  The ticket encryptor is a closure rather than a call, and that is the whole
  reason any of this is testable. SPICE encrypts its ticket with RSA, which on
  Apple means `Security` and on Linux means nothing at all. Calling it directly
  would have put the sequence, the capability negotiation, the framing and every
  refusal behind a platform CI does not have. What a stub cannot check is the
  encryption itself, and the tests do not pretend otherwise.

  Not yet wired into `SPICESession`, which still reports the protocol
  unsupported: a link that completes with nothing to draw is not a session.

- **The SPICE wire format, as bytes rather than as a plan.** `SpiceWire`
  encodes and decodes the link handshake, the 18-byte data header, `MAIN_INIT`,
  the channel list, pings, acknowledgements and notices — pure functions over
  `Data`, with no socket and no actor. SPICE is the default console of
  QEMU/libvirt, so it is what most of the machines the agent manages actually
  speak.

  Little-endian throughout, which is the first thing that separates it from the
  RFB code next door: `ByteStream`'s readers are big-endian because RFB is, and
  borrowing them here would be wrong in a way that still mostly works — a length
  of 1 reads the same either way. It brings its own reader instead.

  22 tests, asserting the bytes literally against the specified layout rather
  than against whatever this code happens to produce, and refusing every
  truncation of a link reply. Four guards were sabotaged to check they bite; the
  two that did not led to real changes rather than to a shrug.

- **« Oublier » throws the saved machine away without ending the running one.**
  "Arrêter" already cleared it, but only by ending the session; there was no
  way to say "keep going, just do not come back to this next time". A user
  whose guest is wedged wants exactly that: leave now, start clean later. The
  button appears only when there is something to forget.
- **The site is a site again: seven pages, a nav strip and a full footer.**
  Reducing it to one page took the strip under the header, the three link
  columns above the bottom bar, the pairing section, and six pages with them —
  Guide, Agent protocol, Architecture, Questions, Roadmap, Releases. They are
  back, along with the CSS that had been sitting there unused ever since,
  describing a footer nothing rendered.

  What did not come back is how to get this. There is no clone, no tap, no
  script to pipe into a shell, no download link, and no page saying where a
  build lives. The Guide lost its "Getting the app" section outright; the
  agent's install commands are gone while the prose explaining what the agent
  is for stays; the protocol page's demo command and the FAQ's benchmark
  command are gone.

  The guard that used to enforce this was too blunt: it forbade the pairing
  section along with the install commands, on the reasoning that both were "how
  to run the project". They are not the same thing — a reader deciding whether
  this is for them needs to know that an agent prints a link and the phone
  scans it, and none of that hands them a build. The test now lists commands
  and download paths only, and it caught two of these while they were being
  removed. Verified by putting an install command back and watching it fail.

  The FAQ's licence answer said Apache-2.0. It now says none has been chosen,
  which is true, and the App Store answer no longer leans on a licence
  comparison that stopped holding. The unused `REPO`, `RELEASES`,
  `CONTRIBUTING` and `SECURITY` constants are gone with the links that used
  them.

### Fixed
- **A machine told to stop while it was resuming ignored it, and then could
  not be stopped at all.** `restore` cleared the stop flag along with the rest
  of the state, in both cores. That flag is not part of the guest's state — it
  is the owner asking this machine to come back — so clearing it threw the
  request away.

  It is not a corner case. The app restores on a background thread and can be
  told to stop from the main one before the restore finishes, which is exactly
  what leaving the console the instant it opens does. The emulator thread then
  ran with nothing able to end it: on a phone, a core spinning until the
  process died.

  Found by the new simulator tests on their first run, in the one assertion
  that says "Arrêter" has to actually conclude — which is the whole argument
  for running that layer rather than reasoning about it. Both cores are fixed
  and both now have a regression test that asserts on retired instructions
  rather than on the outcome: `stopped` is also what an exhausted budget
  returns, so the outcome alone cannot tell an honoured stop from a machine
  that ran the whole budget. The budget stays bounded so a regression is a
  failing test, not a hanging one.

### Changed
- **No licence is claimed any more, because none has been chosen.** The site
  announced Apache-2.0 in the hero badge, in the comparison table, twice in the
  footer and — the one that mattered most — in the JSON-LD block, which is the
  machine-readable version search engines read and repeat. The repository
  carried the full Apache-2.0 text, a shields.io badge, and the field in two
  `Cargo.toml` files and `package.json`. None of it had been decided; it came
  along with the scaffolding.

  Granting rights nobody chose to grant is not a neutral default, so all of it
  is gone, `LICENSE` included. The repository is source-available to read and
  nothing more until its author picks something. Removing the file does not
  retract anything already granted to anyone who took a copy under those terms
  — that grant is irrevocable — it only stops the offer from continuing.

  Facts about *other people's* licences stay, because they are true and are not
  claims about this project: QEMU is GPL, mini-rv32ima is MIT, UTM is
  Apache-2.0, FreeRDP is Apache-2.0. The comparison row that used to read
  "Apache-2.0, all first-party code" now says what it was really getting at —
  no QEMU inside, so no copyleft to carry — which holds whatever licence gets
  chosen later.

  Taking it out left two holes, and nothing said so: the badge went from
  three items to two, and the footer's legal row from three to two, while the
  build stayed green and the footer visibly thinned. What filled them is true
  without a licence — the badge names the platform it targets, the version
  line ends with the plain default, and the legal row carries the copyright,
  which says who wrote this rather than what anyone else may do with it. The
  footer test now checks those two lines, because the whole point of a footer
  check is that a footer loses a line quietly.

  The site test that *required* "Apache-2.0" in the footer is inverted: naming
  a licence now fails, and the list includes the URL forms, because the visible
  page had already been cleaned once while the JSON-LD still carried the claim.
  Verified by putting the badge back and watching it fail. The authorship check
  read the copyright holder out of `LICENSE`; it reads NOTICE and both READMEs
  instead, since what it guards is authorship, which has not changed.

### Added
- **The local machine survives leaving the app.** Going back from the console,
  or iOS taking the app away, saves the machine where it stands; the next visit
  picks it up mid-life instead of booting again. Only "Arrêter" ends it, and
  ending it clears the saved state — that word has to mean stopped, not hidden.
  A machine that powers off or reboots clears itself too, having nothing worth
  coming back to.

  Saving is synchronous on purpose. It runs exactly when the system is taking
  the app away, and returning before the file is written means not writing it;
  the wait is bounded because `stop()` lands within one 1024-instruction slice.
  It waits for the interpreter to leave `run()` before reading the machine —
  snapshotting a machine that is still executing would save a state that never
  existed — and gives up rather than saving if that does not happen in five
  seconds.

  A snapshot is keyed to the kernel it came from, through the file name rather
  than a marker file beside it: a mismatch then simply means "nothing saved",
  with no window where two files disagree. Kernel names come from files the
  user picked, so the name is sanitised — `../../etc/passwd` cannot escape the
  directory, and a test says so.

- **The app layer is tested in a simulated iPhone, not written off.**
  `WisqUI` is `#if os(iOS)`, so no Linux runner compiles it, and it had been
  described in its own comments as the part CI could not check. That was a
  choice, not a fact: it needs an iOS runtime, and CI has one. A new
  `WisqUITests` bundle drives the real `LocalVMModel` against the real
  interpreter, on its real thread, writing real files — booting, suspending,
  resuming, stopping, and being backgrounded and brought back. `xcodebuild`
  runs it in a booted simulator on every change (`scripts/test-app.sh`), and
  the simulator is chosen from what the machine actually has rather than named,
  so a runner image dropping a model does not break the build.

  Writing those tests immediately found a third defect the inline version had
  hidden: the exit that follows "Arrêter" was being swallowed as
  already-reported, so the model stayed in `running` holding a machine it would
  never release. Only a suspension's exit should be ignored, because only that
  one is an exit we asked for.

  Two seams made it testable rather than merely compilable: the model takes the
  directory it saves into, so a test cannot see or outlive another run's
  machine, and the scene-phase decision moved out of the view's `body` — a
  decision in a `body` is a decision nothing runs in a test.

- **`verify.sh` now lints, and there is a floor that runs without SwiftLint.**
  The script said "everything CI would run" and did not lint — and SwiftLint is
  a Homebrew formula, so on the Linux container most of this is written in
  there was no way to run that job at all. A trailing blank line reached a pull
  request and turned it red. `scripts/check-whitespace.sh` implements the three
  rules that are pure text — one trailing newline, no trailing whitespace, no
  double blank lines — over exactly the files `.swiftlint.yml` covers, tracked
  and untracked alike, because the file about to be pushed is the one not yet
  committed. `verify.sh` runs it first and then SwiftLint itself wherever it is
  installed.

- **The suspension rules are a tested type, not inline conditions.**
  `MachineLifecycle` decides what each event does to the saved machine — the
  user stopping it, the screen going away, iOS backgrounding the app, the guest
  halting itself — and the view model does what it says. It lives in `WisqVM`
  because the view model does not build on the runner that runs on every
  commit, and two defects had already reached a pull request while these rules
  were inline conditions there:

  "Arrêter" dismisses the console, so the stop and the departure arrived one
  after the other and the departure saved a snapshot of the machine the stop
  had just ended — the machine came back on the next launch despite having been
  stopped. And a machine put away when iOS backgrounded the app was never
  picked up when the app returned, leaving a dead terminal the user could only
  escape by leaving the screen. Neither was visible to the compiler; both are
  now one assertion each, and returning to the foreground resumes.

  Coming back from a suspension also keeps the console rather than clearing it:
  it is the same session, and blanking it would make a resumption look like the
  reboot the whole feature exists to avoid.

- **A suspended machine has somewhere to wait.** `SuspendedMachine` is the
  file the local VM is saved into and read back from, deliberately in `WisqVM`
  rather than in the app: the app layer only builds on Apple platforms, so
  anything living there cannot be tested on a runner that costs nothing, and
  "survive a first launch with nothing there" is worth testing rather than
  reasoning about. It is named for what it holds because `WisqCore` already has
  a `MachineStore`, which keeps the list of remote machines — two types with
  one name in one app is a reading error waiting to happen.

  The first version replaced the existing file, which fails on the one save
  every user makes: the first. `Data.write(options: .atomic)` does the work
  instead, writing to an auxiliary file and renaming, so the visible file is
  always whole — the previous machine if the new save never finished, never a
  torn mixture. That matters because the moment this runs is the moment iOS is
  taking the app away.

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

  The Swift core writes and reads the **same bytes**, and that is checked
  rather than intended: one test requires the two cores' snapshots of the same
  machine to be identical byte for byte, another makes each core resume from
  the other's file and continue to the same instruction count. A snapshot
  outlives the process that wrote it, so a format only one interpreter can
  read would break someone's saved machine the day the app switches cores.
  Proven to bite by swapping two control registers in the Swift writer, which
  fails both tests.

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

### Changed
- `scripts/test-rust-core.sh` filters on the test target rather than on one
  class. The target grew a second suite — snapshot agreement between the two
  cores — and a filter naming `DifferentialBootTests` had silently stopped
  covering it. Six tests now, not three.

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
