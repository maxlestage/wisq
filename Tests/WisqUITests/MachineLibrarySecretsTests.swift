import Foundation
import WisqCore
import WisqUI
import XCTest

/// The bookkeeping of secrets around the machine list, driven through the real
/// view model.
///
/// `WisqUI` is not built on Linux, so `CredentialReaper`'s own rules are tested
/// in `WisqCoreTests` where they can be broken on purpose. What is checked here
/// is the half that only exists on the phone: that `MachineLibraryModel`
/// actually calls the reaper, on both of its mutating paths, and in an order
/// that cannot lose a password to a failed write.
final class MachineLibrarySecretsTests: XCTestCase {
    private var directory: URL!
    private let agentRef = "agent.nas.local:7442"

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wisq-lib-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeLibrary(
        _ credentials: CredentialStore
    ) -> MachineLibraryModel {
        MachineLibraryModel(
            store: MachineStore(fileURL: directory.appendingPathComponent("machines.json")),
            credentials: credentials
        )
    }

    private func vm(_ name: String) -> Machine {
        var machine = Machine(name: name, host: "nas.local")
        machine.agent = AgentBinding(
            baseURL: URL(string: "http://nas.local:7442")!,
            vmIdentifier: name,
            credentialRef: agentRef
        )
        return machine
    }

    func testDeletingTheLastVMOfAnAgentTakesItsTokenWithIt() throws {
        let credentials = EphemeralCredentialStore()
        let library = makeLibrary(credentials)
        try credentials.setSecret("jeton", for: agentRef)

        let only = vm("unique")
        library.save(only, password: "mdp")
        XCTAssertEqual(try credentials.secret(for: agentRef), "jeton")

        library.delete(library.machines[0])
        XCTAssertNil(library.loadError)
        XCTAssertNil(try credentials.secret(for: agentRef))
        XCTAssertNil(try credentials.secret(for: only.defaultCredentialRef))
    }

    func testDeletingOneVMLeavesTheOtherAbleToTalkToTheSameAgent() throws {
        let credentials = EphemeralCredentialStore()
        let library = makeLibrary(credentials)
        try credentials.setSecret("jeton", for: agentRef)

        library.save(vm("a"), password: nil)
        library.save(vm("b"), password: nil)
        XCTAssertEqual(library.machines.count, 2)

        library.delete(library.machines[0])
        XCTAssertEqual(
            try credentials.secret(for: agentRef), "jeton",
            "le jeton est partagé par toutes les VM de cet agent")
    }

    func testUnbindingAMachineFromItsAgentReleasesTheToken() throws {
        let credentials = EphemeralCredentialStore()
        let library = makeLibrary(credentials)
        try credentials.setSecret("jeton", for: agentRef)

        library.save(vm("a"), password: nil)
        var unbound = library.machines[0]
        unbound.agent = nil
        library.save(unbound, password: nil)

        XCTAssertNil(try credentials.secret(for: agentRef))
    }

    /// A save that could not be written says so, and leaves no token behind.
    ///
    /// The failure is injected with a path whose parent is a regular file
    /// rather than a read-only directory: the same rule is checked on Linux in
    /// `MachineLibraryWriterTests`, where the tests run as root and a `0500`
    /// directory stops nothing. One injection, valid for whoever runs it.
    func testASaveThatCannotBeWrittenReportsItAndStoresNoToken() throws {
        let credentials = EphemeralCredentialStore()
        let file = directory.appendingPathComponent("a-file")
        try Data("x".utf8).write(to: file)
        let library = MachineLibraryModel(
            store: MachineStore(fileURL: file.appendingPathComponent("machines.json")),
            credentials: credentials
        )

        XCTAssertFalse(library.save(vm("a"), password: "mdp", agentToken: "jeton"))
        XCTAssertNotNil(library.loadError)
        XCTAssertNil(try credentials.secret(for: agentRef))
    }

    /// The order the reaping happens in, checked by making the write fail: the
    /// machine list is read-only, so `delete` cannot succeed, and the password
    /// must still be there when the user looks again at a machine that is also
    /// still there.
    func testAFailedDeletionKeepsBothTheMachineAndItsPassword() throws {
        let credentials = EphemeralCredentialStore()
        let library = makeLibrary(credentials)
        library.save(Machine(name: "a", host: "nas.local"), password: "mdp")
        let saved = library.machines[0]
        XCTAssertEqual(library.password(for: saved), "mdp")

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
        // A read-only directory stops nobody when the tests run as root, and a
        // probe that cannot fail proves nothing. Ask before assuming.
        let canary = directory.appendingPathComponent("canary")
        if FileManager.default.createFile(atPath: canary.path, contents: Data()) {
            try? FileManager.default.removeItem(at: canary)
            throw XCTSkip("le répertoire reste inscriptible : rien à faire échouer")
        }
        // A fresh model so the store cannot answer the delete from its cache.
        let reopened = makeLibrary(credentials)
        reopened.delete(reopened.machines[0])

        XCTAssertNotNil(reopened.loadError)
        XCTAssertEqual(
            try credentials.secret(for: saved.defaultCredentialRef), "mdp",
            "une machine encore listée ne doit pas avoir perdu son mot de passe")
    }
}
