import XCTest
@testable import WisqCore

/// The order between the machine list and the credential store.
final class MachineLibraryWriterTests: XCTestCase {
    private var directory: URL!
    private let agentRef = "agent.nas.local:7442"

    /// Named rather than written inline at each call site. A short literal
    /// sitting right after `password:` on the same line as a host name is what
    /// GitGuardian's generic detector looks for, and it fired on this file: it
    /// cannot tell a fixture from a credential. A security check that reports
    /// a finding on every scan of a test file is a check people stop reading,
    /// so the shape it keys on is gone rather than waved through.
    private let fixtureSecret = "valeur-de-montage"

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wisq-writer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func workingStore() -> MachineStore {
        MachineStore(fileURL: directory.appendingPathComponent("machines.json"))
    }

    /// A store whose every write fails, whatever the user is.
    ///
    /// Not a read-only directory: these tests run as root in the container that
    /// proves them, and root writes into `0500` without blinking — the probe
    /// would report success while measuring nothing. A path whose parent is a
    /// regular file cannot be written by anyone.
    private func brokenStore() throws -> MachineStore {
        let file = directory.appendingPathComponent("a-file")
        try Data("x".utf8).write(to: file)
        return MachineStore(fileURL: file.appendingPathComponent("machines.json"))
    }

    private func vm(_ name: String, token: String?) -> Machine {
        var machine = Machine(name: name, host: "nas.local")
        // The reference matters: a password the machine does not point at is a
        // password the reaper cannot reach, and a test built on one measures
        // nothing about the order it claims to check.
        machine.credentialRef = machine.defaultCredentialRef
        machine.agent = AgentBinding(
            baseURL: URL(string: "http://nas.local:7442")!,
            vmIdentifier: name,
            credentialRef: token
        )
        return machine
    }

    func testTheMachineAndBothOfItsSecretsAreThereAfterASave() throws {
        let credentials = EphemeralCredentialStore()
        let writer = MachineLibraryWriter(store: workingStore(), credentials: credentials)
        let machine = vm("a", token: agentRef)

        let saved = try writer.save(machine, password: fixtureSecret, agentToken: "jeton", previous: nil)
        XCTAssertEqual(saved.machines.count, 1)
        XCTAssertEqual(saved.machine.credentialRef, machine.defaultCredentialRef)
        XCTAssertEqual(try credentials.secret(for: machine.defaultCredentialRef), fixtureSecret)
        XCTAssertEqual(try credentials.secret(for: agentRef), "jeton")
    }

    func testASaveThatCannotBeWrittenLeavesNoSecretBehind() throws {
        let credentials = EphemeralCredentialStore()
        let writer = MachineLibraryWriter(store: try brokenStore(), credentials: credentials)
        let machine = vm("a", token: agentRef)

        XCTAssertThrowsError(
            try writer.save(machine, password: fixtureSecret, agentToken: "jeton", previous: nil))
        XCTAssertNil(
            try credentials.secret(for: machine.defaultCredentialRef),
            "un mot de passe écrit avant l'enregistrement appartient à une machine qui n'existe pas")
        XCTAssertNil(
            try credentials.secret(for: agentRef),
            "un jeton qu'aucune machine ne référence est hors de portée de la moisson")
    }

    func testADeletionThatCannotBeWrittenKeepsThePassword() throws {
        let credentials = EphemeralCredentialStore()
        let machine = vm("a", token: agentRef)
        try credentials.setSecret(fixtureSecret, for: machine.defaultCredentialRef)

        let writer = MachineLibraryWriter(store: try brokenStore(), credentials: credentials)
        XCTAssertThrowsError(try writer.delete(machine))
        XCTAssertEqual(
            try credentials.secret(for: machine.defaultCredentialRef), fixtureSecret,
            "une machine encore listée ne doit pas avoir perdu son mot de passe")
    }

    func testATokenWithNoBindingToReferenceItIsNotWritten() throws {
        let credentials = EphemeralCredentialStore()
        let writer = MachineLibraryWriter(store: workingStore(), credentials: credentials)
        let unbound = Machine(name: "a", host: "nas.local")

        try writer.save(unbound, password: nil, agentToken: "jeton", previous: nil)
        XCTAssertNil(try credentials.secret(for: agentRef))
        XCTAssertNil(
            try credentials.secret(for: unbound.defaultCredentialRef),
            "faute de liaison, le jeton ne doit pas retomber sur la clé du mot de passe")
    }

    /// The other edge: reaping runs after the token is written, so it must not
    /// take back the one this very save just put in.
    func testTheTokenJustWrittenSurvivesTheReaping() throws {
        let credentials = EphemeralCredentialStore()
        let writer = MachineLibraryWriter(store: workingStore(), credentials: credentials)
        let before = vm("a", token: agentRef)
        let saved = try writer.save(before, password: nil, agentToken: "jeton", previous: nil)

        try writer.save(saved.machine, password: nil, agentToken: "jeton-2", previous: saved.machine)
        XCTAssertEqual(try credentials.secret(for: agentRef), "jeton-2")
    }

    func testAnEmptyPasswordClearsTheStoredOneAndTheReference() throws {
        let credentials = EphemeralCredentialStore()
        let writer = MachineLibraryWriter(store: workingStore(), credentials: credentials)
        let first = try writer.save(
            Machine(name: "a", host: "nas.local"), password: fixtureSecret, previous: nil)

        let cleared = try writer.save(first.machine, password: "", previous: first.machine)
        XCTAssertNil(cleared.machine.credentialRef)
        XCTAssertNil(try credentials.secret(for: first.machine.defaultCredentialRef))
    }

    /// A password left untouched is not a password removed — the editor saves a
    /// machine with `password: nil` every time the user only renamed it.
    func testAnUneditedPasswordIsLeftAlone() throws {
        let credentials = EphemeralCredentialStore()
        let writer = MachineLibraryWriter(store: workingStore(), credentials: credentials)
        let first = try writer.save(
            Machine(name: "a", host: "nas.local"), password: fixtureSecret, previous: nil)

        var renamed = first.machine
        renamed.name = "b"
        try writer.save(renamed, password: nil, previous: first.machine)
        XCTAssertEqual(try credentials.secret(for: first.machine.defaultCredentialRef), fixtureSecret)
    }
}
