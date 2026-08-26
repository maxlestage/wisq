import XCTest
@testable import WisqCore

/// A store that can be told to refuse, so the "attempt every key" rule has
/// something to fail against.
private final class RefusingStore: CredentialStore, @unchecked Sendable {
    private let inner = EphemeralCredentialStore()
    var refusing: Set<String> = []
    private(set) var attempted: [String] = []

    func secret(for ref: String) throws -> String? { try inner.secret(for: ref) }

    func setSecret(_ secret: String?, for ref: String) throws {
        attempted.append(ref)
        if refusing.contains(ref) { throw WisqError.storageFailure("refus de test") }
        try inner.setSecret(secret, for: ref)
    }
}

final class CredentialReapingTests: XCTestCase {
    private let agentRef = "agent.nas.local:7442"

    private func boundMachine(_ name: String, token: String?) -> Machine {
        var machine = Machine(name: name, host: "nas.local")
        machine.credentialRef = machine.defaultCredentialRef
        machine.agent = AgentBinding(
            baseURL: URL(string: "http://nas.local:7442")!,
            vmIdentifier: name,
            credentialRef: token
        )
        return machine
    }

    func testAMachinesOwnPasswordIsOrphanedAsSoonAsItLeaves() {
        let machine = boundMachine("A", token: nil)
        let orphans = CredentialReaper.orphanedRefs(after: machine, remaining: [])
        XCTAssertEqual(orphans, [machine.defaultCredentialRef])
    }

    func testTheAgentTokenGoesWhenItsLastMachineGoes() {
        let machine = boundMachine("A", token: agentRef)
        let orphans = CredentialReaper.orphanedRefs(after: machine, remaining: [])
        XCTAssertTrue(orphans.contains(agentRef))
    }

    func testTheAgentTokenStaysWhileAnotherVMOnThatAgentRemains() {
        let a = boundMachine("A", token: agentRef)
        let b = boundMachine("B", token: agentRef)
        let orphans = CredentialReaper.orphanedRefs(after: a, remaining: [b])
        XCTAssertFalse(
            orphans.contains(agentRef),
            "supprimer une VM d'un agent déconnecterait ses voisines")
        XCTAssertEqual(orphans, [a.defaultCredentialRef])
    }

    func testTwoVMsLeavingOneAfterTheOtherEndUpFreeingTheToken() throws {
        let store = EphemeralCredentialStore()
        let a = boundMachine("A", token: agentRef)
        let b = boundMachine("B", token: agentRef)
        try store.setSecret("jeton", for: agentRef)
        try store.setSecret("mdp-a", for: a.defaultCredentialRef)
        try store.setSecret("mdp-b", for: b.defaultCredentialRef)

        try CredentialReaper.reap(after: a, remaining: [b], from: store)
        XCTAssertEqual(try store.secret(for: agentRef), "jeton")
        XCTAssertNil(try store.secret(for: a.defaultCredentialRef))
        XCTAssertEqual(try store.secret(for: b.defaultCredentialRef), "mdp-b")

        try CredentialReaper.reap(after: b, remaining: [], from: store)
        XCTAssertNil(try store.secret(for: agentRef))
        XCTAssertNil(try store.secret(for: b.defaultCredentialRef))
    }

    func testAMachineThatChangedAgentLosesOnlyTheTokenItLeftBehind() {
        let before = boundMachine("A", token: agentRef)
        var after = before
        after.agent?.credentialRef = "agent.autre.local:7442"
        let orphans = CredentialReaper.orphanedRefs(after: before, remaining: [after])
        XCTAssertEqual(orphans, [agentRef])
    }

    func testSavingAnUnchangedMachineOrphansNothing() {
        let machine = boundMachine("A", token: agentRef)
        XCTAssertTrue(CredentialReaper.orphanedRefs(after: machine, remaining: [machine]).isEmpty)
    }

    func testARefusedDeletionStillLetsTheOthersThrough() throws {
        let store = RefusingStore()
        let machine = boundMachine("A", token: agentRef)
        try store.setSecret("jeton", for: agentRef)
        try store.setSecret("mdp", for: machine.defaultCredentialRef)
        store.refusing = [agentRef]

        XCTAssertThrowsError(try CredentialReaper.reap(after: machine, remaining: [], from: store))
        XCTAssertNil(
            try store.secret(for: machine.defaultCredentialRef),
            "un refus sur une clé ne doit pas faire sauter les suivantes")
        XCTAssertEqual(try store.secret(for: agentRef), "jeton")
    }
}
