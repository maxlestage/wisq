import XCTest
@testable import WisqVM

/// **Une session d'image de cloud, sauvée puis reprise**, par le chemin de
/// l'application : `X86Machine`, l'image de cloud comme disque sur fichier
/// avec sa couche d'écriture, `snapshot()` puis `restore()` dans une machine
/// neuve. C'est ce que vit un iPhone quand wisq passe en arrière-plan au
/// milieu d'une session, puis revient.
///
/// Armé seulement quand on lui donne l'image (`WISQ_PC_CLOUD_IMAGE`) et qu'on
/// le demande (`WISQ_PC_RESUME`) : il démarre l'image jusqu'au shell de
/// `root` — une quinzaine de minutes pour Debian, une vingtaine pour Fedora,
/// trois quarts d'heure pour Ubuntu. Debian, Fedora et Ubuntu passent par le
/// même test : l'invite de `root` est `~# ` chez Debian et Ubuntu, et
/// `~]# ` chez Fedora, et c'est `/etc/os-release` qui répond à la fin.
final class X86CloudResumeTests: XCTestCase {
    /// La console, recueillie depuis le fil de la machine.
    final class Console: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes: [UInt8] = []
        func append(_ data: Data) { lock.withLock { bytes += data } }
        var text: String { lock.withLock { String(decoding: bytes, as: UTF8.self) } }
        var count: Int { lock.withLock { bytes.count } }
    }

    /// Fait tourner `machine` par tranches jusqu'à ce que la console, depuis
    /// `from`, contienne `wanted`, ou que `budget` soit épuisé.
    private func run(_ machine: X86Machine, until wanted: String..., in console: Console, from: Int,
                     budget: UInt64) -> Bool {
        var spent: UInt64 = 0
        while spent < budget {
            let before = machine.retiredInstructions
            _ = machine.run(instructionBudget: 50_000_000)
            spent += max(machine.retiredInstructions &- before, 1)
            let fresh = String(console.text.utf8.dropFirst(from)) ?? ""
            if wanted.contains(where: { fresh.contains($0) }) { return true }
        }
        return false
    }

    func testACloudSessionComesBackWhereItWas() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["WISQ_PC_CLOUD_IMAGE"], environment["WISQ_PC_RESUME"] != nil else {
            throw XCTSkip("définir WISQ_PC_CLOUD_IMAGE et WISQ_PC_RESUME pour ce test")
        }
        let image = URL(fileURLWithPath: path)
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("wisq-reprise-\(getpid())-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let unpacked = try XCTUnwrap(CloudBoot.unpack(image, into: folder)).get()
        let writes = folder.appendingPathComponent("disque.writes")

        // Le premier démarrage, jusqu'au shell de `root`.
        let console = Console()
        let first = X86Machine(ramSize: CloudBoot.minimumRAMSize) { console.append($0) }
        try first.attach(diskFileAt: image, writes: writes)
        try first.load(kernelImage: try Data(contentsOf: unpacked.kernel), commandLine: unpacked.commandLine,
                       initialRamdisk: try unpacked.initrd.map { try Data(contentsOf: $0) })
        var started = Date()
        XCTAssertTrue(run(first, until: "~# ", "~]# ", in: console, from: 0, budget: 80_000_000_000),
                      "le shell de root n'est pas venu")
        print("démarrage : \(first.retiredInstructions) instructions en \(Int(Date().timeIntervalSince(started))) s")

        // Une trace dans la session : une variable du shell, qui ne vit que
        // dans la mémoire du processus — rien sur le disque ne la garde.
        var mark = console.count
        first.send(Data("TEMOIN=wisq-reprise; echo pr\"\"et\n".utf8))
        XCTAssertTrue(run(first, until: "pret\r\n", in: console, from: mark, budget: 5_000_000_000))

        // La sauvegarde, comme quand l'application passe en arrière-plan.
        started = Date()
        let saved = first.snapshot()
        let saving = Date().timeIntervalSince(started)
        print("instantané : \(saved.count / (1 << 20)) Mio en \(String(format: "%.2f", saving)) s")
        // Gardé, si on le demande, pour en étudier le contenu ailleurs.
        if let out = environment["WISQ_PC_SNAPSHOT_OUT"] { try saved.write(to: URL(fileURLWithPath: out)) }

        // Une machine neuve, le même disque et sa couche, l'instantané.
        let resumed = Console()
        let second = X86Machine(ramSize: CloudBoot.minimumRAMSize) { resumed.append($0) }
        try second.attach(diskFileAt: image, writes: writes)
        started = Date()
        try second.restore(saved)
        print("reprise : \(String(format: "%.2f", Date().timeIntervalSince(started))) s")

        // La session est celle d'avant : la variable du shell est encore là,
        // et le disque répond.
        mark = resumed.count
        second.send(Data("echo $TEMOIN; cat /etc/os-release\n".utf8))
        XCTAssertTrue(run(second, until: "wisq-reprise\r\n", in: resumed, from: mark, budget: 5_000_000_000),
                      "la variable du shell n'a pas survécu : \(resumed.text.suffix(400))")
        XCTAssertTrue(run(second, until: "VERSION_ID=", in: resumed, from: mark, budget: 5_000_000_000),
                      "le disque n'a pas répondu : \(resumed.text.suffix(400))")
        // Les lignes qui disent quelque chose : chez Fedora et Ubuntu, bash
        // entoure chaque invite d'une séquence OSC 3008 de systemd 259, assez
        // longue pour noyer les trois cents derniers octets.
        let said = resumed.text.split(whereSeparator: \.isNewline)
            .filter { $0.contains("wisq-reprise") || $0.hasPrefix("PRETTY_NAME=") || $0.hasPrefix("VERSION_ID=") }
        print(said.joined(separator: "\n"))
    }

    // MARK: - Profiler à partir d'un instantané

    /// **Un instantané au milieu du démarrage**, pour profiler ce qui suit.
    /// Callgrind ne peut pas suivre un démarrage entier — cinquante fois plus
    /// lent, Fedora y passerait seize heures —, mais il peut suivre quelques
    /// centaines de millions d'instructions reprises d'un instantané. Avec
    /// `WISQ_PC_CLOUD_IMAGE`, `WISQ_PC_SNAPSHOT_AT` (en instructions retirées)
    /// et `WISQ_PC_SNAPSHOT_OUT` : l'instantané est écrit à ce nom, et la
    /// couche d'écriture du disque, qui va avec, à côté (`.writes`).
    func testASnapshotIsTakenPartWayThroughTheBoot() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["WISQ_PC_CLOUD_IMAGE"],
              let at = environment["WISQ_PC_SNAPSHOT_AT"].flatMap(UInt64.init),
              let out = environment["WISQ_PC_SNAPSHOT_OUT"]
        else { throw XCTSkip("définir WISQ_PC_CLOUD_IMAGE, WISQ_PC_SNAPSHOT_AT et WISQ_PC_SNAPSHOT_OUT") }
        let image = URL(fileURLWithPath: path)
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("wisq-profil-\(getpid())-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let unpacked = try XCTUnwrap(CloudBoot.unpack(image, into: folder)).get()
        let writes = URL(fileURLWithPath: out + ".writes")
        for suffix in ["", ".map"] { try? FileManager.default.removeItem(atPath: writes.path + suffix) }
        let machine = X86Machine(ramSize: CloudBoot.minimumRAMSize) { _ in }
        try machine.attach(diskFileAt: image, writes: writes)
        try machine.load(kernelImage: try Data(contentsOf: unpacked.kernel), commandLine: unpacked.commandLine,
                         initialRamdisk: try unpacked.initrd.map { try Data(contentsOf: $0) })
        while machine.retiredInstructions < at {
            _ = machine.run(instructionBudget: min(50_000_000, at - machine.retiredInstructions))
        }
        machine.flushDisk()
        try machine.snapshot().write(to: URL(fileURLWithPath: out))
        print("instantané à \(machine.retiredInstructions) instructions : \(out)")
    }

    /// **Reprendre l'instantané et faire tourner un budget**, sans rien
    /// d'autre : c'est ce que callgrind suit. Avec `WISQ_PC_CLOUD_IMAGE`,
    /// `WISQ_PC_FROM_SNAPSHOT` et `WISQ_PC_BUDGET`. La couche d'écriture est
    /// copiée avant : l'instantané reste rejouable autant de fois qu'on veut.
    func testASnapshotRunsAFixedBudget() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["WISQ_PC_CLOUD_IMAGE"], let from = environment["WISQ_PC_FROM_SNAPSHOT"],
              let budget = environment["WISQ_PC_BUDGET"].flatMap(UInt64.init)
        else { throw XCTSkip("définir WISQ_PC_CLOUD_IMAGE, WISQ_PC_FROM_SNAPSHOT et WISQ_PC_BUDGET") }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("wisq-profil-\(getpid())-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let writes = folder.appendingPathComponent("disque.writes")
        for suffix in ["", ".map"] where FileManager.default.fileExists(atPath: from + ".writes" + suffix) {
            try FileManager.default.copyItem(atPath: from + ".writes" + suffix, toPath: writes.path + suffix)
        }
        let machine = X86Machine(ramSize: CloudBoot.minimumRAMSize) { _ in }
        try machine.attach(diskFileAt: URL(fileURLWithPath: path), writes: writes)
        try machine.restore(try Data(contentsOf: URL(fileURLWithPath: from)))
        let start = machine.retiredInstructions
        let started = Date()
        _ = machine.run(instructionBudget: budget)
        print("\(machine.retiredInstructions - start) instructions en \(Date().timeIntervalSince(started)) s")
    }
}
