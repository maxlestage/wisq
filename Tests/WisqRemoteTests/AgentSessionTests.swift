import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import WisqRemote

/// One `URLSession` per pinned agent, not one per request: see
/// `AgentClient.pinnedSession(for:)`.
final class AgentSessionTests: XCTestCase {
    func testTheSameFingerprintSharesOneSession() {
        let fingerprint = Data(repeating: 0xA5, count: 32)
        let first = AgentClient.pinnedSession(for: fingerprint)
        let second = AgentClient.pinnedSession(for: Data(repeating: 0xA5, count: 32))
        XCTAssertTrue(first === second, "a second client for the same agent reuses the session")
    }

    func testAnotherFingerprintGetsItsOwnSession() {
        let first = AgentClient.pinnedSession(for: Data(repeating: 0x01, count: 32))
        let second = AgentClient.pinnedSession(for: Data(repeating: 0x02, count: 32))
        XCTAssertFalse(first === second, "a session never answers for another certificate")
        XCTAssertFalse(first === URLSession.shared, "a pinned session is never the system's")
    }
}
