import CWisqVM
import Foundation
import WisqVM
@testable import WisqVMRust
import XCTest

/// **Les bureaux prêts du cœur Rust** (`RustReadyDesktopBuild`) : la machine
/// de la fabrique est celle de l'application, l'instantané est repris dans
/// une machine neuve avant d'être emporté, l'archive revient sous le nom que
/// l'application cherche, et la reprise remplace l'aléa de la fabrique.
///
/// L'invité est le noyau factice (`Tests/Fixtures/pc-noyau-factice.bin`) : il
/// ne prend ni l'écran ni la tablette, et la vérification s'y arrête donc à
/// la tablette, après la mémoire, la version, les disques, la reprise et la
/// carte réseau. Le bureau lui-même se fabrique avec l'ISO de Void
/// (`wisq-fabrique --coeur rust`) et se reprend par le banc armé
/// `testARealRustDesktopComesBackThroughTheApplicationsPath`.
final class RustReadyDesktopTests: XCTestCase {
    private static let ram = 128 << 20
    private static let moment = Date(timeIntervalSince1970: 1_794_614_400)  // 2026-11-14T00:00:00Z

    private static func tinyKernel() throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/pc-noyau-factice.bin"))
    }

    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("wisq-pret-rust-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// Une image brute de `bytes` octets, dans le dossier du test.
    private func disk(_ name: String, bytes: Int = 64 << 10) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data(repeating: 0x5A, count: bytes).write(to: url)
        return url
    }

    /// **Un instantané de la fabrique** : la machine de la fabrique, l'image
    /// et sa couche branchées, le noyau factice tourné un million
    /// d'instructions, le disque scellé.
    private func fabricated(iso: URL, writes: URL, frozenAt: Date? = moment) throws -> Data {
        let machine = try RustReadyDesktopBuild.machine(ramSize: Self.ram, frozenAt: frozenAt) { _ in }
        try machine.attachDisk(fileAt: iso, writes: writes)
        try machine.load(kernelImage: try Self.tinyKernel(), commandLine: "a=b", initialRamdisk: nil)
        XCTAssertNil(machine.advance(1_000_000))
        machine.flushDisk()
        return machine.snapshot()
    }

    // MARK: - La machine

    /// **La machine de la fabrique est celle de l'application** : la carte
    /// réseau branchée sur la pile de l'application (isolée), l'écran de
    /// l'application, la mémoire demandée.
    func testTheMachineIsTheApplicationsOne() throws {
        let machine = try RustReadyDesktopBuild.machine(ramSize: Self.ram, frozenAt: Self.moment) { _ in }
        XCTAssertTrue(machine.networkBackend is UserNetwork, "sans carte réseau, le bureau repris n'en aurait pas")
        XCTAssertNotNil(machine.networkCounts)
        let screen = try XCTUnwrap(machine.display)
        try machine.load(kernelImage: try Self.tinyKernel(), commandLine: nil, initialRamdisk: nil)
        XCTAssertEqual([screen.width, screen.height],
                       [GuestMachineFactory.screenSize.width, GuestMachineFactory.screenSize.height])
        XCTAssertEqual([screen.width, screen.height], [1024, 768], "l'écran de l'application a changé")
        XCTAssertEqual(machine.ramSize, Self.ram)
        XCTAssertEqual(machine.screenPixels?.count, 1024 * 768 * 4)
        XCTAssertNil(try XCTUnwrap(RustPCMachine(ramSize: Self.ram, onOutput: { _ in })).screenPixels, "sans écran")
    }

    /// **La fabrique est reproductible, l'application non** : deux
    /// fabrications à la même heure figée sont les mêmes octets (la graine
    /// fixée, l'horloge figée) ; à deux heures figées, non ; et deux machines
    /// de l'application tirent chacune leur graine.
    func testTheFabricationIsReproducibleAndTheApplicationIsNot() throws {
        let iso = try disk("void.iso")
        func run(frozenAt: Date) throws -> Data {
            let writes = folder.appendingPathComponent(UUID().uuidString)
            return try fabricated(iso: iso, writes: writes, frozenAt: frozenAt)
        }
        XCTAssertEqual(try run(frozenAt: Self.moment), try run(frozenAt: Self.moment))
        XCTAssertNotEqual(try run(frozenAt: Self.moment), try run(frozenAt: Self.moment.addingTimeInterval(86_400)),
                          "l'heure figée n'est pas dans l'instantané")
        func application() throws -> Data {
            let machine = try XCTUnwrap(RustPCMachine.make(
                ramSize: Self.ram, network: { UserNetwork.isolated() }, onOutput: { _ in }))
            machine.freezeHostTime(at: Self.moment)
            try machine.load(kernelImage: try Self.tinyKernel(), commandLine: nil, initialRamdisk: nil)
            return machine.snapshot()
        }
        XCTAssertNotEqual(try application(), try application(), "deux téléphones, la même graine")
    }

    /// **Le pilotage par la console** : une tranche qui finit rend `nil`,
    /// l'extinction se dit.
    func testTheMachineIsDrivenLikeTheSwiftOne() throws {
        let machine = try RustReadyDesktopBuild.machine(ramSize: Self.ram, frozenAt: Self.moment) { _ in }
        try machine.load(kernelImage: try Self.tinyKernel(), commandLine: nil, initialRamdisk: nil)
        XCTAssertNil(machine.advance(1_000))
        XCTAssertEqual(machine.advance(50_000_000), "l'invité s'est éteint")
    }

    // MARK: - La vérification

    /// **Le verdict, dans l'ordre du cœur Swift** : la carte réseau, la
    /// tablette, l'écran allumé à plus de la moitié.
    func testTheVerdictFollowsTheOrderOfTheSwiftCore() throws {
        typealias Seen = RustReadyDesktopBuild.Seen
        XCTAssertEqual(try RustReadyDesktopBuild.verdict(Seen(network: true, tablet: true, lit: 0.8)), 0.8)
        let refused: [(Seen, ReadyDesktopBuild.Refusal)] = [
            (Seen(network: false, tablet: true, lit: 0.8), .noNetwork),
            (Seen(network: false, tablet: false, lit: 0), .noNetwork),
            (Seen(network: true, tablet: false, lit: 0.8), .noTablet),
            (Seen(network: true, tablet: false, lit: 0), .noTablet),
            (Seen(network: true, tablet: true, lit: 0.5), .darkScreen(lit: 0.5)),
            (Seen(network: true, tablet: true, lit: 0), .darkScreen(lit: 0)),
        ]
        for (seen, refusal) in refused {
            XCTAssertThrowsError(try RustReadyDesktopBuild.verdict(seen), "\(seen)") {
                XCTAssertEqual($0 as? ReadyDesktopBuild.Refusal, refusal, "\(seen)")
            }
        }
    }

    /// **Repris dans une machine de l'application neuve, sur les disques de
    /// la fabrique** : la reprise passe, la carte réseau revient, et c'est la
    /// tablette, que le noyau factice ne prend pas, qui arrête. Puis chaque
    /// autre garde : la mémoire, la version (un instantané du cœur Swift n'en
    /// a pas), un autre disque, une machine sans carte réseau.
    func testTheCheckResumesOnTheDisksOfTheFabrication() throws {
        let iso = try disk("void.iso")
        let writes = folder.appendingPathComponent("couche")
        let snapshot = try fabricated(iso: iso, writes: writes)
        XCTAssertEqual(RustPCSnapshot.header(of: snapshot)?.version, RustPCSnapshot.version)
        func refusal(_ snapshot: Data, ramSize: Int = RustReadyDesktopTests.ram, disk: URL? = nil) -> ReadyDesktopBuild.Refusal? {
            do {
                try RustReadyDesktopBuild.check(snapshot, ramSize: ramSize, disk: disk ?? iso, writes: writes)
                return nil
            } catch {
                return error as? ReadyDesktopBuild.Refusal
            }
        }
        XCTAssertEqual(refusal(snapshot), .noTablet)
        XCTAssertEqual(refusal(snapshot, ramSize: 2 * Self.ram), .memory(saved: Self.ram, expected: 2 * Self.ram))
        var newer = snapshot
        newer[8] = 3
        XCTAssertEqual(refusal(newer), .level(saved: 3, expected: 2))
        var older = snapshot
        older[8] = 1
        XCTAssertEqual(refusal(older), .level(saved: 1, expected: 2))
        let swift = X86Machine(ramSize: Self.ram, onOutput: { _ in }).snapshot()
        XCTAssertEqual(refusal(swift), .level(saved: nil, expected: 2), "un instantané du cœur Swift")
        // Un autre disque, d'une autre capacité, sa couche à lui : la reprise
        // refuse d'autres disques que ceux de l'instantané.
        let other = try disk("autre.iso", bytes: 128 << 10)
        do {
            try RustReadyDesktopBuild.check(snapshot, ramSize: Self.ram, disk: other,
                                            writes: folder.appendingPathComponent("autre-couche"))
            XCTFail("un autre disque est passé")
        } catch ReadyDesktopBuild.Refusal.unreadable(let why) {
            XCTAssertTrue(why.contains("snapshotOfOtherDisks"), why)
        }

        let bare = try XCTUnwrap(RustPCMachine(ramSize: Self.ram, onOutput: { _ in }))
        try bare.attachApplicationScreen()
        let bareWrites = folder.appendingPathComponent("couche-nue")
        try bare.attachDisk(fileAt: iso, writes: bareWrites)
        try bare.load(kernelImage: try Self.tinyKernel(), commandLine: nil, initialRamdisk: nil)
        XCTAssertNil(bare.advance(1_000_000))
        bare.flushDisk()
        XCTAssertThrowsError(try RustReadyDesktopBuild.check(bare.snapshot(), ramSize: Self.ram, disk: iso,
                                                             writes: bareWrites)) {
            XCTAssertEqual($0 as? ReadyDesktopBuild.Refusal, .noNetwork)
        }
    }

    // MARK: - L'archive, de la fabrique au téléphone

    /// **De la fabrique au téléphone** : l'instantané assemblé avec sa couche,
    /// l'archive importée ailleurs, la session retrouvée sous l'empreinte du
    /// noyau — du cœur Rust, réglage éteint compris —, la mémoire réglée à
    /// celle de l'en-tête, et l'instantané repris sur la couche importée.
    func testTheArchiveComesBackAndResumesOnTheImportedLayer() throws {
        let work = folder.appendingPathComponent("atelier")
        let phone = folder.appendingPathComponent("telephone")
        for place in [work, phone] { try FileManager.default.createDirectory(at: place, withIntermediateDirectories: true) }
        let image = "void-live-x86_64-20250202-xfce.iso"
        let iso = try disk(image)
        let kernel = try Self.tinyKernel()
        let (installed, writes) = try ReadyDesktopBuild.install(image: image, name: "Void Xfce (prêt)", in: work)
        let snapshot = try fabricated(iso: iso, writes: writes)
        let archive = folder.appendingPathComponent("bureau.wisqmachine")
        try ReadyDesktopBuild.assemble(installed, snapshot: snapshot, kernel: kernel, in: work, to: archive)

        let imported = try MachineArchive.import(
            from: archive, library: [image], in: phone,
            createOwnDisk: { _, _ in throw MachineArchive.Refusal.damaged })
        let identity = SuspendedMachine.identity(of: kernel, named: imported.keys.settings)
        guard case .readable(let session) = SavedSession.find(kernel: identity, in: phone, core: .x86_64) else {
            return XCTFail("pas de session sous l'empreinte du noyau")
        }
        XCTAssertEqual(session, snapshot)
        XCTAssertTrue(RustPCSetting.runs(.x86_64, enabled: false, session: session),
                      "la session du cœur Rust choisit son cœur")
        XCTAssertEqual(KernelMemory.size(forKernel: imported.key, in: phone, ceiling: .max), UInt64(Self.ram))
        let layer = try LocalDisk.writesURL(for: imported.keys.overlay(forDisk: image), in: phone)
        XCTAssertThrowsError(try RustReadyDesktopBuild.check(session, ramSize: Self.ram, disk: iso, writes: layer)) {
            XCTAssertEqual($0 as? ReadyDesktopBuild.Refusal, .noTablet, "repris sur la couche importée")
        }
    }

    // MARK: - L'aléa de la reprise

    /// **Une reprise prend l'aléa de cet appareil.** L'instantané du cœur
    /// Rust porte l'état de son générateur : repris tel quel, un bureau prêt
    /// tirerait sur chaque téléphone la suite de la fabrique. `PendingSession`
    /// le remplace par la graine qu'on lui donne (celle du système dans
    /// l'application) : repris par la boîte, l'instantané n'est plus celui
    /// de la reprise seule, à huit octets près — l'état du générateur —, et
    /// deux graines donnent deux machines.
    func testAResumeTakesTheEntropyOfThisDevice() throws {
        let iso = try disk("void.iso")
        let writes = folder.appendingPathComponent("couche")
        let snapshot = try fabricated(iso: iso, writes: writes)
        func resumed(_ resume: (RustPCMachine) throws -> Void) throws -> Data {
            let machine = try XCTUnwrap(RustPCMachine.make(
                ramSize: Self.ram, network: { UserNetwork.isolated() }, onOutput: { _ in }))
            try machine.attachApplicationScreen()
            try machine.attachDisk(fileAt: iso, writes: writes)
            try resume(machine)
            return machine.snapshot()
        }
        let direct = try resumed { try $0.restore(snapshot) }
        let one = try resumed { XCTAssertTrue(try PendingSession(snapshot).resume(into: $0, seed: { 1 })) }
        let again = try resumed { XCTAssertTrue(try PendingSession(snapshot).resume(into: $0, seed: { 1 })) }
        let two = try resumed { XCTAssertTrue(try PendingSession(snapshot).resume(into: $0, seed: { 2 })) }
        XCTAssertNotEqual(one, direct, "l'aléa de la fabrique est resté")
        XCTAssertEqual(one, again, "la graine donnée est celle qui sert")
        XCTAssertNotEqual(one, two)
        // **Seul l'état du générateur change** : huit octets qui se suivent.
        XCTAssertEqual(one.count, direct.count)
        let changed = (0..<min(one.count, direct.count)).filter { one[$0] != direct[$0] }
        XCTAssertLessThanOrEqual(changed.count, 8, "\(changed)")
        XCTAssertLessThan((changed.last ?? 0) - (changed.first ?? 0), 8, "\(changed)")
    }

    // MARK: - Le bureau, pour de vrai

    /// **Un vrai bureau prêt du cœur Rust, par le chemin de l'application.**
    /// Armé par `WISQ_BUREAU_RUST_FICHE` (la fiche que `wisq-fabrique --coeur
    /// rust` écrit, l'archive à côté sous son nom) et `WISQ_BUREAU_ISO`
    /// (l'image). Comme le téléphone : l'entrée tirée de la fiche, choisie
    /// par l'index pour une application au cœur Rust (`ReadyDesktop.parse`),
    /// l'archive installée (`ReadyDesktop.install`, sa marque de première
    /// reprise comprise), la session cherchée et le cœur décidé par son format
    /// (`RustPCSetting.runs`), la machine de l'application
    /// (`RustPCMachine.make`), la couche importée, `PendingSession`, puis
    /// `FirstResume.resumed`. Ce qui est mesuré : le dépliage, la reprise,
    /// l'écran, la console, l'heure, la carte réseau, la tablette, les clés
    /// SSH refaites. L'archive est copiée avant l'installation, qui l'efface.
    func testARealRustDesktopComesBackThroughTheApplicationsPath() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let sheetPath = environment["WISQ_BUREAU_RUST_FICHE"], let isoPath = environment["WISQ_BUREAU_ISO"] else {
            throw XCTSkip("définir WISQ_BUREAU_RUST_FICHE (la fiche, l'archive à côté) et WISQ_BUREAU_ISO")
        }
        let sheet = try ReadyDesktopBuild.Sheet.decode(Data(contentsOf: URL(fileURLWithPath: sheetPath)))
        let source = URL(fileURLWithPath: sheetPath).deletingLastPathComponent().appendingPathComponent(sheet.archive.name)
        let base = URL(string: "https://github.com/maxlestage/wisq/releases/download/bureaux-1")!
        let entry = ReadyDesktop.Index.Entry(
            sheet: sheet, image: URL(string: "https://repo-default.voidlinux.org/live/20250202")!
                .appendingPathComponent(sheet.image.name),
            archive: base.appendingPathComponent(sheet.archive.name))
        let text = String(decoding: try ReadyDesktop.Index(desktops: [entry]).encoded(), as: UTF8.self)
        let desktop = try XCTUnwrap(
            ReadyDesktop.parse(text, rustLevel: UInt64(RustPCSnapshot.version)).first, "l'entrée n'est pas proposée")
        XCTAssertEqual(desktop.core, .rust)

        let phone = folder.appendingPathComponent("telephone")
        try FileManager.default.createDirectory(at: phone, withIntermediateDirectories: true)
        let archive = folder.appendingPathComponent(sheet.archive.name)
        try FileManager.default.copyItem(at: source, to: archive)
        let iso = URL(fileURLWithPath: isoPath)
        let digest = try XCTUnwrap(IsoBoot.kernelDigest(
            of: iso, scratch: folder.appendingPathComponent("noyau"), ceiling: UInt64(ReadyDesktop.digestScratch)))
        let installStart = Date()
        let installed = try desktop.install(
            archive: archive, imageKernelDigest: digest, library: [sheet.image.name], in: phone,
            createOwnDisk: { _, _ in throw MachineArchive.Refusal.damaged })
        let installSeconds = Date().timeIntervalSince(installStart)

        // **Ce que `LocalVMModel.boot` fait**, dans son ordre.
        let identity = SuspendedMachine.identity(digest: desktop.kernelDigest, named: installed.keys.settings)
        let opened = Date()
        let found = SavedSession.find(kernel: identity, in: phone, core: .x86_64)
        guard case .readable(let session) = found else { return XCTFail("session : \(found)") }
        let unpackSeconds = Date().timeIntervalSince(opened)
        XCTAssertTrue(RustPCSetting.runs(.x86_64, enabled: false, session: session))
        let first = FirstResume.pending(kernel: identity, in: phone)
        XCTAssertNotNil(first, "la marque de la première reprise")
        let savedAt = SuspendedMachine.savedAt(kernel: identity, in: phone)
        let ramSize = try XCTUnwrap(SessionMemory.savedRAMSize(session, core: .x86_64))
        XCTAssertEqual(UInt64(ramSize), desktop.ramBytes)
        let console = GuestConsole()
        let machine = try XCTUnwrap(RustPCMachine.make(
            ramSize: ramSize, network: { MachineNetwork.backend(forKernel: installed.keys.settings, in: phone) },
            onOutput: { console.append($0) }))
        try machine.attachApplicationScreen()
        try machine.attachDisk(fileAt: iso, writes: LocalDisk.writesURL(
            for: installed.keys.overlay(forDisk: sheet.image.name), in: phone))
        let pending = PendingSession(session)
        let restoreStart = Date()
        XCTAssertTrue(try pending.resume(into: machine))
        let restoreSeconds = Date().timeIntervalSince(restoreStart)
        let line = FirstResume.resumed(machine, first: first, savedAt: savedAt)
        XCTAssertNotNil(line, "la première reprise n'a rien tapé")
        let screenAtResume = GuestScript.litFraction(machine.screenPixels ?? [])
        XCTAssertGreaterThan(screenAtResume, 0.5, "l'écran repris est noir")
        print("installation \(String(format: "%.2f", installSeconds)) s ; session lue et dépliée "
            + "\(String(format: "%.2f", unpackSeconds)) s (\(session.count) octets) ; reprise "
            + "\(String(format: "%.2f", restoreSeconds)) s ; écran allumé à \(Int(screenAtResume * 100)) %")

        let script = GuestScript(machine: machine, console: console)
        let budget: UInt64 = 400_000_000_000
        let started = Date()
        script.type("echo REPRIS_$((6*7))\n")
        try script.expect("REPRIS_42", budget: budget)
        print("la console répond \(String(format: "%.1f", Date().timeIntervalSince(started))) s après la reprise")

        script.type("pgrep -x xfdesktop >/dev/null && echo FOND_VIVANT_$((2+2)); echo FOND_$((1+1))\n")
        try script.expect("FOND_2", budget: budget)
        XCTAssertTrue(console.contains("FOND_VIVANT_4", after: script.mark), "xfdesktop ne tourne plus")

        // **L'heure** : celle de l'invité, et celle que sert son horloge
        // CMOS, contre l'heure de l'hôte.
        script.type("echo HEURE_$(date +%s)_RTC_$(cat \(FirstResume.rtcSeconds))_FIN$((3+4))\n")
        try script.expect("_FIN7", budget: budget)
        let host = Date().timeIntervalSince1970
        let tail = console.text.components(separatedBy: "HEURE_").last ?? ""
        let guest = TimeInterval(tail.prefix { $0.isNumber }) ?? 0
        let rtcPart = tail.components(separatedBy: "_RTC_").dropFirst().first ?? ""
        let rtc = TimeInterval(rtcPart.prefix { $0.isNumber }) ?? 0
        print("heure de l'invité \(Int(guest)), de son horloge CMOS \(Int(rtc)), de l'hôte \(Int(host)) : "
            + "écarts \(Int(host - guest)) s et \(Int(host - rtc)) s")
        XCTAssertLessThan(abs(host - guest), 120, "la première reprise n'a pas remis l'heure")
        XCTAssertLessThan(abs(host - rtc), 120, "l'horloge CMOS reprise n'est pas celle de l'hôte")

        script.type("echo NET_$(ls /sys/bus/virtio/drivers/virtio_net | grep -c virtio)_FIN$((1+1))\n")
        try script.expect("_FIN2", budget: budget)
        XCTAssertTrue(console.contains("NET_1_FIN2", after: script.mark), "l'invité n'a plus de carte réseau")

        script.type("D=$(grep -A6 'wisq tablet' /proc/bus/input/devices | grep -o 'event[0-9]*'); "
            + "(dd if=/dev/input/$D bs=24 count=4 status=none | wc -c | sed 's/^/LU_/' &); sleep 3; echo PRET_$((1+1))\n")
        try script.expect("PRET_2", budget: budget)
        XCTAssertTrue(machine.touch(x: 0.3, y: 0.4, buttons: 0))
        XCTAssertTrue(machine.touch(x: 0.6, y: 0.5, buttons: 0))
        XCTAssertNoThrow(try script.expect("LU_96", budget: budget), "la tablette ne parle plus à l'invité")

        script.type("until pgrep -x sshd >/dev/null && [ -s /etc/ssh/ssh_host_ed25519_key.pub ]; do sleep 5; done; "
            + "sleep 5; A=$(ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub | cut -d' ' -f2); "
            + "B=$(ssh-keyscan -t ed25519 127.0.0.1 2>/dev/null | ssh-keygen -lf - | cut -d' ' -f2); "
            + "[ -n \"$A\" ] && [ \"$A\" = \"$B\" ] && echo CLE_SERVIE_$((1+1)) $A; echo CLE_$((3+3))\n")
        try script.expect("CLE_6", budget: budget)
        XCTAssertTrue(console.contains("CLE_SERVIE_2", after: script.mark),
                      "sshd ne présente pas la clé refaite après la reprise")
        print("clés refaites \(String(format: "%.1f", Date().timeIntervalSince(started))) s après la reprise")
        XCTAssertGreaterThan(GuestScript.litFraction(machine.screenPixels ?? []), 0.5, "l'écran s'est éteint")
        if let out = environment["WISQ_BUREAU_CONSOLE"] {
            FileManager.default.createFile(atPath: out, contents: Data(console.text.utf8))
        }
        print(console.text.suffix(800))
    }
}
