import XCTest
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
@testable import WisqVM

/// Couper le réseau d'une machine : voir `MachineNetwork` et
/// `UserNetwork.isolated()`.
final class MachineNetworkTests: XCTestCase {
    typealias Flag = HostStreams.Flag
    private var folder: URL!

    override func setUpWithError() throws {
        folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wisq-reseau-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// **Le réglage, par machine** : rien de coupé tant qu'on n'y touche
    /// pas ; couper l'une ne coupe pas l'autre ; rendre le réseau à la
    /// dernière efface le fichier.
    func testTheSettingBelongsToOneMachine() {
        XCTAssertFalse(MachineNetwork.isCut(forKernel: "alpine", in: folder))
        MachineNetwork.setCut(true, forKernel: "alpine", in: folder)
        MachineNetwork.setCut(true, forKernel: "alpine", in: folder)
        MachineNetwork.setCut(true, forKernel: "debian", in: folder)
        XCTAssertTrue(MachineNetwork.isCut(forKernel: "alpine", in: folder))
        XCTAssertFalse(MachineNetwork.isCut(forKernel: "ubuntu", in: folder))
        let file = folder.appendingPathComponent(MachineNetwork.fileName)
        MachineNetwork.setCut(false, forKernel: "alpine", in: folder)
        XCTAssertFalse(MachineNetwork.isCut(forKernel: "alpine", in: folder))
        XCTAssertTrue(MachineNetwork.isCut(forKernel: "debian", in: folder))
        MachineNetwork.forget(kernel: "debian", in: folder)
        XCTAssertFalse(MachineNetwork.isCut(forKernel: "debian", in: folder))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "plus rien de coupé, plus de fichier")
    }

    /// Un fichier abîmé se lit « rien de coupé » : le réseau, comme avant le
    /// réglage.
    func testABrokenFileCutsNothing() throws {
        try Data("{pas du json".utf8).write(to: folder.appendingPathComponent(MachineNetwork.fileName))
        XCTAssertFalse(MachineNetwork.isCut(forKernel: "alpine", in: folder))
        XCTAssertNotNil(MachineNetwork.backend(forKernel: "alpine", in: folder).relay)
    }

    /// **Le câble que reçoit la machine** : le dehors, ou rien que le TCP
    /// qui entre.
    func testTheBackendFollowsTheSetting() {
        let open = MachineNetwork.backend(forKernel: "alpine", in: folder)
        defer { open.streams?.close() }
        XCTAssertNotNil(open.relay)
        XCTAssertEqual(open.streams?.reachesOutside, true)

        MachineNetwork.setCut(true, forKernel: "alpine", in: folder)
        let cut = MachineNetwork.backend(forKernel: "alpine", in: folder)
        defer { cut.streams?.close() }
        XCTAssertNil(cut.relay, "ni UDP")
        XCTAssertNil(cut.echoes, "ni ping")
        XCTAssertEqual(cut.streams?.reachesOutside, false, "le TCP, pour les ports relayés seulement")
    }

    /// **Rien ne sort** : un serveur qui écoute, joignable par la
    /// passerelle, n'est jamais appelé, et l'invité reçoit tout de suite une
    /// remise à zéro au lieu d'attendre.
    func testACutMachineReachesNothing() throws {
        let called = Called()
        let server = try HostStreamsTests.Server { _ in called.mark() }
        let network = UserNetwork.isolated()
        let streams = try XCTUnwrap(network.streams)
        defer { streams.close() }
        network.send(HostStreamsTests.fromGuest(HostStreams.Segment(
            remote: UserNetwork.gateway, remotePort: server.port, guestPort: 40_100, sequence: 41,
            acknowledgment: 0, flags: Flag.syn, window: 1000, maximumSegment: 1460, payload: [])))
        let replies = streams.receive()
        XCTAssertEqual(replies.first?.flags, Flag.rst | Flag.ack, "refusé tout de suite")
        XCTAssertEqual(replies.first?.acknowledgment, 42)
        XCTAssertEqual(streams.openConnections, 0)
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertFalse(called.happened, "le serveur de l'hôte n'a vu personne")
        withExtendedLifetime(server) {}
    }

    /// **Le bureau reste** : le port relayé entre dans l'invité, réseau
    /// coupé ou non.
    func testTheDesktopStillReachesACutMachine() throws {
        let machine = X86Machine(ramSize: 16 << 20, onOutput: { _ in })
        let network = UserNetwork.isolated()
        defer { network.streams?.close() }
        machine.attach(network: VirtioNet(backend: network))
        let port = try XCTUnwrap(try machine.forward(toGuestPort: 5900))
        let client = try HostStreamsTests.connectClient(to: port)
        defer { _ = closeSocket(client) }
        let deadline = Date().addingTimeInterval(5)
        var syn: HostStreams.Segment?
        while syn == nil, Date() < deadline {
            syn = network.streams?.receive().first { $0.flags & Flag.syn != 0 }
            if syn == nil { Thread.sleep(forTimeInterval: 0.01) }
        }
        XCTAssertEqual(syn?.guestPort, 5900, "wisq ouvre vers le serveur VNC de l'invité")
    }

    /// **Couper ne coûte pas la session** : l'instantané d'une machine qui
    /// sortait se reprend sur une machine coupée, et inversement — la carte
    /// est la même, seul le câble change.
    func testASessionSurvivesTheChange() throws {
        let saved = X86Machine(ramSize: X86Machine.minimumRAMSize, onOutput: { _ in })
        saved.attach(network: VirtioNet(backend: UserNetwork()))
        let data = saved.snapshot()

        let cut = UserNetwork.isolated()
        defer { cut.streams?.close() }
        let resumed = X86Machine(ramSize: X86Machine.minimumRAMSize, onOutput: { _ in })
        resumed.attach(network: VirtioNet(backend: cut))
        try resumed.restore(data)
        XCTAssertTrue(resumed.network?.backend === cut)
        XCTAssertEqual(resumed.snapshot(), data)
    }
}

private final class Called: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func mark() { lock.lock(); value = true; lock.unlock() }
    var happened: Bool { lock.lock(); defer { lock.unlock() }; return value }
}
