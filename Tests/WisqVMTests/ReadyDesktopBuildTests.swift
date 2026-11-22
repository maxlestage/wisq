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

    /// L'instantané, son niveau réécrit. La section suit la mémoire, et sa
    /// marque n'y paraît qu'une fois.
    static func levelOffset(in snapshot: Data) throws -> Int {
        let marker = withUnsafeBytes(of: Snapshot.levelSection.littleEndian) { Data($0) }
        let found = try XCTUnwrap(snapshot.range(of: marker), "pas de section du niveau")
        XCTAssertNil(snapshot.range(of: marker, in: found.upperBound..<snapshot.endIndex), "une seule marque")
        return found.upperBound
    }

    static func withLevel(_ level: UInt64, in snapshot: Data) throws -> Data {
        let at = try levelOffset(in: snapshot)
        var patched = snapshot
        patched.replaceSubrange(at..<at + 8, with: withUnsafeBytes(of: level.littleEndian) { Data($0) })
        return patched
    }

    /// **Un autre niveau de machine est refusé**, plus ancien comme plus
    /// récent : la fiche annonce le niveau de cette version, et un bureau
    /// pris par une autre machine que celle-ci n'est pas celui qu'on publie.
    func testAnotherLevelIsRefused() throws {
        let machine = try ReadyDesktopBuild.machine(ramSize: Self.ram, frozenAt: Self.moment) { _ in }
        let snapshot = try Self.snapshot(of: machine)
        XCTAssertNoThrow(try ReadyDesktopBuild.check(snapshot, ramSize: Self.ram))
        for level in [0, X86Machine.snapshotLevel + 1] {
            let other = try Self.withLevel(level, in: snapshot)
            XCTAssertEqual(X86Machine.savedLevel(in: other), level)
            XCTAssertThrowsError(try ReadyDesktopBuild.check(other, ramSize: Self.ram)) {
                XCTAssertEqual($0 as? ReadyDesktopBuild.Refusal,
                               .level(saved: level, expected: X86Machine.snapshotLevel), "niveau \(level)")
            }
        }
    }

    /// **Un instantané qui ne se reprend pas est dit illisible**, avec la
    /// raison de la reprise : ici, coupé au milieu de la pile x87, alors que
    /// son niveau et sa mémoire se lisent encore.
    func testASnapshotThatDoesNotComeBackIsUnreadable() throws {
        let machine = try ReadyDesktopBuild.machine(ramSize: Self.ram, frozenAt: nil) { _ in }
        let snapshot = try Self.snapshot(of: machine)
        let cut = Data(snapshot.prefix(try Self.levelOffset(in: snapshot) + 8 + 12))
        XCTAssertEqual(X86Machine.savedLevel(in: cut), X86Machine.snapshotLevel)
        XCTAssertEqual(X86Machine.savedRAMSize(in: cut), Self.ram)
        XCTAssertThrowsError(try ReadyDesktopBuild.check(cut, ramSize: Self.ram)) { error in
            guard case .unreadable(let why)? = error as? ReadyDesktopBuild.Refusal else {
                return XCTFail("refusé autrement : \(error)")
            }
            XCTAssertFalse(why.isEmpty)
        }
    }

    // MARK: - L'heure et les clés

    /// **La passerelle sert l'heure figée**, comme l'horloge CMOS : un client
    /// NTP de l'invité (`chronyd` tourne dans le bureau Void) recevait
    /// l'heure vraie de l'hôte. La machine de l'application, elle, sert
    /// l'heure du système.
    func testTheGatewayServesTheFrozenTime() throws {
        func served(by machine: X86Machine) throws -> TimeInterval {
            let network = try XCTUnwrap(machine.network?.backend as? UserNetwork)
            defer { network.streams?.close() }
            network.send(UserNetworkTimeTests.frame(UserNetworkTimeTests.request(sent: [1, 1, 1, 1, 1, 1, 1, 1])))
            let reply = try XCTUnwrap(network.receive().first)
            let ntp = Array(reply[(14 + 20 + 8)...])
            return TimeInterval(UserNetwork.be32(ntp, 40)) - UserNetwork.ntpEpochOffset
        }
        let frozen = try ReadyDesktopBuild.machine(ramSize: Self.ram, frozenAt: Self.moment) { _ in }
        XCTAssertEqual(try served(by: frozen), Self.moment.timeIntervalSince1970)
        let live = try ReadyDesktopBuild.machine(ramSize: Self.ram, frozenAt: nil) { _ in }
        XCTAssertEqual(try served(by: live), Date().timeIntervalSince1970, accuracy: 5)
    }

    /// **`sshd` est arrêté avant que ses clés soient effacées**, et la
    /// préparation le prouve avant sa marque. Depuis OpenSSH 9.8 l'écouteur
    /// garde les clés en mémoire : effacer les fichiers sous un `sshd`
    /// vivant laissait la clé de la fabrication à toutes les copies.
    func testSSHIsStoppedBeforeItsKeysAreErased() throws {
        let line = ReadyDesktopBuild.prepare
        let stop = try XCTUnwrap(line.range(of: "sv down sshd;"))
        let erase = try XCTUnwrap(line.range(of: "rm -f /etc/ssh/ssh_host_*;"))
        XCTAssertLessThan(stop.lowerBound, erase.lowerBound)
        XCTAssertTrue(line.contains("setsid sh -c '\(ReadyDesktopBuild.keyWatcher)' </dev/null"))
        XCTAssertFalse(ReadyDesktopBuild.keyWatcher.contains("'"), "le guetteur tient entre apostrophes")
        let proof = try XCTUnwrap(line.range(of: "if pgrep -x sshd >/dev/null || ! test -r "
            + ReadyDesktopBuild.rtcSeconds + "; then echo REFUS_$((2+2)); else echo PRET_$((1+1)); fi"))
        XCTAssertLessThan(erase.lowerBound, proof.lowerBound)
        XCTAssertEqual(ReadyDesktopBuild.preparationRefused, "REFUS_4")
        XCTAssertGreaterThan(ReadyDesktopBuild.reseedWait, 60,
                             "plus de soixante secondes : le noyau réensemence alors son générateur")
        XCTAssertEqual(ReadyDesktopBuild.keyWatcher,
                       ReadyDesktopBuild.watcher(clock: ReadyDesktopBuild.rtcSeconds, poll: "5",
                                                 settle: "\(ReadyDesktopBuild.reseedWait)"))
    }

    /// **Le guetteur, joué par un vrai `sh`** : tant que l'horloge ne bouge
    /// pas, il ne fait rien ; dès qu'elle bouge, il **attend** encore
    /// (`settle`), puis refait les clés, **puis** relance `sshd`, et s'en
    /// va. `ssh-keygen`, `sv` et `sleep` sont des doublures qui notent leur
    /// appel ; `sleep` dort vraiment ensuite.
    ///
    /// L'attente est ce qui rend chaque clé unique (`keyWatcher`) : le test
    /// la mesure. Une seconde, et aucun appel noté une demi-seconde après
    /// que l'horloge a bougé ; puis au moins une seconde entre l'horloge et
    /// la fin du guetteur. Les deux bornes ne tiennent que si le guetteur
    /// a dormi : une machine chargée ne fait que les élargir.
    func testTheWatcherWaitsForTheClockToMove() throws {
        let files = FileManager.default
        let folder = files.temporaryDirectory.appendingPathComponent("wisq-guetteur-\(UUID().uuidString)")
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: folder) }
        let log = folder.appendingPathComponent("appels")
        let naps = folder.appendingPathComponent("sommes")
        func write(_ script: String, as tool: String) throws {
            let stub = folder.appendingPathComponent(tool)
            try Data(script.utf8).write(to: stub)
            try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        }
        for tool in ["ssh-keygen", "sv"] {
            try write("#!/bin/sh\necho \(tool) \"$@\" >> '\(log.path)'\n", as: tool)
        }
        try write("#!/bin/sh\necho sleep \"$@\" >> '\(naps.path)'\nexec /bin/sleep \"$@\"\n", as: "sleep")
        func text(_ file: URL) -> String { String(decoding: (try? Data(contentsOf: file)) ?? Data(), as: UTF8.self) }
        func waitUntil(_ done: () -> Bool) {
            let deadline = Date().addingTimeInterval(10)
            while !done(), Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        }
        let clock = folder.appendingPathComponent("since_epoch")
        try Data("1794614400\n".utf8).write(to: clock)
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", ReadyDesktopBuild.watcher(clock: clock.path, poll: "0.05", settle: "1")]
        shell.environment = ["PATH": folder.path + ":/usr/bin:/bin"]
        try shell.run()
        defer { if shell.isRunning { shell.terminate() } }

        // Le premier somme de la boucle prouve que `t` est lu : l'horloge ne
        // change pas avant, même si `sh` tarde à démarrer.
        waitUntil { text(naps).hasPrefix("sleep 0.05\n") }
        XCTAssertTrue(text(naps).hasPrefix("sleep 0.05\n"), "le guetteur est entré dans sa boucle")
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertTrue(shell.isRunning, "l'horloge figée : le guetteur attend")
        XCTAssertFalse(files.fileExists(atPath: log.path), "rien refait à la fabrique")

        // L'instant est pris avant l'écriture : le guetteur ne peut pas voir
        // l'horloge bouger plus tôt, la borne d'une seconde est donc sûre.
        let moved = Date()
        try Data("1794614401\n".utf8).write(to: clock, options: .atomic)
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertFalse(files.fileExists(atPath: log.path), "pas de clé avant la fin de l'attente")
        waitUntil { !shell.isRunning }
        XCTAssertFalse(shell.isRunning, "le guetteur a fini")
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(moved), 1, "le guetteur a dormi son attente")
        XCTAssertTrue(text(naps).hasSuffix("sleep 0.05\nsleep 1\n"), "l'attente vient après la boucle")
        XCTAssertEqual(text(log), "ssh-keygen -A\nsv up sshd\n")
    }

    // MARK: - Les réglages

    /// **La mémoire se juge avant de démarrer** : `--ram 1500` tournait
    /// quarante minutes avant que l'assemblage la refuse.
    func testTheMemoryIsJudgedBeforeTheBoot() {
        let gibibyte = 1 << 30
        XCTAssertEqual(try ReadyDesktopBuild.memory(requestedMiB: nil, minimum: gibibyte), gibibyte)
        XCTAssertEqual(try ReadyDesktopBuild.memory(requestedMiB: nil, minimum: 0), X86Machine.minimumRAMSize)
        XCTAssertEqual(try ReadyDesktopBuild.memory(requestedMiB: "2048", minimum: gibibyte), 2 * gibibyte)
        let refused: [(String, ReadyDesktopBuild.Refusal)] = [
            ("1500", .unrecordableMemory(1500 << 20)),
            ("512", .memoryBelowMinimum(requested: 512 << 20, minimum: gibibyte)),
            ("mille", .unreadableOption("--ram", value: "mille")),
            ("0", .unreadableOption("--ram", value: "0")),
            ("-1024", .unreadableOption("--ram", value: "-1024")),
        ]
        for (text, refusal) in refused {
            XCTAssertThrowsError(try ReadyDesktopBuild.memory(requestedMiB: text, minimum: gibibyte), text) {
                XCTAssertEqual($0 as? ReadyDesktopBuild.Refusal, refusal, text)
            }
        }
    }

    /// **Un budget illisible est refusé**, au lieu d'être remplacé sans un
    /// mot par celui par défaut.
    func testAnUnreadableBudgetIsRefused() {
        XCTAssertEqual(try ReadyDesktopBuild.budget(nil), 2_000_000_000_000)
        XCTAssertEqual(try ReadyDesktopBuild.budget("5000"), 5000)
        for text in ["2e12", "", "0", "beaucoup"] {
            XCTAssertThrowsError(try ReadyDesktopBuild.budget(text), text) {
                XCTAssertEqual($0 as? ReadyDesktopBuild.Refusal, .unreadableOption("--budget", value: text))
            }
        }
    }

    /// **Le cœur de la fabrication**, jugé avant la demi-heure de
    /// démarrage : le cœur Swift sans l'option, comme avant elle ; `rust` ;
    /// rien d'autre.
    func testTheCoreIsJudgedBeforeTheBoot() {
        XCTAssertEqual(try ReadyDesktopBuild.core(nil), .swift)
        XCTAssertEqual(try ReadyDesktopBuild.core("swift"), .swift)
        XCTAssertEqual(try ReadyDesktopBuild.core("rust"), .rust)
        for text in ["Rust", "", "emetteur", "rust "] {
            XCTAssertThrowsError(try ReadyDesktopBuild.core(text), text) {
                XCTAssertEqual($0 as? ReadyDesktopBuild.Refusal, .unreadableOption("--coeur", value: text))
            }
        }
    }

    /// **L'assemblage lit la mémoire du cœur qui a écrit l'instantané** :
    /// l'en-tête `WISQPC\r\n` du cœur Rust, que `X86Machine` ne lit pas. La
    /// mémoire réglée de la machine importée est celle de l'en-tête, et la
    /// session se retrouve sous l'empreinte du noyau, lisible.
    func testARustSnapshotIsAssembledAtItsOwnMemory() throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent("wisq-pret-\(UUID().uuidString)")
        defer { try? files.removeItem(at: root) }
        let work = root.appendingPathComponent("atelier")
        let fresh = root.appendingPathComponent("telephone")
        for folder in [work, fresh] { try files.createDirectory(at: folder, withIntermediateDirectories: true) }
        let ram = 1 << 30
        var header = Array("WISQPC\r\n".utf8)
        header += withUnsafeBytes(of: RustPCSnapshot.version.littleEndian, Array.init)
        header += withUnsafeBytes(of: UInt64(ram).littleEndian, Array.init)
        let snapshot = Data(header + (0..<4096).map { UInt8(truncatingIfNeeded: $0) })
        XCTAssertNil(X86Machine.savedRAMSize(in: snapshot), "le cœur Swift ne lit pas cet en-tête")
        let (installed, _) = try ReadyDesktopBuild.install(image: "void.iso", name: "Void Xfce (prêt)", in: work)
        let archive = root.appendingPathComponent("bureau.wisqmachine")
        let kernel = Data([4, 5, 6])
        try ReadyDesktopBuild.assemble(installed, snapshot: snapshot, kernel: kernel, in: work, to: archive)
        let imported = try MachineArchive.import(
            from: archive, library: ["void.iso"], in: fresh,
            createOwnDisk: { _, _ in throw MachineArchive.Refusal.damaged })
        XCTAssertEqual(KernelMemory.size(forKernel: imported.key, in: fresh, ceiling: .max), UInt64(ram))
        let found = SavedSession.find(
            kernel: SuspendedMachine.identity(of: kernel, named: imported.keys.settings), in: fresh, core: .x86_64)
        guard case .readable(let session) = found else { return XCTFail("session : \(found)") }
        XCTAssertEqual(session, snapshot)
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
            installed, snapshot: snapshot, kernel: kernel, in: work, to: archive)
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
        XCTAssertEqual(KernelMemory.size(forKernel: imported.key, in: fresh, ceiling: .max), UInt64(Self.ram),
                       "la mémoire réglée n'est pas celle de la session")
        let layer = try LocalDisk.writesURL(for: imported.keys.overlay(forDisk: image), in: fresh)
        XCTAssertTrue(files.fileExists(atPath: layer.path + ".map"), "la couche n'a pas suivi")
        // Et la machine reprend dans une machine de l'application neuve.
        XCTAssertNoThrow(try ReadyDesktopBuild.check(try XCTUnwrap(found.snapshot), ramSize: Self.ram))
    }

    /// **Deux assemblages du même instantané sont les mêmes octets**, bien
    /// que chacun installe sa machine sous une clé tirée au sort et à sa
    /// date : ni l'une ni l'autre n'entre dans l'archive (la session y est
    /// nommée par l'empreinte du noyau seule, la couche par le nom du
    /// disque). Deux bureaux prêts se comparent donc par la somme de leur
    /// archive.
    func testTwoAssembliesOfTheSameSnapshotAreTheSameBytes() throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent("wisq-pret-\(UUID().uuidString)")
        defer { try? files.removeItem(at: root) }
        let machine = try ReadyDesktopBuild.machine(ramSize: Self.ram, frozenAt: Self.moment) { _ in }
        let snapshot = try Self.snapshot(of: machine)
        var archives: [Data] = []
        var keys: [String] = []
        for (index, day) in [0.0, 86_400.0].enumerated() {
            let work = root.appendingPathComponent("atelier-\(index)")
            try files.createDirectory(at: work, withIntermediateDirectories: true)
            let (installed, _) = try ReadyDesktopBuild.install(
                image: "void.iso", name: "Void Xfce (prêt)", in: work, now: Self.moment.addingTimeInterval(day))
            let archive = work.appendingPathComponent("bureau.wisqmachine")
            try ReadyDesktopBuild.assemble(installed, snapshot: snapshot, kernel: Data([1, 2, 3]), in: work, to: archive)
            archives.append(try Data(contentsOf: archive))
            keys.append(installed.key)
        }
        XCTAssertNotEqual(keys[0], keys[1])
        XCTAssertEqual(archives[0], archives[1])
    }

    /// **Une mémoire que l'application ne sait pas régler est refusée** à
    /// l'assemblage, plutôt qu'emportée sous le réglage par défaut.
    func testAMemoryTheApplicationCannotRecordIsRefused() throws {
        let files = FileManager.default
        let work = files.temporaryDirectory.appendingPathComponent("wisq-pret-\(UUID().uuidString)")
        defer { try? files.removeItem(at: work) }
        try files.createDirectory(at: work, withIntermediateDirectories: true)
        let (installed, _) = try ReadyDesktopBuild.install(image: "void.iso", name: "Void", in: work)
        let odd = X86Machine(ramSize: Self.ram + (1 << 20), onOutput: { _ in })
        XCTAssertThrowsError(try ReadyDesktopBuild.assemble(
            installed, snapshot: odd.snapshot(), kernel: Data([1]), in: work,
            to: work.appendingPathComponent("bureau.wisqmachine"))) {
            XCTAssertEqual($0 as? ReadyDesktopBuild.Refusal, .unrecordableMemory(Self.ram + (1 << 20)))
        }
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
