import XCTest
@testable import WisqNet

final class ResumeOnceTests: XCTestCase {
    func testClaimSucceedsExactlyOnce() {
        let once = ResumeOnce()
        XCTAssertTrue(once.claim())
        XCTAssertFalse(once.claim())
        XCTAssertFalse(once.claim())
    }

    /// The case that matters: many threads racing, exactly one winner. A
    /// captured-var flag passes the sequential test above and fails this one.
    func testOnlyOneOfManyConcurrentClaimantsWins() {
        for _ in 0..<200 {
            let once = ResumeOnce()
            let winners = Counter()
            DispatchQueue.concurrentPerform(iterations: 32) { _ in
                if once.claim() { winners.increment() }
            }
            XCTAssertEqual(winners.value, 1, "une continuation reprise deux fois plante le processus")
        }
    }

    private final class Counter: @unchecked Sendable {
        private var count = 0
        private let lock = NSLock()
        func increment() { lock.lock(); count += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    }
}
