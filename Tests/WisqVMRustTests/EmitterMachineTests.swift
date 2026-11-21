import Foundation
import WisqVM
@testable import WisqVMRust
import XCTest

/// **La machine de l'émetteur, sans la vue** : le montage (`EmitterMachine`),
/// le magasin (`EmitterStore`), le pont (`EmitterBridge`) et le réglage
/// (`EmitterSetting`). La page elle-même, de bout en bout sous Bun, est dans
/// `EmitterPageTests`.
final class EmitterMachineTests: XCTestCase {
    private var folders: [URL] = []

    override func tearDown() {
        for folder in folders { try? FileManager.default.removeItem(at: folder) }
        folders = []
        super.tearDown()
    }

    private func folder(_ name: String) throws -> URL {
        let url = try EmitterFixtures.folder(name)
        folders.append(url)
        return url
    }

    private func write(_ bytes: [UInt8], _ name: String, in folder: URL) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url
    }

    private func plan(_ prepared: EmitterMachine.Prepared) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: prepared.plan()) as? [String: Any])
    }

    // MARK: - Le montage

    /// **Un ELF se pose segment par segment**, la page zéro par-dessus, et le
    /// plan dit tout ce que la page doit savoir — les adresses de 64 bits en
    /// texte.
    func testAnELFIsMountedSegmentBySegmentAndThePlanSaysIt() throws {
        let work = try folder("elf")
        let kernel = try write(EmitterFixtures.elf(EmitterFixtures.kernel(), bss: 0x2000), "vmlinux", in: work)
        let prepared = try EmitterMachine.prepare(
            .init(kernel: kernel, ramBytes: 64 << 20, clock: 1_795_178_096_000), scratch: work)
        XCTAssertEqual(prepared.pages, 1024)
        XCTAssertEqual(prepared.entry, EmitterFixtures.physical)
        XCTAssertEqual(prepared.kernelTop, EmitterFixtures.physical + UInt64(EmitterFixtures.kernel().count) + 0x2000)
        XCTAssertEqual(prepared.pieces.map(\.name), ["noyau-0", "page-zero"])
        XCTAssertEqual(
            prepared.pieces[0].source,
            .file(kernel, offset: 0x1000, length: UInt64(EmitterFixtures.kernel().count)),
            "le fichier d'origine, déjà un ELF : rien n'est recopié")
        XCTAssertEqual(prepared.pieces[1].at, 0x9000)
        XCTAssertEqual(
            prepared.commandLine, "earlycon=uart8250,io,0x3f8 keep_bootcon",
            "la ligne du montage, quand l'image n'en ajoute pas")

        let json = try plan(prepared)
        XCTAssertEqual(json["pages"] as? Int, 1024)
        XCTAssertEqual(json["entree"] as? String, "16777216")
        XCTAssertEqual(json["pageZero"] as? Int, 0x9000)
        XCTAssertEqual(json["heure"] as? Int, 1_795_178_096_000)
        XCTAssertTrue(json["disque"] is NSNull)
        let ecran = try XCTUnwrap(json["ecran"] as? [String: Any])
        XCTAssertEqual(ecran["largeur"] as? Int, 1280)
        XCTAssertEqual(ecran["hauteur"] as? Int, 800)
        XCTAssertEqual(ecran["base"] as? String, String(0xE000_0000), "la BAR0 de la carte")
        let segments = try XCTUnwrap(json["segments"] as? [[String: Any]])
        XCTAssertEqual(segments.map { $0["chemin"] as? String }, ["noyau-0", "page-zero"])
        XCTAssertEqual(segments.map { $0["a"] as? Int }, [0x0100_0000, 0x9000])
        XCTAssertEqual(segments.map { $0["octets"] as? Int }, [EmitterFixtures.kernel().count, 4096])
    }

    /// **Un `bzImage` est décompressé une fois**, dans le dossier de travail,
    /// et c'est de là que ses segments sont servis.
    func testABzImageIsInflatedIntoTheScratchAndServedFromThere() throws {
        let work = try folder("bz")
        let elf = EmitterFixtures.elf(EmitterFixtures.kernel())
        let kernel = try write(KernelPayloadTestsSupport.bzImage(gzip: elf), "vmlinuz", in: work)
        let scratch = work.appendingPathComponent("travail")
        let prepared = try EmitterMachine.prepare(.init(kernel: kernel, ramBytes: 64 << 20), scratch: scratch)
        let inflated = scratch.appendingPathComponent("vmlinux")
        XCTAssertEqual(try Data(contentsOf: inflated), Data(elf))
        XCTAssertEqual(
            prepared.pieces[0].source,
            .file(inflated, offset: 0x1000, length: UInt64(EmitterFixtures.kernel().count)))
    }

    /// **L'archive se pose juste au-dessus du noyau**, alignée sur une page,
    /// et la page zéro la dit au noyau ; la ligne de l'image suit celle du
    /// montage, dans la page.
    func testTheArchiveSitsAboveTheKernelAndThePageSaysWhere() throws {
        let work = try folder("initrd")
        let kernel = try write(EmitterFixtures.elf(EmitterFixtures.kernel(), bss: 0x1234), "vmlinux", in: work)
        let initrd = try write([UInt8](repeating: 0x30, count: 5000), "initrd", in: work)
        let disk = try write([UInt8](repeating: 0, count: 4096), "disque.iso", in: work)
        let prepared = try EmitterMachine.prepare(
            .init(kernel: kernel, initrd: initrd, disk: disk, commandLine: "console=ttyS0 quiet",
                  ramBytes: 64 << 20),
            scratch: work)
        let top = prepared.kernelTop
        XCTAssertEqual(prepared.initrdAt, (top + 0xFFF) & ~0xFFF)
        XCTAssertEqual(prepared.pieces.map(\.name), ["noyau-0", "initramfs", "page-zero"])
        XCTAssertEqual(prepared.pieces[1].source, .file(initrd, offset: 0, length: 5000))
        XCTAssertEqual(prepared.commandLine, "earlycon=uart8250,io,0x3f8 console=ttyS0 quiet",
                       "keep_bootcon part : l'image nomme console=ttyS0")
        guard case .bytes(let page) = prepared.pieces[2].source else { return XCTFail("la page zéro") }
        func le32(_ at: Int) -> UInt32 { page[at..<(at + 4)].enumerated().reduce(0) { $0 | UInt32($1.1) << (8 * $1.0) } }
        XCTAssertEqual(UInt64(le32(0x218)), prepared.initrdAt, "ramdisk_image")
        XCTAssertEqual(le32(0x21C), 5000, "ramdisk_size")
        XCTAssertEqual(le32(0x228), 0x9800, "cmd_line_ptr")
        let json = try plan(prepared)
        let disque = try XCTUnwrap(json["disque"] as? [String: Any])
        XCTAssertEqual(disque["chemin"] as? String, "disque")
        XCTAssertEqual(disque["octets"] as? Int, 4096)
    }

    /// **Ce qui ne peut pas tourner est refusé sous son nom**, avant qu'une
    /// page s'ouvre.
    func testWhatCannotRunIsRefusedByName() throws {
        let work = try folder("refus")
        let kernel = try write(EmitterFixtures.elf(EmitterFixtures.kernel()), "vmlinux", in: work)
        let big = try write([UInt8](repeating: 1, count: 1 << 20), "gros", in: work)
        let tiny = try write([1, 2, 3], "petit.iso", in: work)
        // Dix-sept mébioctets, creux : plus que ce qui reste au-dessus du
        // noyau dans 32 Mio.
        let huge = work.appendingPathComponent("enorme")
        _ = FileManager.default.createFile(atPath: huge.path, contents: nil)
        let handle = try FileHandle(forWritingTo: huge)
        try handle.truncate(atOffset: 17 << 20)
        try handle.close()
        // Ce que la ligne du montage (« earlycon=… keep_bootcon », et une
        // espace) laisse à celle de l'image.
        let roomForTheImage = EmitterMachine.commandLineRoom - "earlycon=uart8250,io,0x3f8 keep_bootcon ".utf8.count
        // `nil` : celui-là passe — la borne d'à côté.
        let cases: [(EmitterMachine.Setup, EmitterMachine.Refusal?)] = [
            (.init(kernel: work.appendingPathComponent("absent")), .unreadable("absent")),
            (.init(kernel: big), .kernel(.notAKernel)),
            (.init(kernel: kernel, ramBytes: 4 << 30), .foldMisses(folded: 0x8100_0000)),
            (.init(kernel: kernel, ramBytes: 48 << 20), .ramIsNotAPowerOfTwo(48 << 20)),
            (.init(kernel: kernel, ramBytes: 16 << 20), .ramTooSmall(needed: EmitterFixtures.physical + UInt64(EmitterFixtures.kernel().count))),
            (.init(kernel: kernel, ramBytes: 1000), .ramIsNotAPowerOfTwo(1000)),
            (.init(kernel: kernel, commandLine: "a\u{0}b", ramBytes: 64 << 20), .commandLineCarriesNul),
            // Le refus 2 du Rust : la ligne entière dépasse sa place d'un octet.
            (.init(kernel: kernel, commandLine: String(repeating: "a", count: roomForTheImage + 1),
                   ramBytes: 64 << 20), .commandLineTooLong),
            (.init(kernel: kernel, commandLine: String(repeating: "a", count: roomForTheImage),
                   ramBytes: 64 << 20), nil),
            (.init(kernel: kernel, ramBytes: 64 << 20, screen: .init(width: 70000, height: 1)), .screen),
            (.init(kernel: kernel, initrd: big, ramBytes: 32 << 20, screen: nil), nil),
            (.init(kernel: kernel, initrd: huge, ramBytes: 32 << 20), .archiveDoesNotFit(bytes: 17 << 20)),
            (.init(kernel: kernel, disk: tiny, ramBytes: 64 << 20), .diskTooSmall(3)),
            (.init(kernel: kernel, disk: work.appendingPathComponent("absent.iso"), ramBytes: 64 << 20),
             .unreadable("absent.iso")),
        ]
        // Un ELF sans segment chargeable (son seul en-tête est PT_DYNAMIC), et
        // un ELF dont le point d'entrée tombe hors de son segment.
        var dynamic = EmitterFixtures.elf(EmitterFixtures.kernel())
        dynamic[64] = 2
        let unloadable = try write(dynamic, "dynamique", in: work)
        var astray = EmitterFixtures.elf(EmitterFixtures.kernel())
        astray.replaceSubrange(24..<32, with: EmitterFixtures.le64(EmitterFixtures.physical + 0x10_0000))
        let elsewhere = try write(astray, "ailleurs", in: work)
        let empty = try write([], "vide.cpio", in: work)
        let refused: [(EmitterMachine.Setup, EmitterMachine.Refusal)] = [
            (.init(kernel: unloadable, ramBytes: 64 << 20), .noLoadableSegment),
            (.init(kernel: elsewhere, ramBytes: 64 << 20),
             .noSegmentCarriesTheEntry(EmitterFixtures.physical + 0x10_0000)),
            // Une archive vide n'est pas une archive : le noyau la déclarerait
            // de zéro octet, et chercherait sa racine ailleurs sans le dire.
            (.init(kernel: kernel, initrd: empty, ramBytes: 64 << 20), .unreadable("vide.cpio")),
        ]
        for (setup, expected) in cases + refused.map({ ($0.0, Optional($0.1)) }) {
            guard let expected else {
                XCTAssertNoThrow(try EmitterMachine.prepare(setup, scratch: work), "\(setup)")
                continue
            }
            XCTAssertThrowsError(try EmitterMachine.prepare(setup, scratch: work), "\(setup)") {
                XCTAssertEqual($0 as? EmitterMachine.Refusal, expected, "\(setup)")
            }
        }
    }

    /// **Le montage d'`IsoBoot` passe tel quel**, et la RAM est au moins celle
    /// que l'image demande.
    func testTheSetupOfABootKeepsWhatTheImageAsked() {
        var boot = IsoBoot.Boot(
            kind: .unknown, kernel: URL(fileURLWithPath: "/k"), disk: URL(fileURLWithPath: "/d.iso"),
            commandLine: "root=live:CDLABEL=X", initrd: URL(fileURLWithPath: "/i"))
        boot.minimumRAM = 2 << 30
        let setup = EmitterMachine.Setup(boot: boot, ramBytes: 1 << 30)
        XCTAssertEqual(setup.kernel.path, "/k")
        XCTAssertEqual(setup.initrd?.path, "/i")
        XCTAssertEqual(setup.disk?.path, "/d.iso")
        XCTAssertEqual(setup.commandLine, "root=live:CDLABEL=X")
        XCTAssertEqual(setup.ramBytes, 2 << 30)
        XCTAssertEqual(setup.screen, .standard)
    }

    /// **La ligne d'une image passe telle quelle**, ses `---` et ses `--`
    /// compris. Elle passait par la syntaxe de retrait de `kernel-entry`, où un
    /// mot qui commence par `-` enlève un mot du montage, et une ISO d'Ubuntu
    /// ou de Debian ne s'ouvrait pas.
    func testAnImageLineWithDashesPassesAsItIs() throws {
        let work = try folder("tirets")
        let kernel = try write(EmitterFixtures.elf(EmitterFixtures.kernel()), "vmlinux", in: work)
        for image in ["boot=casper quiet splash ---", "vga=788 --- quiet", "init=/bin/sh -- -x"] {
            let prepared = try EmitterMachine.prepare(
                .init(kernel: kernel, commandLine: image, ramBytes: 64 << 20), scratch: work)
            XCTAssertEqual(prepared.commandLine, "earlycon=uart8250,io,0x3f8 keep_bootcon \(image)")
        }
        // Le chemin de l'application : la ligne d'`IsoBoot`, la console de
        // l'émetteur au bout.
        let iso = IsoBoot.commandLine(from: "boot=casper quiet splash ---")
        let prepared = try EmitterMachine.prepare(
            .init(kernel: kernel, commandLine: EmitterMachine.emitterLine(iso), ramBytes: 64 << 20), scratch: work)
        XCTAssertTrue(prepared.commandLine.hasPrefix("earlycon=uart8250,io,0x3f8 boot=casper splash --- "),
                      prepared.commandLine)
        XCTAssertTrue(prepared.commandLine.hasSuffix(" console=ttyS0,115200"), prepared.commandLine)
    }

    /// **La console du cœur Swift cède la place à celle de l'émetteur**, et
    /// seulement elle : le reste de la ligne passe mot pour mot, et une ligne
    /// qui ne finit pas par elle passe entière.
    func testTheCoresConsoleGivesWayToTheEmitters() {
        let core = X86BootLoader.defaultCommandLine
        XCTAssertEqual(EmitterMachine.emitterLine("root=live:X  rw \(core)"), "root=live:X  rw console=ttyS0,115200")
        XCTAssertEqual(EmitterMachine.emitterLine(core), "console=ttyS0,115200")
        XCTAssertEqual(EmitterMachine.emitterLine("root=/dev/vda1 rw"), "root=/dev/vda1 rw", "un système installé")
        XCTAssertEqual(EmitterMachine.emitterLine("x\(core)"), "x\(core)", "collée, ce n'est pas la sienne")
        XCTAssertNil(EmitterMachine.emitterLine(nil))
        let boot = IsoBoot.Boot(kind: .unknown, kernel: URL(fileURLWithPath: "/k"), disk: nil,
                                commandLine: "a \(core)", initrd: nil)
        XCTAssertEqual(EmitterMachine.Setup(boot: boot).commandLine, "a console=ttyS0,115200")
    }

    /// **La RAM choisie pour l'appareil** : une puissance de deux, un
    /// gibioctet si l'on peut, deux au plus, jamais moins que ce que l'image
    /// demande.
    func testTheRAMIsAPowerOfTwoTheFoldAccepts() {
        XCTAssertEqual(EmitterMachine.chooseRAM(ceiling: 4 << 30, minimum: 0), 1 << 30)
        XCTAssertEqual(EmitterMachine.chooseRAM(ceiling: 3 << 29, minimum: 0), 1 << 30)
        XCTAssertEqual(EmitterMachine.chooseRAM(ceiling: 700 << 20, minimum: 0), 512 << 20)
        XCTAssertEqual(EmitterMachine.chooseRAM(ceiling: 64 << 20, minimum: 0), 64 << 20)
        XCTAssertNil(EmitterMachine.chooseRAM(ceiling: 32 << 20, minimum: 0), "moins de 64 Mio")
        XCTAssertEqual(EmitterMachine.chooseRAM(ceiling: 8 << 30, minimum: 2 << 30), 2 << 30)
        XCTAssertNil(EmitterMachine.chooseRAM(ceiling: 8 << 30, minimum: 3 << 30), "au-delà du repli")
        XCTAssertNil(EmitterMachine.chooseRAM(ceiling: 8 << 30, minimum: 4 << 30),
                     "quatre gibioctets tiendraient, mais le repli les refuse")
        XCTAssertNil(EmitterMachine.chooseRAM(ceiling: 700 << 20, minimum: 1 << 30), "un système vivant")
        XCTAssertNil(EmitterMachine.chooseRAM(ceiling: 0, minimum: 0))
    }

    /// **Une ISO s'ouvre comme l'application l'ouvre** : le noyau et l'archive
    /// déballés par `IsoBoot`, l'ISO en disque, la ligne de l'image (sans
    /// `quiet`, la console de wisq au bout), la RAM choisie.
    func testAnISOOpensTheWayTheApplicationOpensIt() throws {
        let work = try folder("iso")
        var gravure = IsoGravure()
        gravure.kernel = Data(EmitterFixtures.elf(EmitterFixtures.kernel()))
        let image = try gravure.write()
        defer { try? FileManager.default.removeItem(at: image) }
        let prepared = try EmitterMachine.open(image, unpackingInto: work, ceiling: 4 << 30)
        XCTAssertEqual(prepared.pages, 16384, "un gibioctet")
        XCTAssertEqual(prepared.disk, image)
        XCTAssertEqual(prepared.diskBytes, UInt64(try Data(contentsOf: image).count))
        XCTAssertEqual(prepared.pieces.map(\.name), ["noyau-0", "initramfs", "page-zero"])
        XCTAssertEqual(prepared.pieces[1].source.length, UInt64(IsoGravure.initramfs.count))
        // **Une console, une seule fois chaque ligne** : la console précoce du
        // montage, rendue quand `ttyS0` arrive (pas de `keep_bootcon`), et
        // pas l'`earlyprintk` gardé du cœur Swift.
        XCTAssertTrue(prepared.commandLine.hasPrefix("earlycon=uart8250,io,0x3f8 modules=loop,squashfs "),
                      prepared.commandLine)
        XCTAssertFalse(prepared.commandLine.contains("quiet"), prepared.commandLine)
        XCTAssertFalse(prepared.commandLine.contains("keep_bootcon"), prepared.commandLine)
        XCTAssertFalse(prepared.commandLine.contains("earlyprintk"), prepared.commandLine)
        XCTAssertTrue(prepared.commandLine.hasSuffix(" console=ttyS0,115200"), prepared.commandLine)

        XCTAssertThrowsError(try EmitterMachine.open(image, unpackingInto: work, ceiling: 32 << 20)) {
            XCTAssertEqual($0 as? EmitterMachine.Refusal, .notEnoughRoom(ceiling: 32 << 20, minimum: 0))
        }
        var nothing = IsoGravure()
        nothing.carriesKernel = false
        let empty = try nothing.write()
        defer { try? FileManager.default.removeItem(at: empty) }
        XCTAssertThrowsError(try EmitterMachine.open(empty, unpackingInto: work, ceiling: 4 << 30)) {
            guard case .image(let sentence)? = $0 as? EmitterMachine.Refusal else { return XCTFail("\($0)") }
            XCTAssertFalse(sentence.isEmpty)
        }
    }

    func testARefusalReadsAsASentence() {
        XCTAssertEqual(EmitterMachine.explanation(.kernel(.unsupportedCompression("xz"))),
                       "Le noyau est compressé en xz, que la machine de l'émetteur ne sait pas défaire.")
        XCTAssertEqual(EmitterMachine.explanation(.notEnoughRoom(ceiling: 512 << 20, minimum: 1 << 30)),
                       "L'appareil laisse 512 Mio à la machine, et l'image en demande au moins 1024 Mio.")
        XCTAssertEqual(EmitterMachine.explanation(.image("phrase")), "phrase")
        XCTAssertEqual(EmitterMachine.explanation(.commandLineTooLong),
                       "La ligne de commande de l'image dépasse les 2047 octets que le noyau lit.")
        XCTAssertEqual(EmitterMachine.explanation(.commandLineCarriesNul),
                       "La ligne de commande de l'image porte un caractère nul, où le noyau la couperait.")
    }

    // MARK: - Le magasin

    /// **Les fichiers de la page sont ceux du dépôt**, tels que la bibliothèque
    /// les porte, et le magasin les sert sous leur type.
    func testTheStoreServesThePageFilesWithTheirTypes() throws {
        let work = try folder("magasin")
        let kernel = try write(EmitterFixtures.elf(EmitterFixtures.kernel()), "vmlinux", in: work)
        let prepared = try EmitterMachine.prepare(.init(kernel: kernel, ramBytes: 64 << 20), scratch: work)
        let store = prepared.store(module: Data([0, 0x61, 0x73, 0x6D]))
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for name in EmitterMachine.pageFiles {
            let response = store.respond(method: "GET", url: URL(string: "wisq-machine://machine/\(name)")!)
            XCTAssertEqual(response.status, 200, name)
            XCTAssertEqual(response.body, try Data(contentsOf: root.appendingPathComponent("web/\(name)")), name)
        }
        let types = [
            "machine.html": "text/html; charset=utf-8", "machine.js": "text/javascript; charset=utf-8",
            "plan.json": "application/json", "wisq_page.wasm": "application/wasm",
            "noyau-0": "application/octet-stream",
        ]
        for (name, type) in types {
            XCTAssertEqual(store.respond(method: "GET", url: URL(string: "wisq-machine://machine/\(name)")!).contentType,
                           type, name)
        }
        XCTAssertEqual(store.respond(method: "GET", url: URL(string: "wisq-machine://machine/")!).body,
                       EmitterMachine.asset("machine.html"), "la racine est la page")
        let segment = store.respond(method: "GET", url: URL(string: "wisq-machine://machine/noyau-0")!)
        XCTAssertEqual([UInt8](segment.body), EmitterFixtures.kernel(), "le segment, lu dans son fichier")
        XCTAssertEqual(store.respond(method: "GET", url: URL(string: "wisq-machine://machine/autre.js")!).status, 404)
        XCTAssertEqual(store.respond(method: "PUT", url: URL(string: "wisq-machine://machine/plan.json")!).status, 405)
        XCTAssertNil(EmitterMachine.asset("autre.js"))
    }

    /// **Le disque par plages**, sur le contrat d'`arriereParUrl` : une
    /// lecture rend ses octets, une écriture va dans la couche et jamais dans
    /// le fichier, une lecture d'après la voit — y compris à cheval sur un
    /// secteur à moitié écrit.
    func testTheDiskIsServedByRangesAndWritesStayInTheLayer() throws {
        let work = try folder("disque")
        let bytes = (0..<4096).map { UInt8($0 & 0xFF) }
        let disk = try write(bytes, "disque.iso", in: work)
        let store = EmitterStore(files: [:], disk: (url: disk, bytes: 4096))
        func url(_ query: String) -> URL { URL(string: "wisq-machine://machine/disque?\(query)")! }

        let read = store.respond(method: "GET", url: url("a=1000&n=24"))
        XCTAssertEqual(read.status, 200)
        XCTAssertEqual([UInt8](read.body), Array(bytes[1000..<1024]))

        // Six octets à cheval sur les secteurs 1 et 2.
        let wrote = store.respond(method: "PUT", url: url("a=1021"), body: Data([9, 9, 9, 9, 9, 9]))
        XCTAssertEqual(wrote.status, 200)
        XCTAssertEqual(store.layeredSectors, 2)
        XCTAssertEqual([UInt8](try Data(contentsOf: disk)), bytes, "le fichier n'est jamais écrit")
        let again = store.respond(method: "GET", url: url("a=1016&n=16"))
        XCTAssertEqual([UInt8](again.body), Array(bytes[1016..<1021]) + [9, 9, 9, 9, 9, 9] + Array(bytes[1027..<1032]))
        let whole = store.respond(method: "GET", url: url("a=0&n=4096"))
        XCTAssertEqual(whole.body.count, 4096)
        XCTAssertEqual([UInt8](whole.body[1020..<1028]), [bytes[1020], 9, 9, 9, 9, 9, 9, bytes[1027]])
        XCTAssertEqual([store.reads, store.writes], [3, 1])
        XCTAssertEqual(store.bytesRead, 24 + 16 + 4096)

        // Les refus, nommés.
        XCTAssertEqual(store.respond(method: "GET", url: url("a=4090&n=8")).status, 416, "au-delà du disque")
        XCTAssertEqual(store.respond(method: "GET", url: url("a=4096&n=1")).status, 416)
        XCTAssertEqual(store.respond(method: "GET", url: url("a=18446744073709551615&n=2")).status, 416,
                       "un début au maximum ne déborde pas, il est refusé")
        XCTAssertEqual(store.respond(method: "GET", url: url("a=x&n=8")).status, 400)
        XCTAssertEqual(store.respond(method: "GET", url: url("a=0")).status, 400, "sans longueur")
        XCTAssertEqual(store.respond(method: "GET", url: url("a=0&n=0")).status, 400)
        XCTAssertEqual(store.respond(method: "GET", url: url("a=0&n=67108865")).status, 400, "plus de 64 Mio")
        XCTAssertEqual(store.respond(method: "PUT", url: url("a=4095"), body: Data([1, 2])).status, 416)
        XCTAssertEqual(store.respond(method: "PUT", url: url("a=0"), body: Data()).status, 400)
        XCTAssertEqual(store.respond(method: "DELETE", url: url("a=0")).status, 405)
        XCTAssertEqual(store.layeredSectors, 2, "aucun refus n'a rien écrit")
    }

    /// **Une écriture de plus de 64 Mio est refusée**, même sur un disque
    /// assez grand pour la prendre : c'est une page qui a divergé, et la
    /// couche, en mémoire, la garderait entière.
    func testAWriteBeyondTheLargestRangeIsRefusedEvenOnABigDisk() throws {
        let work = try folder("grande")
        let disk = work.appendingPathComponent("grand.img")
        _ = FileManager.default.createFile(atPath: disk.path, contents: nil)
        let handle = try FileHandle(forWritingTo: disk)
        try handle.truncate(atOffset: EmitterStore.largestRange + (1 << 20))
        try handle.close()
        let store = EmitterStore(files: [:], disk: (url: disk, bytes: EmitterStore.largestRange + (1 << 20)))
        let url = URL(string: "wisq-machine://machine/disque?a=0")!
        let response = store.respond(method: "PUT", url: url, body: Data(count: Int(EmitterStore.largestRange) + 1))
        XCTAssertEqual(response.status, 416)
        XCTAssertEqual(store.layeredSectors, 0)
        XCTAssertEqual(store.writes, 0)
    }

    /// **Un fichier qui ne rend pas ce qu'il promet est un 500**, pour le
    /// disque comme pour un morceau : il ne rend jamais moins, ni un corps vide
    /// sous un 200, que la page poserait comme s'il était juste.
    func testAFileShorterThanPromisedIsRefusedNotShortened() throws {
        let work = try folder("court")
        let short = try write([UInt8](repeating: 7, count: 1000), "court.img", in: work)
        let store = EmitterStore(
            files: ["noyau-0": .file(short, offset: 512, length: 1024)],
            disk: (url: short, bytes: 4096))
        let read = store.respond(method: "GET", url: URL(string: "wisq-machine://machine/disque?a=900&n=200")!)
        XCTAssertEqual(read.status, 500, "le disque rend 100 octets pour 200")
        XCTAssertTrue(String(decoding: read.body, as: UTF8.self).contains("100 octets à 900 pour 200"),
                      String(decoding: read.body, as: UTF8.self))
        XCTAssertEqual(store.reads, 0)
        let gone = store.respond(method: "GET", url: URL(string: "wisq-machine://machine/disque?a=2000&n=8")!)
        XCTAssertEqual(gone.status, 500, "au-delà de la fin du fichier")
        let piece = store.respond(method: "GET", url: URL(string: "wisq-machine://machine/noyau-0")!)
        XCTAssertEqual(piece.status, 500, "le morceau rend 488 octets pour 1024")
        XCTAssertThrowsError(try EmitterStore.read(short, at: 0, count: 1001))
        XCTAssertEqual(try EmitterStore.read(short, at: 0, count: 1000).count, 1000)
    }

    func testTheSectorsOfARangeAreCutAtTheirEdges() {
        let cut = EmitterStore.sectors(at: 510, count: 516)
        XCTAssertEqual(cut.map(\.0), [0, 1, 2])
        XCTAssertEqual(cut.map(\.1), [510, 512, 1024])
        XCTAssertEqual(cut.map(\.2), [512, 1024, 1026])
        XCTAssertTrue(EmitterStore.sectors(at: 7, count: 0).isEmpty)
    }

    // MARK: - Le pont

    func testThePagesMessagesAreRead() throws {
        XCTAssertEqual(try EmitterBridge.message(from: ["kind": "prête", "pages": 1024, "segments": 3]),
                       .ready(pages: 1024, pieces: 3))
        XCTAssertEqual(try EmitterBridge.message(from: ["kind": "console", "octets": "aGk=", "perdus": 2]),
                       .console(Data("hi".utf8), lost: 2))
        XCTAssertEqual(try EmitterBridge.message(from: ["kind": "écran", "largeur": 1280.0, "hauteur": 800]),
                       .screen(width: 1280, height: 800))
        XCTAssertEqual(
            try EmitterBridge.message(from: [
                "kind": "arrêt", "stopped": "refusée", "at": "18446744071578845184",
                "refus": ["a": "0xffffffff81000000", "pourquoi": "CannotDecode"],
            ]),
            .stopped(why: "refusée", at: 0xFFFF_FFFF_8100_0000, refusal: "0xffffffff81000000 : CannotDecode"))
        XCTAssertEqual(try EmitterBridge.message(from: ["kind": "arrêt", "stopped": "x", "at": "5", "refus": NSNull()]),
                       .stopped(why: "x", at: 5, refusal: nil))
        XCTAssertEqual(try EmitterBridge.message(from: ["kind": "panne", "pourquoi": "p"]), .failure("p"))
        let unreadable: [([String: Any], EmitterBridge.Unreadable)] = [
            ([:], .noKind),
            (["kind": "autre"], .unknownKind("autre")),
            (["kind": "arrêt", "stopped": "x", "at": 5], .missingField("at")),
            (["kind": "console", "octets": "%%%"], .missingField("octets")),
            (["kind": "écran", "largeur": 1.5, "hauteur": 2], .missingField("largeur")),
            (["kind": "prête", "pages": 1], .missingField("segments")),
            (["kind": "panne"], .missingField("pourquoi")),
        ]
        for (body, expected) in unreadable {
            XCTAssertThrowsError(try EmitterBridge.message(from: body)) {
                XCTAssertEqual($0 as? EmitterBridge.Unreadable, expected, "\(body)")
            }
        }
    }

    /// **Ce qu'on envoie à la page ne recolle rien de ce qu'on lui donne** :
    /// le texte part en littéral JSON, un toucher fou est ramené au bord.
    func testWhatIsSentToThePageIsSafeByConstruction() {
        XCTAssertEqual(EmitterBridge.typing("a\"b\\c\n<script>"),
                       #"window.wisq.taper(["a\"b\\c\n<script>"][0])"#)
        XCTAssertEqual(EmitterBridge.key(.up), "window.wisq.touches([[72,true,true],[72,true,false]])")
        XCTAssertEqual(EmitterBridge.key(.control("c")),
                       "window.wisq.touches([[29,false,true],[46,false,true],[46,false,false],[29,false,false]])")
        XCTAssertEqual(EmitterBridge.touch(x: 0.25, y: 2, buttons: 1), "window.wisq.toucher(0.25,1.0,1)")
        XCTAssertEqual(EmitterBridge.touch(x: .nan, y: -.infinity, buttons: 0), "window.wisq.toucher(0.5,0.5,0)")
        XCTAssertEqual(EmitterBridge.scroll(notches: -1000), "window.wisq.defiler(-127)")
        XCTAssertEqual(EmitterBridge.scroll(notches: 1000), "window.wisq.defiler(127)")
        XCTAssertEqual(EmitterBridge.scroll(notches: 3), "window.wisq.defiler(3)")
        XCTAssertEqual(EmitterBridge.stop, "window.wisq && window.wisq.arreter()")
    }

    func testHardwareKeysAreTheirSetOneCodes() {
        func codes(_ keysym: UInt32) -> [UInt8] { EmitterBridge.events(forKeysym: keysym, down: true).map(\.code.set1) }
        XCTAssertEqual(codes(0x61), [0x1E], "a")
        XCTAssertEqual(codes(0x41), [0x1E], "A : la même touche, Maj arrive à part")
        XCTAssertEqual(codes(0x31), [0x02], "1")
        XCTAssertEqual(codes(0xFF0D), [0x1C], "Entrée")
        XCTAssertEqual(codes(0xFF08), [0x0E], "Retour arrière")
        XCTAssertEqual(codes(0xFFBE), [0x3B], "F1")
        XCTAssertEqual(codes(0xFFC9), [0x58], "F12")
        XCTAssertEqual(codes(0xFFE1), [0x2A], "Maj")
        XCTAssertEqual(codes(0xFFE2), [0x2A], "Maj droite : la même touche pour l'invité")
        XCTAssertEqual(codes(0xFFE4), [0x1D], "Ctrl droite")
        XCTAssertEqual(codes(0xFFEA), [0x38], "Alt droite")
        let up = EmitterBridge.events(forKeysym: 0xFF52, down: false)
        XCTAssertEqual(up.map(\.code), [.up])
        XCTAssertEqual(up.map(\.down), [false])
        XCTAssertTrue(EmitterBridge.events(forKeysym: 0x1008FF11, down: true).isEmpty, "rien au hasard")
        XCTAssertTrue(EmitterBridge.events(forKeysym: 0xE9, down: true).isEmpty, "é n'est pas sur un QWERTY")
    }

    // MARK: - Le réglage

    func testTheSettingIsOffByDefaultAndOpensOnlyWhatThePCBoots() {
        XCTAssertFalse(EmitterSetting.defaultValue)
        XCTAssertEqual(EmitterSetting.key, "wisq.machine.emetteur")
        let iso = KernelImageKind.discImage("ISO 9660")
        let pc = KernelImageKind.identify(prefix: Data(KernelPayloadTestsSupport.bzImage(gzip: EmitterFixtures.elf([0xF4]))))
        XCTAssertEqual(pc.core, .x86_64, "un bzImage x86-64")
        XCTAssertTrue(EmitterSetting.opens(iso, enabled: true, installed: false, moduleEmbedded: true))
        XCTAssertTrue(EmitterSetting.opens(pc, enabled: true, installed: false, moduleEmbedded: true))
        XCTAssertFalse(EmitterSetting.opens(iso, enabled: false, installed: false, moduleEmbedded: true), "éteint")
        XCTAssertFalse(EmitterSetting.opens(iso, enabled: true, installed: true, moduleEmbedded: true),
                       "une machine installée reste au cœur Swift")
        XCTAssertFalse(EmitterSetting.opens(iso, enabled: true, installed: false, moduleEmbedded: false),
                       "une construction sans module")
        XCTAssertFalse(EmitterSetting.opens(.unknown, enabled: true, installed: false, moduleEmbedded: true))
        // **Un noyau RISC-V a son cœur**, et l'émetteur ne traduit que du
        // x86-64 : il part dans le sien, pas dans celui-ci.
        let riscv = KernelImageKind.executable(GuestArchitecture(.riscv, bits: 32))
        XCTAssertEqual(riscv.core, .riscv32)
        XCTAssertFalse(EmitterSetting.opens(riscv, enabled: true, installed: false, moduleEmbedded: true))
        XCTAssertFalse(EmitterSetting.opens(nil, enabled: true, installed: false, moduleEmbedded: true))
    }

    /// **Le module n'est pas dans une construction de tous les jours** : la
    /// bibliothèque de `cargo build` n'embarque rien sans `WISQ_PAGE_WASM`, et
    /// l'application le dit au lieu d'ouvrir une page vide.
    func testAnEverydayBuildCarriesNoModule() {
        XCTAssertEqual(EmitterMachine.isInThisBuild, EmitterMachine.embeddedModule != nil)
        if ProcessInfo.processInfo.environment["WISQ_PAGE_WASM"] == nil {
            XCTAssertNil(EmitterMachine.embeddedModule)
            XCTAssertFalse(EmitterMachine.isInThisBuild)
        }
        XCTAssertNotNil(EmitterMachine.asset("host.js"))
    }
}

/// Un `bzImage` autour d'un ELF, pour les tests de ce dossier : le même
/// assemblage que `KernelPayloadTests`, qui vit dans une autre cible.
enum KernelPayloadTestsSupport {
    static func le32(_ value: UInt32) -> [UInt8] { withUnsafeBytes(of: value.littleEndian, Array.init) }

    static func bzImage(gzip data: [UInt8]) -> [UInt8] {
        // Un membre gzip de blocs stockés, d'au plus 65 535 octets chacun.
        var member: [UInt8] = [0x1F, 0x8B, 8, 0, 0, 0, 0, 0, 0, 3]
        var at = 0
        repeat {
            let piece = Array(data[at..<min(at + 65535, data.count)])
            at += piece.count
            let length = UInt16(piece.count)
            member += [at == data.count ? 1 : 0, UInt8(length & 0xFF), UInt8(length >> 8),
                       UInt8(~length & 0xFF), UInt8(~length >> 8)]
            member += piece
        } while at < data.count
        member += le32(CRC32.checksum(data)) + le32(UInt32(data.count))
        var setup = [UInt8](repeating: 0, count: 1024)
        setup[0x1F1] = 1
        let protected = 16 + member.count
        let paragraphs = UInt32((protected + 15) / 16)
        setup.replaceSubrange(0x1F4..<0x1F8, with: le32(paragraphs))
        setup[0x1FE] = 0x55
        setup[0x1FF] = 0xAA
        setup.replaceSubrange(0x202..<0x206, with: Array("HdrS".utf8))
        setup[0x206] = 0x0F
        setup[0x207] = 0x02
        // Le point d'entrée 64 bits annoncé (XLF_KERNEL_64), comme un vrai.
        setup[0x236] = 1
        setup.replaceSubrange(0x248..<0x24C, with: le32(16))
        setup.replaceSubrange(0x24C..<0x250, with: le32(UInt32(member.count)))
        return setup + [UInt8](repeating: 0x90, count: 16) + member
            + [UInt8](repeating: 0, count: Int(paragraphs) * 16 - protected)
    }
}
