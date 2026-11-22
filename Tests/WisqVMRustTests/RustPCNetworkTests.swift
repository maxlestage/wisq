import CWisqVM
import Foundation
@testable import WisqVM
@testable import WisqVMRust
import XCTest

#if canImport(Glibc)
import Glibc
#endif

/// **Le réseau de la machine PC en Rust**, par l'enveloppe de l'application :
/// la carte virtio-net branchée sur un `NetworkBackend` — le même protocole,
/// et la même pile `UserNetwork`, que le cœur Swift —, des trames qui passent
/// dans les deux sens à chaque tranche de `run`, le réglage qui coupe le
/// réseau d'une machine, et le relais du port du bureau.
///
/// L'invité est le pilote réseau minimal (`Tests/Fixtures/pc-noyau-reseau.bin`,
/// que `crates/wisq-vm/tests/pc_reseau.rs` vérifie octet pour octet) : il émet
/// une trame, attend qu'une trame tombe sur son propre code, l'exécute et
/// s'éteint — « oR » sur sa console.
final class RustPCNetworkTests: XCTestCase {
    private static let ram = 128 << 20

    private static func networkGuest() throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/pc-noyau-reseau.bin"))
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

    /// **Un pair qui répond** : il garde ce que l'invité envoie, et ne lui
    /// rend sa trame — `mov $'R', %eax ; ret`, puis du remplissage — qu'après
    /// avoir reçu la sienne. Un aller, puis un retour.
    private final class Responder: NetworkBackend {
        private(set) var sent: [[UInt8]] = []
        private var answered = false
        static let reply: [UInt8] = [0xB8, 0x52, 0x00, 0x00, 0x00, 0xC3] + [UInt8](repeating: 0x5A, count: 54)

        func send(_ frame: [UInt8]) { sent.append(frame) }

        func receive() -> [[UInt8]] {
            guard !sent.isEmpty, !answered else { return [] }
            answered = true
            return [Self.reply]
        }
    }

    private func machine(_ console: Console) throws -> RustPCMachine {
        let machine = try XCTUnwrap(RustPCMachine(ramSize: Self.ram, onOutput: { console.append($0) }))
        machine.freezeHostTime(at: Date(timeIntervalSince1970: 1_795_230_600))
        return machine
    }

    /// La trame que le pilote minimal émet : diffusée, depuis l'adresse de la
    /// carte, de type 0x88B5, puis son texte.
    private static let guestFrame: [UInt8] =
        [UInt8](repeating: 0xFF, count: 6) + VirtioNet.defaultMAC + [0x88, 0xB5]
        + Array("wisq-reseau : une trame de l'invite vers l'hote".utf8)

    /// **Une trame sort, une trame entre**, par le backend, sans rien d'autre
    /// que `run` : la trame de l'invité arrive au pair telle qu'il l'a
    /// émise, la réponse du pair arrive à l'invité, qui l'exécute.
    func testFramesPassBothWaysThroughTheBackend() throws {
        let console = Console()
        let machine = try machine(console)
        XCTAssertNil(machine.networkCounts, "pas de carte, pas de compteurs")
        let responder = Responder()
        try machine.attachNetwork(responder)
        XCTAssertThrowsError(try machine.attachNetwork(responder)) {
            XCTAssertEqual($0 as? RustPCMachine.Refusal, .networkAlreadyAttached)
        }
        try machine.load(kernelImage: Self.networkGuest(), commandLine: nil, initialRamdisk: nil)
        XCTAssertThrowsError(try machine.attachNetwork(UserNetwork.isolated())) {
            XCTAssertEqual($0 as? RustPCMachine.Refusal, .alreadyStarted)
        }
        XCTAssertEqual(machine.run(instructionBudget: 20_000_000), .powerOff)
        XCTAssertEqual(console.text, "oR", "« R » : la réponse du pair, exécutée par l'invité")
        XCTAssertEqual(responder.sent, [Self.guestFrame])
        let counts = try XCTUnwrap(machine.networkCounts)
        XCTAssertEqual(counts.transmitted, 1)
        XCTAssertEqual(counts.delivered, 1)
        XCTAssertEqual(counts.dropped, 0)
        XCTAssertEqual(counts.refused, 0)
    }

    /// **Un pair qui compte ses questions** (`Counting` des tests du cœur
    /// Swift).
    private final class Counting: NetworkBackend {
        private(set) var questions = 0
        func send(_ frame: [UInt8]) {}
        func receive() -> [[UInt8]] {
            questions += 1
            return []
        }
    }

    /// **Le rythme de `X86Machine`** : avec une carte, `run` pompe toutes les
    /// deux cent mille instructions de l'invité, la tranche du cœur Swift —
    /// une trame attend au plus une tranche de chaque côté. Un invité qui
    /// tourne sans fin (`cli ; jmp .`), un million d'instructions : cinq
    /// questions au pair.
    func testTheBackendIsAskedAtEachSliceOfTheSwiftCore() throws {
        var kernel = try Data(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/pc-noyau-factice.bin"))
        kernel.replaceSubrange(0x600..<0x603, with: [0xFA, 0xEB, 0xFE])
        let machine = try machine(Console())
        let counting = Counting()
        try machine.attachNetwork(counting)
        try machine.load(kernelImage: kernel, commandLine: nil, initialRamdisk: nil)
        XCTAssertEqual(machine.run(instructionBudget: 1_000_000), .stopped)
        XCTAssertEqual(counting.questions, 5)
    }

    /// **Sans carte, rien ne passe** : la machine n'a pas de réseau, et une
    /// pompe n'y fait rien.
    func testWithoutACardNothingIsPumped() throws {
        let machine = try machine(Console())
        XCTAssertEqual(machine.pumpNetwork().sent, 0)
        XCTAssertNil(machine.networkBackend)
        XCTAssertNil(try machine.forward(toGuestPort: 5900), "pas de réseau, pas de relais")
    }

    /// **Le réglage qui coupe le réseau d'une machine est respecté** : la
    /// même règle que pour le cœur Swift (`MachineNetwork.backend`) — coupé,
    /// la passerelle refuse le dehors ; pas coupé, il sort par l'hôte.
    func testTheSettingThatCutsTheNetworkIsKept() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wisq-rust-reseau-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        MachineNetwork.setCut(true, forKernel: "coupee", in: directory)

        let cut = try machine(Console())
        try cut.attachNetwork(forKernel: "coupee", in: directory)
        let isolated = try XCTUnwrap(cut.networkBackend as? UserNetwork)
        XCTAssertTrue(isolated.refusesOutside, "coupé : rien ne sort")
        XCTAssertNil(isolated.relay)
        defer { isolated.streams?.close() }

        let open = try machine(Console())
        try open.attachNetwork(forKernel: "ouverte", in: directory)
        let host = try XCTUnwrap(open.networkBackend as? UserNetwork)
        XCTAssertFalse(host.refusesOutside, "pas coupé : l'hôte")
        XCTAssertNotNil(host.relay)
        host.streams?.close()
        (host.relay as? HostDatagrams)?.close()
    }

    /// **Le port du bureau** : `forward` écoute sur la boucle locale, et une
    /// connexion de l'hôte devient un SYN vers le port 5900 de l'invité,
    /// remis à la machine par la pompe — le chemin du VNC d'un bureau.
    func testTheDesktopPortReachesTheGuestThroughTheUserNetwork() throws {
        let machine = try machine(Console())
        let network = UserNetwork.isolated()
        defer { network.streams?.close() }
        try machine.attachNetwork(network)
        let port = try XCTUnwrap(try machine.forward(toGuestPort: 5900))
        XCTAssertNotEqual(port, 0)

        let client = socket(AF_INET, HostStreams.streamType, 0)
        XCTAssertGreaterThanOrEqual(client, 0)
        defer { _ = closeSocket(client) }
        var address = HostDatagrams.socketAddress([127, 0, 0, 1], port: port)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(client, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(connected, 0, "le port relayé écoute")

        var given = 0
        let deadline = Date().addingTimeInterval(5)
        while given == 0, Date() < deadline {
            given += machine.pumpNetwork().given
            if given == 0 { usleep(10_000) }
        }
        XCTAssertEqual(given, 1, "le SYN vers l'invité est remis à la machine")
        let counts = try XCTUnwrap(machine.networkCounts)
        XCTAssertEqual(counts.incoming, 1, "il attend que la carte le prenne")
    }

    /// **Un serveur de l'hôte, une seule réponse** : sur la boucle locale, un
    /// port libre ; il accepte une connexion, lit la requête, répond `body`
    /// en HTTP/1.0 et ferme. Rend le port.
    private static func serveOnce(_ body: String) throws -> UInt16 {
        let listener = socket(AF_INET, HostStreams.streamType, 0)
        guard listener >= 0 else { throw POSIXError(.EMFILE) }
        var address = HostDatagrams.socketAddress([127, 0, 0, 1], port: 0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer -> Int32 in
                guard bind(listener, pointer, length) == 0, listen(listener, 1) == 0 else { return -1 }
                return getsockname(listener, pointer, &length)
            }
        }
        guard bound == 0 else { throw POSIXError(.EADDRINUSE) }
        let response = Array("HTTP/1.0 200 OK\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)".utf8)
        Thread.detachNewThread {
            defer { _ = closeSocket(listener) }
            let client = accept(listener, nil, nil)
            guard client >= 0 else { return }
            defer { _ = closeSocket(client) }
            var request = [UInt8](repeating: 0, count: 4096)
            _ = recv(client, &request, request.count, 0)
            _ = response.withUnsafeBytes { send(client, $0.baseAddress, $0.count, 0) }
        }
        return UInt16(bigEndian: address.sin_port)
    }

    /// **Alpine obtient son bail DHCP sur le cœur Rust, puis parle TCP à
    /// l'hôte**, par `UserNetwork` : `WISQ_PC_KERNEL` et `WISQ_PC_INITRD` (le
    /// noyau et l'initramfs du netboot d'Alpine 6.18.60, ceux du banc
    /// commun), `ip=dhcp` sur la ligne de commande — l'initramfs charge
    /// `virtio_net`, lève `eth0` et lance `udhcpc`. Le bail est servi par la
    /// passerelle de wisq. Puis, au shell de secours, `wget` vers `10.0.2.2`,
    /// c'est-à-dire la boucle locale de l'hôte, où un serveur de ce test
    /// répond : la réponse doit revenir sur la console. Se tait bruyamment
    /// sans noyau.
    func testAlpineGetsItsLeaseAndTalksTCPToTheHost() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["WISQ_PC_KERNEL"], let initrd = environment["WISQ_PC_INITRD"] else {
            print("noyau PC absent : définir WISQ_PC_KERNEL et WISQ_PC_INITRD pour ce test")
            return
        }
        let console = Console()
        let machine = try XCTUnwrap(RustPCMachine(ramSize: 512 << 20, onOutput: { console.append($0) }))
        machine.freezeHostTime(at: Date(timeIntervalSince1970: 1_795_230_600))
        // Le TCP de l'invité vers l'hôte, et rien d'autre : ni UDP, ni ping.
        let network = UserNetwork(streams: HostStreams())
        defer { network.streams?.close() }
        try machine.attachNetwork(network)
        try machine.load(kernelImage: Data(contentsOf: URL(fileURLWithPath: path)),
                         commandLine: "console=ttyS0 ip=dhcp",
                         initialRamdisk: Data(contentsOf: URL(fileURLWithPath: initrd)))
        let start = Date()
        var outcome = RustPCMachine.Outcome.stopped
        func run(until text: String, within limit: UInt64) {
            while outcome == .stopped, !console.text.contains(text), machine.retiredInstructions < limit {
                outcome = machine.run(instructionBudget: 20_000_000)
            }
        }
        let lease = "lease of 10.0.2.15 obtained"
        run(until: lease, within: 8_000_000_000)
        let leased = (machine.retiredInstructions, Date().timeIntervalSince(start))
        XCTAssertTrue(console.text.contains(lease), "« \(lease) » jamais vu ; fin : \(outcome)\n"
                      + String(console.text.suffix(3000)))
        for line in console.text.split(separator: "\n") where line.contains("DHCP") || line.contains("udhcpc") {
            print(line)
        }
        run(until: "~ # ", within: leased.0 + 4_000_000_000)
        let body = "wisq-hote : bonjour l'invite"
        let port = try Self.serveOnce(body + "\n")
        machine.send(Data("wget -q -O - http://10.0.2.2:\(port)/\n".utf8))
        let asked = (machine.retiredInstructions, Date().timeIntervalSince(start))
        // La réponse, et pas l'écho de la commande : elle seule a son texte.
        run(until: body, within: asked.0 + 4_000_000_000)
        let answered = (machine.retiredInstructions, Date().timeIntervalSince(start))
        let counts = machine.networkCounts
        print("bail : \(leased.0) instructions, \(String(format: "%.1f", leased.1)) s ; "
              + "wget demandé à \(asked.0), \(String(format: "%.1f", asked.1)) s ; "
              + "réponse à \(answered.0), \(String(format: "%.1f", answered.1)) s ; "
              + "trames émises \(counts?.transmitted ?? 0), livrées \(counts?.delivered ?? 0), "
              + "perdues \(counts?.dropped ?? 0)")
        XCTAssertTrue(console.text.contains(body), "la réponse de l'hôte jamais vue ; fin : \(outcome)\n"
                      + String(console.text.suffix(3000)))
    }
}
