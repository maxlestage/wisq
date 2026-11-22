import CWisqVM
import Foundation
import WisqVM
@testable import WisqVMRust
import XCTest

/// **La machine PC en Rust derrière `GuestMachine`**, jugée contre le cœur
/// Swift : le même noyau factice (`Tests/Fixtures/pc-noyau-factice.bin`, que
/// `crates/wisq-vm/tests/pc_poste.rs` vérifie octet pour octet) démarré sur
/// `X86Machine` et sur `RustPCMachine`, la console comparée. Puis ce que
/// `LocalVMModel` emploie : l'écran, le clavier, la tablette, l'arrêt d'un
/// autre fil, l'instantané, et le réglage qui choisit le cœur.
final class RustPCMachineTests: XCTestCase {
    private static let ram = 128 << 20
    private static let frozen = Date(timeIntervalSince1970: 1_795_230_600)

    /// Le noyau factice : sa bannière, sa ligne, cinq battements, « FIN ».
    private static func tinyKernel() throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/pc-noyau-factice.bin"))
    }

    /// Le même `bzImage`, son code remplacé par `cli ; jmp .` : une course
    /// qui ne finit que si on l'arrête. Le code commence à l'entrée 64 bits,
    /// 0x200 octets dans le noyau en mode protégé, qui suit les deux secteurs
    /// d'en-tête.
    private static func endlessKernel() throws -> Data {
        var image = try tinyKernel()
        image.replaceSubrange(0x600..<0x603, with: [0xFA, 0xEB, 0xFE])
        return image
    }

    /// Une console recueillie de n'importe quel fil.
    private final class Console: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes = Data()
        func append(_ data: Data) {
            lock.lock()
            bytes.append(data)
            lock.unlock()
        }
        var text: String {
            lock.lock()
            defer { lock.unlock() }
            return String(decoding: bytes, as: UTF8.self)
        }
    }

    private func rust(_ console: Console, ram: Int = ram) throws -> RustPCMachine {
        let machine = try XCTUnwrap(RustPCMachine(ramSize: ram, onOutput: { console.append($0) }))
        machine.freezeHostTime(at: Self.frozen)
        return machine
    }

    private func swift(_ console: Console) -> X86Machine {
        let machine = X86Machine(ramSize: Self.ram, onOutput: { console.append($0) })
        machine.frozenHostTime = Self.frozen
        return machine
    }

    // MARK: - Les deux cœurs, la même console

    /// **Le même noyau dit la même chose sur les deux cœurs**, jusqu'à son
    /// extinction, et retire autant d'instructions.
    func testTheTinyKernelSaysTheSameOnBothCores() throws {
        let kernel = try Self.tinyKernel()
        let swiftConsole = Console()
        let rustConsole = Console()
        let reference = swift(swiftConsole)
        let machine = try rust(rustConsole)
        let cores: [GuestMachine] = [reference, machine]
        for core in cores {
            try core.load(kernelImage: kernel, commandLine: "a=b", initialRamdisk: nil)
            XCTAssertEqual(core.runGuest(instructionBudget: 50_000_000), .powerOff)
        }
        XCTAssertEqual(swiftConsole.text, "wisq-noyau-factice\na=b\n.....\nFIN\n")
        XCTAssertEqual(rustConsole.text, swiftConsole.text)
        XCTAssertEqual(machine.retiredInstructions, reference.retiredInstructions)
        XCTAssertEqual(machine.liveProgress?.retired, machine.retiredInstructions)
    }

    /// **Sous un écran, les deux mettent `console=tty0` devant la ligne**, et
    /// montrent le même mode de démarrage.
    func testUnderAScreenBothPutTty0FirstAndShowTheSameMode() throws {
        let kernel = try Self.tinyKernel()
        let swiftConsole = Console()
        let rustConsole = Console()
        let reference = swift(swiftConsole)
        let machine = try rust(rustConsole)
        try reference.attachDisplay(width: 1024, height: 768)
        try machine.attachDisplay(width: 1024, height: 768)
        for core in [reference, machine] as [GuestMachine] {
            try core.load(kernelImage: kernel, commandLine: nil, initialRamdisk: nil)
            XCTAssertEqual(core.runGuest(instructionBudget: 50_000_000), .powerOff)
        }
        XCTAssertTrue(swiftConsole.text.hasPrefix("wisq-noyau-factice\nconsole=tty0 "))
        XCTAssertEqual(rustConsole.text, swiftConsole.text)

        let screen = try XCTUnwrap(machine.display)
        let swiftScreen = try XCTUnwrap(reference.display)
        XCTAssertEqual(screen.mode, swiftScreen.mode)
        XCTAssertEqual(screen.memorySize, swiftScreen.memorySize)
        let (mode, pixels) = screen.frame()
        XCTAssertEqual(mode, X86Framebuffer.Mode(width: 1024, height: 768, bytesPerRow: 4096, start: 0))
        XCTAssertEqual(pixels.count, 1024 * 768 * 4)
        XCTAssertEqual(pixels, swiftScreen.frame().data, "deux écrans noirs")
        XCTAssertEqual(screen.revision, screen.revision, "rien n'a changé entre deux lectures")
        XCTAssertThrowsError(try machine.attachDisplay(width: 800, height: 600)) {
            XCTAssertEqual($0 as? RustPCMachine.Refusal, .alreadyStarted)
        }
    }

    /// **Une image coupée au mode sous lequel elle a été copiée** : l'invité
    /// tourne pendant qu'on lit, et le mode peut changer entre la mesure et
    /// la copie. La copie est jouée ici à la main.
    func testAFrameFollowsAModeThatChangesDuringTheCopy() {
        func setMode(_ display: inout WisqPCDisplay, _ width: UInt32, _ height: UInt32) {
            display.width = width
            display.height = height
            display.bytes_per_row = width * 4
        }
        // Plus petit : mesuré en 4 × 2, copié en 2 × 2 dans le tampon de
        // l'ancien mode.
        var calls = 0
        let shrunk = RustPCScreen.frame { pixels, display in
            calls += 1
            guard calls > 1, let pixels else {
                setMode(&display, 4, 2)
                return -3
            }
            XCTAssertEqual(pixels.count, 4 * 2 * 4)
            setMode(&display, 2, 2)
            for index in 0..<16 { pixels[index] = UInt8(index + 1) }
            return 0
        }
        XCTAssertEqual(shrunk?.mode, X86Framebuffer.Mode(width: 2, height: 2, bytesPerRow: 8, start: 0))
        XCTAssertEqual(shrunk?.data, Data((1...16).map { UInt8($0) }), "coupée au nouveau mode")

        // Plus grand : la copie refuse le tampon, et l'on recommence à la
        // taille qu'elle dit.
        var sizes: [Int] = []
        let grown = RustPCScreen.frame { pixels, display in
            sizes.append(pixels?.count ?? 0)
            switch sizes.count {
            case 1, 2:
                setMode(&display, UInt32(2 * sizes.count), 1)
                return -3
            default: return 0
            }
        }
        XCTAssertEqual(sizes, [0, 8, 16])
        XCTAssertEqual(grown?.mode.width, 4)
        XCTAssertEqual(grown?.data.count, 16)

        // Quatre refus de suite : rien.
        var refusals = 0
        XCTAssertNil(RustPCScreen.frame { _, display in
            refusals += 1
            setMode(&display, UInt32(refusals), 1)
            return -3
        })
        XCTAssertEqual(refusals, 5, "la mesure, puis quatre essais")
    }

    // MARK: - Les refus

    func testWhatCannotBeDoneIsRefusedByName() throws {
        let machine = try rust(Console())
        XCTAssertNil(machine.display)
        XCTAssertEqual(machine.runGuest(instructionBudget: 1000),
                       .faulted("rien à faire tourner : ni noyau chargé, ni machine reprise"))
        XCTAssertEqual(machine.snapshot(), Data(), "rien à sauver avant le noyau")
        XCTAssertThrowsError(try machine.attachDisplay(width: 0, height: 768)) {
            XCTAssertEqual($0 as? RustPCMachine.Refusal, .displayTooLarge(width: 0, height: 768))
        }
        XCTAssertThrowsError(try machine.attachDisplay(width: -1, height: 768))
        XCTAssertThrowsError(try machine.attachDisk(Data([1, 2, 3]))) {
            XCTAssertEqual($0 as? RustPCMachine.Refusal, .diskTooSmall)
        }
        XCTAssertThrowsError(try machine.attachDisk(Data())) {
            XCTAssertEqual($0 as? RustPCMachine.Refusal, .diskTooSmall)
        }
        let kernel = try Self.tinyKernel()
        XCTAssertThrowsError(try machine.load(kernelImage: Data("pas un noyau".utf8), commandLine: nil,
                                              initialRamdisk: nil)) {
            XCTAssertEqual($0 as? RustPCMachine.Refusal, .notAKernel)
        }
        XCTAssertThrowsError(try machine.load(kernelImage: kernel.prefix(kernel.count / 2),
                                              commandLine: nil, initialRamdisk: nil)) {
            XCTAssertEqual($0 as? RustPCMachine.Refusal, .truncatedKernel)
        }
        XCTAssertThrowsError(try machine.load(kernelImage: kernel, commandLine: "a\u{0}b",
                                              initialRamdisk: nil)) {
            XCTAssertEqual($0 as? RustPCMachine.Refusal, .commandLineHasNUL,
                           "un nul ne coupe pas la ligne en silence")
        }
        try machine.load(kernelImage: kernel, commandLine: nil, initialRamdisk: Data([1, 2, 3, 4]))
        XCTAssertThrowsError(try machine.load(kernelImage: kernel, commandLine: nil, initialRamdisk: nil)) {
            XCTAssertEqual($0 as? RustPCMachine.Refusal, .alreadyStarted)
        }
        XCTAssertNotNil(RustPCMachine.Refusal.notAKernel.errorDescription)
    }

    /// Un disque sur fichier se branche, ses compteurs se lisent ; un format
    /// d'image que seul le cœur Swift lit est refusé en le disant.
    func testDisksAreAttachedAndImageFormatsRefused() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("wisq-rust-pc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let base = folder.appendingPathComponent("disque.img")
        try Data(count: 4096).write(to: base)
        let second = folder.appendingPathComponent("second.img")
        try Data(count: 4096).write(to: second)
        var qcow = Data([0x51, 0x46, 0x49, 0xFB, 0, 0, 0, 3])
        qcow.append(Data(count: 4088))
        let image = folder.appendingPathComponent("disque.qcow2")
        try qcow.write(to: image)

        let machine = try rust(Console())
        XCTAssertNil(machine.diskActivity)
        XCTAssertThrowsError(try machine.attachDisk(
            fileAt: folder.appendingPathComponent("absent.img"),
            writes: folder.appendingPathComponent("absent.couche"))) {
            XCTAssertEqual($0 as? FileDiskStore.Failure, .cannotOpenBase)
        }
        XCTAssertThrowsError(try machine.attachDisk(
            fileAt: image, writes: folder.appendingPathComponent("qcow.couche"))) {
            guard case .unreadableImage? = $0 as? FileDiskStore.Failure else {
                return XCTFail("un qcow2 refusé sous son nom, pas \($0)")
            }
        }
        try machine.attachDisk(fileAt: base, writes: folder.appendingPathComponent("disque.couche"))
        try machine.attachSecondDisk(fileAt: second, writes: folder.appendingPathComponent("second.couche"))
        XCTAssertEqual(machine.diskActivity?.served, 0)
        XCTAssertEqual(machine.diskActivity?.refused, 0)
        XCTAssertEqual(machine.diskBytesWritten, 0)
        machine.flushDisk()
        try machine.load(kernelImage: try Self.tinyKernel(), commandLine: nil, initialRamdisk: nil)
        XCTAssertThrowsError(try machine.attachDisk(
            fileAt: base, writes: folder.appendingPathComponent("disque.couche"))) {
            XCTAssertEqual($0 as? RustPCMachine.Refusal, .alreadyStarted)
        }
    }

    /// **Chaque refus d'un disque sur fichier a son nom** — ceux que la
    /// bibliothèque rend par -3, -4, -5 et -6, sur l'un et l'autre disque.
    func testEachRefusalOfADiskFileHasItsName() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("wisq-rust-pc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        func file(_ name: String) -> URL { folder.appendingPathComponent(name) }
        let base = file("disque.img")
        try Data(count: 4096).write(to: base)
        try Data([1, 2, 3]).write(to: file("petit.img"))
        // Une carte qui n'en est pas une : celle d'un autre programme.
        try Data("pas une carte du tout".utf8).write(to: file("etrangere.couche.map"))
        // La bonne marque, les huit secteurs de la base, et un secteur nommé
        // que le fichier des écritures, vide, n'a pas.
        var named = Data("wisqdisk".utf8)
        named.append(contentsOf: [8, 0, 0, 0, 0, 0, 0, 0])
        named.append(Data(count: 8))
        try named.write(to: file("tronquee.couche.map"))
        try Data().write(to: file("tronquee.couche"))

        let machine = try rust(Console())
        let cases: [(URL, URL, FileDiskStore.Failure)] = [
            (file("petit.img"), file("petit.couche"), .notADisk),
            (base, file("absent/disque.couche"), .cannotOpenOverlay),
            (base, file("etrangere.couche"), .overlayBelongsToAnotherDisk),
            (base, file("tronquee.couche"), .overlayIsTruncated),
        ]
        for (base, writes, failure) in cases {
            XCTAssertThrowsError(try machine.attachDisk(fileAt: base, writes: writes)) {
                XCTAssertEqual($0 as? FileDiskStore.Failure, failure, "premier disque")
            }
            XCTAssertThrowsError(try machine.attachSecondDisk(fileAt: base, writes: writes)) {
                XCTAssertEqual($0 as? FileDiskStore.Failure, failure, "second disque")
            }
        }
        XCTAssertNil(machine.diskActivity, "aucun refus n'a branché de disque")
        try machine.attachDisk(fileAt: base, writes: file("disque.couche"))
        XCTAssertNotNil(machine.diskActivity)
    }

    /// **Une mémoire sous le plancher est portée au plancher**, et celui que
    /// l'enveloppe annonce est bien celui que la bibliothèque a pris : la RAM
    /// que l'en-tête de l'instantané porte, après la magie et la version.
    func testAMemoryBelowTheFloorIsRaisedToTheOneTheLibraryTakes() throws {
        for asked in [0, 1 << 20, RustPCMachine.minimumRAMSize - 1] {
            let machine = try rust(Console(), ram: asked)
            XCTAssertEqual(machine.ramSize, RustPCMachine.minimumRAMSize, "\(asked)")
            XCTAssertEqual(machine.ramSizeBytes, RustPCMachine.minimumRAMSize)
            try machine.load(kernelImage: try Self.tinyKernel(), commandLine: nil, initialRamdisk: nil)
            let header = Array(machine.snapshot().prefix(20))
            XCTAssertEqual(header.count, 20)
            let ram = header[12..<20].reversed().reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            XCTAssertEqual(ram, UInt64(machine.ramSize))
        }
    }

    // MARK: - Le clavier, la tablette, la souris

    func testKeystrokesAreSetOneCodesAndTypingStopsAtTheFirstThatDoesNotFit() throws {
        XCTAssertEqual(RustPCMachine.setOneCodes(X86Keystrokes.press(.up)), [0xE0, 0x48, 0xE0, 0xC8])
        XCTAssertEqual(RustPCMachine.setOneCodes(X86Keystrokes.character("A")),
                       [0x2A, 0x1E, 0x9E, 0xAA], "Maj autour de la touche")

        let machine = try rust(Console())
        let keyboard: ScreenKeyboard = machine
        let report = keyboard.type("aé b")
        XCTAssertEqual(report.typed, 3)
        XCTAssertEqual(report.skipped, 1, "ce qu'un clavier QWERTY n'a pas")
        XCTAssertEqual(report.untyped, "")
        XCTAssertEqual(keyboard.pendingKeystrokes, 6)
        XCTAssertTrue(keyboard.press(X86Keystrokes.press(.enter)))
        XCTAssertEqual(keyboard.pendingKeystrokes, 8)
        keyboard.abandonTyping()
        XCTAssertEqual(keyboard.pendingKeystrokes, 0)

        // La file en tient 8192 : un long texte s'arrête au premier caractère
        // qui ne tient plus, entier.
        let long = String(repeating: "a", count: 5000)
        let partial = keyboard.type(long[...])
        XCTAssertEqual(partial.typed, 4096)
        XCTAssertEqual(partial.untyped.count, 5000 - 4096)
        XCTAssertFalse(keyboard.press(X86Keystrokes.press(.enter)))
    }

    func testTheTabletWaitsForTheGuestAndTheMouseNeverBreaks() throws {
        let machine = try rust(Console())
        XCTAssertFalse(machine.touch(x: 0.5, y: 0.5, buttons: 1), "pas d'écran")
        try machine.attachDisplay(width: 640, height: 480)
        XCTAssertFalse(machine.touch(x: 0.5, y: 0.5, buttons: 1), "la tablette n'est pas prise")
        XCTAssertFalse(machine.scroll(notches: 0))
        XCTAssertFalse(machine.scroll(notches: 3))
        machine.mouse(dx: Int.max, dy: Int.min, buttons: 1)
    }

    // MARK: - La course

    /// **Un arrêt d'un autre fil rend la main**, et reste demandé, comme sur
    /// `X86Machine`. L'avancement se lit pendant la course.
    func testAStopFromAnotherThreadReturnsAndStays() throws {
        let machine = try rust(Console())
        try machine.load(kernelImage: try Self.endlessKernel(), commandLine: nil, initialRamdisk: nil)
        XCTAssertNil(machine.liveProgress)
        let seen = expectation(description: "l'avancement lu pendant la course")
        DispatchQueue.global().async {
            while (machine.liveProgress?.retired ?? 0) < 5_000_000 { usleep(1000) }
            seen.fulfill()
            machine.send(Data("x".utf8))
            _ = machine.press(X86Keystrokes.press(.enter))
            machine.stop()
        }
        XCTAssertEqual(machine.runGuest(instructionBudget: .max), .stopped)
        wait(for: [seen], timeout: 10)
        let retired = machine.retiredInstructions
        XCTAssertGreaterThanOrEqual(retired, 5_000_000)
        // Borné : un arrêt oublié ferait tourner ce budget-ci, sans pendre.
        XCTAssertEqual(machine.runGuest(instructionBudget: 10_000_000), .stopped)
        XCTAssertEqual(machine.retiredInstructions, retired, "l'arrêt reste demandé : rien n'a tourné")
    }

    /// Le budget épuisé rend `.stopped`, comme le cœur Swift : c'est ce que
    /// `CheckpointedRun` attend de chaque tranche.
    func testASpentBudgetReturnsStopped() throws {
        let machine = try rust(Console())
        try machine.load(kernelImage: try Self.endlessKernel(), commandLine: nil, initialRamdisk: nil)
        XCTAssertEqual(machine.runGuest(instructionBudget: 2_500_000), .stopped)
        XCTAssertEqual(machine.retiredInstructions, 2_500_000)
        XCTAssertEqual(machine.runGuest(instructionBudget: 500_000), .stopped)
        XCTAssertEqual(machine.retiredInstructions, 3_000_000)
    }

    /// Le noyau factice, qui attend cent battements au lieu de cinq : le
    /// `cmp $5, %ebx` de sa boucle d'attente (`83 fb 05`) devient
    /// `cmp $100, %ebx`. Cent millisecondes de son temps, presque toutes sur
    /// `hlt`.
    private static func patientKernel() throws -> Data {
        var image = try tinyKernel()
        let compare: [UInt8] = [0x83, 0xFB, 0x05]
        let at = try XCTUnwrap(image.indices.first { image[$0...].starts(with: compare) })
        image[at + 2] = 100
        return image
    }

    /// **Devant une personne, un invité qui dort laisse dormir l'appareil** :
    /// ses cent millisecondes d'attente durent au moins cela, à l'horloge
    /// murale — sans le pas, la course les saute en quelques millisecondes.
    func testAnIdleGuestIsPacedToTheWallClock() throws {
        let console = Console()
        let machine = try rust(console)
        machine.pacesIdleToWallClock = true
        try machine.load(kernelImage: try Self.patientKernel(), commandLine: nil, initialRamdisk: nil)
        let start = Date()
        XCTAssertEqual(machine.runGuest(instructionBudget: .max), .powerOff)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.09)
        XCTAssertTrue(console.text.hasSuffix(String(repeating: ".", count: 100) + "\nFIN\n"))
    }

    func testTimeSpentOutsideIsCaughtUpWithoutChangingWhatTheGuestSays() throws {
        let console = Console()
        let machine = try rust(console)
        try machine.load(kernelImage: try Self.tinyKernel(), commandLine: "a=b", initialRamdisk: nil)
        machine.elapse(seconds: -3)
        machine.elapse(seconds: .nan)
        machine.elapse(seconds: 25)
        XCTAssertEqual(machine.runGuest(instructionBudget: 50_000_000), .powerOff)
        XCTAssertEqual(console.text, "wisq-noyau-factice\na=b\n.....\nFIN\n")
    }

    // MARK: - L'instantané

    /// **Coupée à mi-course, sauvée, reprise dans une autre machine** : la
    /// console des deux moitiés est celle d'une course entière.
    func testASnapshotTakenMidRunFinishesTheRunElsewhere() throws {
        let kernel = try Self.tinyKernel()
        let whole = Console()
        let reference = try rust(whole)
        try reference.load(kernelImage: kernel, commandLine: "x=y", initialRamdisk: nil)
        XCTAssertEqual(reference.runGuest(instructionBudget: 50_000_000), .powerOff)

        let first = Console()
        let cut = try rust(first)
        try cut.load(kernelImage: kernel, commandLine: "x=y", initialRamdisk: nil)
        XCTAssertEqual(cut.runGuest(instructionBudget: 1_000_000), .stopped)
        let saved = cut.snapshot()
        XCTAssertEqual(saved.prefix(8), Data("WISQPC\r\n".utf8))

        let second = Console()
        let resumed = try rust(second)
        XCTAssertThrowsError(try resumed.restore(Data("autre chose".utf8))) {
            XCTAssertEqual($0 as? RustPCMachine.Refusal, .notASnapshot)
        }
        XCTAssertThrowsError(try resumed.restore(saved.prefix(saved.count - 1))) {
            XCTAssertEqual($0 as? RustPCMachine.Refusal, .damagedSnapshot)
        }
        let bigger = try rust(Console(), ram: Self.ram * 2)
        XCTAssertThrowsError(try bigger.restore(saved)) {
            XCTAssertEqual($0 as? RustPCMachine.Refusal, .snapshotOfOtherMemory)
        }
        var older = saved
        older[8] = 1
        XCTAssertThrowsError(try resumed.restore(older)) {
            XCTAssertEqual($0 as? RustPCMachine.Refusal, .olderSnapshot, "la version 1, sans la carte")
        }
        let disked = try rust(Console())
        try disked.attachDisk(Data(count: 4096))
        XCTAssertThrowsError(try disked.restore(saved)) {
            XCTAssertEqual($0 as? RustPCMachine.Refusal, .snapshotOfOtherDisks, "un disque de trop")
        }
        try resumed.restore(saved)
        XCTAssertEqual(resumed.runGuest(instructionBudget: 50_000_000), .powerOff)
        XCTAssertFalse(first.text.isEmpty)
        XCTAssertFalse(second.text.isEmpty)
        XCTAssertEqual(first.text + second.text, whole.text)
        XCTAssertEqual(resumed.retiredInstructions, reference.retiredInstructions)
    }

    // MARK: - Un vrai noyau

    /// **Un vrai noyau, par l'enveloppe de l'application** : `WISQ_PC_KERNEL`
    /// (et `WISQ_PC_INITRD`, `WISQ_PC_CMDLINE`, `WISQ_PC_ATTENDU`, « ~ # »
    /// par défaut : le shell de secours d'Alpine). Le banc commun : Alpine
    /// 6.18.60 et son initramfs, `console=ttyS0`, 512 Mio. Se tait bruyamment
    /// sans noyau.
    func testARealKernelBootsThroughTheWrapper() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["WISQ_PC_KERNEL"] else {
            print("noyau PC absent : définir WISQ_PC_KERNEL pour ce test")
            return
        }
        let kernel = try Data(contentsOf: URL(fileURLWithPath: path))
        let ramdisk = try environment["WISQ_PC_INITRD"].map { try Data(contentsOf: URL(fileURLWithPath: $0)) }
        let expected = environment["WISQ_PC_ATTENDU"] ?? "~ # "
        let console = Console()
        let machine = try rust(console, ram: 512 << 20)
        try machine.load(kernelImage: kernel, commandLine: environment["WISQ_PC_CMDLINE"] ?? "console=ttyS0",
                         initialRamdisk: ramdisk)
        let start = Date()
        var outcome = GuestOutcome.stopped
        while outcome == .stopped, !console.text.contains(expected),
              machine.retiredInstructions < 6_000_000_000 {
            outcome = machine.runGuest(instructionBudget: 50_000_000)
        }
        let seconds = Date().timeIntervalSince(start)
        let retired = machine.retiredInstructions
        print("instructions retirées : \(retired) ; \(String(format: "%.1f", seconds)) s ; "
              + "\(String(format: "%.1f", Double(retired) / seconds / 1e6)) MIPS")
        XCTAssertTrue(console.text.contains(expected), "« \(expected) » jamais vu ; fin : \(outcome)\n"
                      + String(console.text.suffix(2000)))
    }

    // MARK: - Le réglage

    /// **Allumé par défaut**, à côté de celui de l'émetteur (éteint) ;
    /// sans session, il ne prend qu'une machine PC neuve et non installée.
    func testTheSettingIsOnByDefaultAndTakesOnlyAFreshPC() {
        XCTAssertTrue(RustPCSetting.defaultValue)
        XCTAssertFalse(EmitterSetting.defaultValue, "l'émetteur reste éteint")
        XCTAssertEqual(RustPCSetting.key, "wisq.machine.pc-rust")
        XCTAssertNotEqual(RustPCSetting.key, EmitterSetting.key)
        XCTAssertTrue(RustPCSetting.savesSessions, "la machine du cœur Rust sauve ses sessions")
        XCTAssertTrue(RustPCSetting.runs(.x86_64, enabled: true, session: nil, installed: false))
        XCTAssertFalse(RustPCSetting.runs(.x86_64, enabled: false, session: nil, installed: false),
                       "éteint")
        XCTAssertFalse(RustPCSetting.runs(.riscv32, enabled: true, session: nil, installed: false),
                       "une machine RISC-V reste à son cœur")
        XCTAssertFalse(RustPCSetting.runs(.x86_64, enabled: true, session: nil, installed: true),
                       "une machine installée reste au cœur Swift")
    }

    /// **C'est le format de la session qui décide du cœur, pas le réglage** :
    /// une vraie session du cœur Swift se reprend sur lui, réglage allumé ;
    /// une vraie session du cœur Rust sur le cœur Rust, réglage éteint, et
    /// même sur une machine installée. Sinon, toucher l'interrupteur rendrait
    /// une session illisible. Les deux se jugent lisibles, à leur mémoire.
    func testASessionGoesBackToTheCoreThatWroteIt() throws {
        let kernel = try Self.tinyKernel()
        let swiftCore = swift(Console())
        try swiftCore.load(kernelImage: kernel, commandLine: "x=y", initialRamdisk: nil)
        _ = swiftCore.runGuest(instructionBudget: 1_000_000)
        let swiftSession = swiftCore.snapshot()
        let rustCore = try rust(Console())
        try rustCore.load(kernelImage: kernel, commandLine: "x=y", initialRamdisk: nil)
        _ = rustCore.runGuest(instructionBudget: 1_000_000)
        let rustSession = rustCore.snapshot()

        for enabled in [true, false] {
            for installed in [true, false] {
                XCTAssertFalse(
                    RustPCSetting.runs(.x86_64, enabled: enabled, session: swiftSession, installed: installed),
                    "une session du cœur Swift, réglage \(enabled), installée \(installed)")
                XCTAssertTrue(
                    RustPCSetting.runs(.x86_64, enabled: enabled, session: rustSession, installed: installed),
                    "une session du cœur Rust, réglage \(enabled), installée \(installed)")
            }
        }
        XCTAssertFalse(RustPCSetting.runs(.riscv32, enabled: true, session: rustSession, installed: false))

        // L'en-tête lu côté Swift est celui que la bibliothèque écrit.
        let header = try XCTUnwrap(RustPCSnapshot.header(of: rustSession))
        XCTAssertEqual(header.version, RustPCSnapshot.version, "la version de la bibliothèque")
        XCTAssertEqual(header.ramSize, rustCore.ramSize)
        XCTAssertNotNil(SavedSession.judge(rustSession, core: .x86_64).snapshot)
        XCTAssertNotNil(SavedSession.judge(swiftSession, core: .x86_64).snapshot)
        XCTAssertEqual(SessionMemory.savedRAMSize(rustSession, core: .x86_64), rustCore.ramSize)
        XCTAssertEqual(SessionMemory.savedRAMSize(swiftSession, core: .x86_64), Self.ram)
        // Et une session du cœur Rust se reprend dans la machine que
        // l'application construirait à sa mémoire.
        let resumed = try rust(Console(), ram: try XCTUnwrap(SessionMemory.savedRAMSize(rustSession, core: .x86_64)))
        try resumed.restore(rustSession)
        XCTAssertEqual(resumed.retiredInstructions, rustCore.retiredInstructions)
    }

    /// **Le défaut s'applique à un réglage jamais touché**, et un réglage
    /// éteint à la main le reste. `UserDefaults.bool(forKey:)` rendait faux
    /// dans le premier cas : personne n'aurait eu le cœur Rust.
    func testAnUntouchedSettingTakesTheDefaultAndATouchedOneIsKept() throws {
        let suite = "wisq.tests.reglage-pc-rust.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertTrue(RustPCSetting.isEnabled(in: defaults), "jamais touché : le défaut")
        defaults.set(false, forKey: RustPCSetting.key)
        XCTAssertFalse(RustPCSetting.isEnabled(in: defaults), "éteint à la main")
        defaults.set(true, forKey: RustPCSetting.key)
        XCTAssertTrue(RustPCSetting.isEnabled(in: defaults), "rallumé")
    }

    /// **Une date hors de `Int64` est bornée avant le cœur** : `Int64(_:)`
    /// planterait. Le cœur borne ensuite de 1970 à l'an 9999.
    func testADateOutsideInt64IsClampedBeforeTheCore() {
        XCTAssertEqual(RustPCMachine.seconds(since1970: 1e19), .max)
        XCTAssertEqual(RustPCMachine.seconds(since1970: Double(Int64.max)), .max, "2^63 tout juste")
        XCTAssertEqual(RustPCMachine.seconds(since1970: -1e19), .min)
        XCTAssertEqual(RustPCMachine.seconds(since1970: .infinity), .max)
        XCTAssertEqual(RustPCMachine.seconds(since1970: -.infinity), .min)
        XCTAssertEqual(RustPCMachine.seconds(since1970: .nan), 0)
        XCTAssertEqual(RustPCMachine.seconds(since1970: 1_700_000_000.9), 1_700_000_000)
        XCTAssertEqual(RustPCMachine.seconds(since1970: -0.5), -1)
        let machine = RustPCMachine(ramSize: 64 << 20) { _ in }
        machine?.freezeHostTime(at: Date(timeIntervalSince1970: 1e19))
    }
}
