import XCTest
@testable import WisqVM

/// **Une session Debian, sauvée puis reprise**, par le chemin de
/// l'application : `X86Machine`, l'image de cloud comme disque sur fichier
/// avec sa couche d'écriture, `snapshot()` puis `restore()` dans une machine
/// neuve. C'est ce que vit un iPhone quand wisq passe en arrière-plan au
/// milieu d'une session, puis revient.
///
/// Armé seulement quand on lui donne l'image (`WISQ_PC_CLOUD_IMAGE`) et qu'on
/// le demande (`WISQ_PC_RESUME`) : il démarre Debian jusqu'au shell de `root`,
/// une quinzaine de minutes.
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
    private func run(_ machine: X86Machine, until wanted: String, in console: Console, from: Int,
                     budget: UInt64) -> Bool {
        var spent: UInt64 = 0
        while spent < budget {
            let before = machine.retiredInstructions
            _ = machine.run(instructionBudget: 50_000_000)
            spent += max(machine.retiredInstructions &- before, 1)
            if String(console.text.utf8.dropFirst(from)).map({ $0.contains(wanted) }) ?? false { return true }
        }
        return false
    }

    func testADebianSessionComesBackWhereItWas() throws {
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
        let writes = folder.appendingPathComponent("debian.writes")

        // Le premier démarrage, jusqu'au shell de `root`.
        let console = Console()
        let first = X86Machine(ramSize: CloudBoot.minimumRAMSize) { console.append($0) }
        try first.attach(diskFileAt: image, writes: writes)
        try first.load(kernelImage: try Data(contentsOf: unpacked.kernel), commandLine: unpacked.commandLine,
                       initialRamdisk: try unpacked.initrd.map { try Data(contentsOf: $0) })
        var started = Date()
        XCTAssertTrue(run(first, until: "~# ", in: console, from: 0, budget: 40_000_000_000),
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
        second.send(Data("echo $TEMOIN; cat /etc/debian_version\n".utf8))
        XCTAssertTrue(run(second, until: "wisq-reprise\r\n", in: resumed, from: mark, budget: 5_000_000_000),
                      "la variable du shell n'a pas survécu : \(resumed.text.suffix(400))")
        XCTAssertTrue(run(second, until: "13.", in: resumed, from: mark, budget: 5_000_000_000))
        print(String(resumed.text.suffix(300)))
    }
}
