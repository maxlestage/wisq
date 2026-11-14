import Foundation
import XCTest
@testable import WisqVM

/// **Fabriquer un bureau prêt** (`ReadyDesktopBuild`) : la machine de la
/// fabrique est celle de l'application, l'instantané est vérifié avant d'être
/// emporté, et l'archive, importée ailleurs, rend la session sous le nom que
/// l'application cherchera.
///
/// Le bureau lui-même ne se fabrique pas ici — il demande l'ISO et une
/// demi-heure (`wisq-fabrique`, et le banc armé `X86DesktopResumeTests`).
final class ReadyDesktopBuildTests: XCTestCase {
    static let moment = Date(timeIntervalSince1970: 1_794_614_400)  // 2026-11-14T00:00:00Z
    static let ram = X86Machine.minimumRAMSize

    /// **La machine de la fabrique est celle de l'application** : carte
    /// réseau branchée, écran de l'application, tablette, la mémoire
    /// demandée, l'heure figée.
    func testTheMachineIsTheApplicationsOne() throws {
        let machine = try ReadyDesktopBuild.machine(ramSize: Self.ram, frozenAt: Self.moment) { _ in }
        XCTAssertNotNil(machine.network, "sans carte réseau, le bureau repris n'aurait pas de réseau")
        XCTAssertTrue(machine.network?.backend is UserNetwork)
        let display = try XCTUnwrap(machine.display)
        XCTAssertEqual(display.width, GuestMachineFactory.screenSize.width)
        XCTAssertEqual(display.height, GuestMachineFactory.screenSize.height)
        XCTAssertEqual([display.width, display.height], [1024, 768], "l'écran de l'application a changé")
        XCTAssertNotNil(machine.tablet)
        XCTAssertEqual(machine.ramSize, Self.ram)
        XCTAssertEqual(machine.core.cmos.fixedHostTime, Self.moment)
    }

    /// **L'heure figée survit à la reprise** : `restore` refait le cœur, et
    /// son horloge avec.
    func testTheFrozenClockSurvivesARestore() throws {
        let saved = try ReadyDesktopBuild.machine(ramSize: Self.ram, frozenAt: nil) { _ in }
        let machine = try ReadyDesktopBuild.machine(ramSize: Self.ram, frozenAt: Self.moment) { _ in }
        try machine.restore(saved.snapshot())
        XCTAssertEqual(machine.core.cmos.fixedHostTime, Self.moment)
        machine.frozenHostTime = nil
        XCTAssertNil(machine.core.cmos.fixedHostTime, "l'application lit l'horloge du système")
    }

    /// **Et au chargement** : `load` refait le cœur lui aussi.
    func testTheFrozenClockSurvivesALoad() throws {
        let machine = try ReadyDesktopBuild.machine(ramSize: Self.ram, frozenAt: Self.moment) { _ in }
        try machine.load(kernelImage: X86LocalMachineTests.kernel(X86LocalMachineTests.printing("ok")))
        XCTAssertEqual(machine.core.cmos.fixedHostTime, Self.moment)
    }

    /// La ligne de la fabrication : celle de l'image, plus la mise à zéro des
    /// pages libérées, et la console de wisq toujours en dernier.
    func testTheCommandLineZeroesFreedPages() {
        let line = "root=live:CDLABEL=VOID_LIVE ro console=ttyS0,115200"
        let made = ReadyDesktopBuild.commandLine(line)
        XCTAssertEqual(made, "init_on_free=1 " + line)
        XCTAssertEqual(ReadyDesktopBuild.commandLine(made), made, "une seule fois")
        XCTAssertEqual(ReadyDesktopBuild.commandLine(line, zeroingFreedPages: false), line)
    }

    // MARK: - La vérification

    /// Un instantané pris sur `machine`, la tablette prête et l'écran peint
    /// aux trois quarts — comme un bureau dessiné.
    static func snapshot(of machine: X86Machine, paint: Bool = true) throws -> Data {
        let tablet = try XCTUnwrap(machine.tablet)
        // Ce qu'écrit le pilote `virtio_input` : la file d'événements
        // activée, puis l'état « pilote prêt ».
        tablet.writeCommon(0x16, 2, 0)
        tablet.writeCommon(0x1C, 2, 1)
        tablet.writeCommon(0x14, 1, 0x0F)
        XCTAssertTrue(tablet.isReady)
        let display = try XCTUnwrap(machine.display)
        if paint {
            for offset in stride(from: 0, to: display.byteCount * 3 / 4, by: 8) {
                display.write(offset, 8, 0x00FF_FFFF_00FF_FFFF)
            }
        }
        return machine.snapshot()
    }

    /// Un bureau pris dans la machine de l'application passe, et l'écran
    /// repris est celui qu'on a peint.
    func testAnApplicationSnapshotPasses() throws {
        let machine = try ReadyDesktopBuild.machine(ramSize: Self.ram, frozenAt: Self.moment) { _ in }
        let lit = try ReadyDesktopBuild.check(Self.snapshot(of: machine), ramSize: Self.ram)
        XCTAssertEqual(lit, 0.75, accuracy: 0.001)
    }

    /// **Sans carte réseau, refusé** : repris dans l'application, la carte du
    /// téléphone serait remplacée par rien.
    func testASnapshotWithoutNetworkIsRefused() throws {
        let machine = X86Machine(ramSize: Self.ram, onOutput: { _ in })
        try GuestMachineFactory.attachScreen(to: machine)
        XCTAssertThrowsError(try ReadyDesktopBuild.check(Self.snapshot(of: machine), ramSize: Self.ram)) {
            XCTAssertEqual($0 as? ReadyDesktopBuild.Refusal, .noNetwork)
        }
    }

    /// **Un écran d'une autre taille, refusé** : la reprise laisse l'écran
    /// de l'application noir.
    func testASnapshotOnAnotherScreenIsRefused() throws {
        let machine = X86Machine(ramSize: Self.ram, onOutput: { _ in })
        machine.attach(network: VirtioNet(backend: UserNetwork.isolated()))
        try machine.attachDisplay(width: 800, height: 600)
        XCTAssertThrowsError(try ReadyDesktopBuild.check(Self.snapshot(of: machine), ramSize: Self.ram)) {
            XCTAssertEqual($0 as? ReadyDesktopBuild.Refusal, .darkScreen(lit: 0))
        }
    }

    /// Un écran encore noir, refusé : on n'emporte pas un bureau pas dessiné.
    func testADarkDesktopIsRefused() throws {
        let machine = try ReadyDesktopBuild.machine(ramSize: Self.ram, frozenAt: nil) { _ in }
        XCTAssertThrowsError(try ReadyDesktopBuild.check(Self.snapshot(of: machine, paint: false), ramSize: Self.ram)) {
            XCTAssertEqual($0 as? ReadyDesktopBuild.Refusal, .darkScreen(lit: 0))
        }
    }

    /// Une tablette que le pilote n'a jamais prise, refusée : le toucher ne
    /// pointerait plus.
    func testASnapshotWithoutADriverForTheTabletIsRefused() throws {
        let machine = try ReadyDesktopBuild.machine(ramSize: Self.ram, frozenAt: nil) { _ in }
        _ = try Self.snapshot(of: machine)
        try XCTUnwrap(machine.tablet).writeCommon(0x14, 1, 0)
        XCTAssertThrowsError(try ReadyDesktopBuild.check(machine.snapshot(), ramSize: Self.ram)) {
            XCTAssertEqual($0 as? ReadyDesktopBuild.Refusal, .noTablet)
        }
    }

    /// La mémoire sauvée doit être celle qu'annonce la fiche.
    func testAnotherMemoryIsRefused() throws {
        let machine = try ReadyDesktopBuild.machine(ramSize: Self.ram, frozenAt: nil) { _ in }
        XCTAssertThrowsError(try ReadyDesktopBuild.check(Self.snapshot(of: machine), ramSize: 2 * Self.ram)) {
            XCTAssertEqual($0 as? ReadyDesktopBuild.Refusal, .memory(saved: Self.ram, expected: 2 * Self.ram))
        }
    }

    // MARK: - L'assemblage

    /// **Exporter, puis importer dans un dossier neuf** : la machine revient
    /// sous une clé neuve, sa session sous l'empreinte du noyau — celle que
    /// l'application calcule —, sa couche d'écriture et sa mémoire là où
    /// l'application les lit.
    func testTheArchiveComesBackUnderTheKernelsDigest() throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent("wisq-pret-\(UUID().uuidString)")
        defer { try? files.removeItem(at: root) }
        let work = root.appendingPathComponent("atelier")
        let fresh = root.appendingPathComponent("telephone")
        let kernels = root.appendingPathComponent("images")
        for folder in [work, fresh, kernels] { try files.createDirectory(at: folder, withIntermediateDirectories: true) }
        let image = "void-live-x86_64-20250202-xfce.iso"
        let iso = kernels.appendingPathComponent(image)
        try Data(repeating: 0x5A, count: 64 << 10).write(to: iso)
        let kernel = Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 31) })

        let (installed, writes) = try ReadyDesktopBuild.install(image: image, name: "Void Xfce (prêt)", in: work)
        let machine = try ReadyDesktopBuild.machine(ramSize: Self.ram, frozenAt: Self.moment) { _ in }
        try machine.attach(diskFileAt: iso, writes: writes)
        machine.flushDisk()
        let snapshot = try Self.snapshot(of: machine)
        XCTAssertTrue(files.fileExists(atPath: writes.path + ".map"), "la couche de la fabrication")

        let archive = root.appendingPathComponent("bureau.wisqmachine")
        let identity = try ReadyDesktopBuild.assemble(
            installed, snapshot: snapshot, kernel: kernel, ramSize: 1 << 30,
            kernels: kernels, in: work, to: archive)
        XCTAssertEqual(identity, SuspendedMachine.identity(of: kernel, named: installed.key))
        XCTAssertTrue(identity.hasSuffix(ReadyDesktopBuild.kernelDigest(kernel)))

        let imported = try MachineArchive.import(
            from: archive, library: [image], in: fresh,
            createOwnDisk: { _, _ in throw MachineArchive.Refusal.damaged })
        XCTAssertNotEqual(imported.id, installed.id)
        XCTAssertEqual(imported.name, "Void Xfce (prêt)")
        XCTAssertEqual(imported.image, image)
        let found = SavedSession.find(
            kernel: SuspendedMachine.identity(of: kernel, named: imported.keys.settings), in: fresh, core: .x86_64)
        XCTAssertEqual(found.snapshot, snapshot, "la session n'est pas sous l'empreinte du noyau")
        // Un autre noyau ne la trouve pas : c'est bien l'empreinte qui nomme.
        var other = kernel
        other[0] ^= 1
        guard case .none = SavedSession.find(
            kernel: SuspendedMachine.identity(of: other, named: imported.keys.settings), in: fresh, core: .x86_64)
        else { return XCTFail("un autre noyau a trouvé la session") }
        XCTAssertEqual(KernelMemory.size(forKernel: imported.key, in: fresh, ceiling: .max), 1 << 30)
        let layer = try LocalDisk.writesURL(for: imported.keys.overlay(forDisk: image), in: fresh)
        XCTAssertTrue(files.fileExists(atPath: layer.path + ".map"), "la couche n'a pas suivi")
        // Et la machine reprend dans une machine de l'application neuve.
        XCTAssertNoThrow(try ReadyDesktopBuild.check(try XCTUnwrap(found.snapshot), ramSize: Self.ram))
    }

    /// La fiche se relit telle qu'écrite, clés triées, dates lisibles.
    func testTheSheetRoundTrips() throws {
        let sheet = ReadyDesktopBuild.Sheet(
            title: "Void Xfce (prêt)", level: X86Machine.snapshotLevel,
            image: .init(name: "void.iso", bytes: 1, sha256: "ab"),
            archive: .init(name: "void-pret.wisqmachine", bytes: 2, sha256: "cd"),
            kernelDigest: "d63775f2e341116a", ramBytes: 1 << 30, screen: [1024, 768],
            commandLine: "init_on_free=1", madeAt: Self.moment, guestClock: Self.moment,
            instructions: 3, snapshotBytes: 4, packedBytes: 5, commit: nil)
        let data = try sheet.encoded()
        XCTAssertEqual(try ReadyDesktopBuild.Sheet.decode(data), sheet)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\"madeAt\" : \"2026-11-14T00:00:00Z\""), text)
        XCTAssertLessThan(try XCTUnwrap(text.range(of: "archive")).lowerBound,
                          try XCTUnwrap(text.range(of: "title")).lowerBound)
    }

    /// Les sommes de la fiche sont celles du fichier.
    func testAFileIsMeasured() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wisq-fiche-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("abc".utf8).write(to: url)
        let file = try ReadyDesktopBuild.Sheet.File.measure(url, name: "abc.iso")
        XCTAssertEqual(file, .init(name: "abc.iso", bytes: 3,
                                   sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"))
    }
}
