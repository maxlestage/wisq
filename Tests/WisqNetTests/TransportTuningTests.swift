import XCTest
@testable import WisqNet

/// The TCP settings a session asks for.
///
/// These used to be four literals inside a `#if canImport(Network)` file, which
/// on a Linux runner is not compiled, not run and not checked — a keepalive
/// interval of zero, or an idle wait longer than the NAT timeout it exists to
/// beat, would have looked exactly as green as the right numbers. They are a
/// value now, so this machine can read them.
///
/// What these tests hold is the *reasoning*, not the numbers: each one names a
/// bound the setting has to stay inside and why, so that changing a number is
/// allowed and breaking the property is not.
final class TransportTuningTests: XCTestCase {
    private let tuning = TransportTuning.interactive

    /// Nagle coalesces small writes, and a keystroke is the smallest write
    /// there is. The user notices the round trip; nobody notices the bytes.
    func testKeystrokesAreNotHeldBackToFillASegment() {
        XCTAssertTrue(tuning.noDelay)
    }

    /// A remote desktop is silent whenever the screen is, and carrier NAT drops
    /// idle mappings without telling either end. The probe has to start well
    /// inside the shortest timeout worth defending against — a few minutes on
    /// the mobile networks this is for — or the mapping is already gone when it
    /// fires and the keepalive was decoration.
    func testTheFirstProbeGoesOutBeforeACarrierWouldDropTheMapping() {
        XCTAssertTrue(tuning.keepaliveEnabled)
        XCTAssertGreaterThan(tuning.keepaliveIdle, 0)
        XCTAssertLessThanOrEqual(
            tuning.keepaliveIdle, 120,
            "la sonde part trop tard : le mappage NAT est déjà tombé"
        )
    }

    /// Zero would be a probe per tick and a battery complaint; the count has to
    /// be more than one, or a single dropped packet on a hiccuping link tears
    /// down a session that was about to recover.
    func testOneLostPacketDoesNotTearDownAWorkingSession() {
        XCTAssertGreaterThan(tuning.keepaliveInterval, 0)
        XCTAssertGreaterThan(
            tuning.keepaliveCount, 1,
            "une seule sonde perdue suffirait à couper"
        )
    }

    /// The number a person would recognise: how long the screen stays frozen
    /// before the app admits the connection is gone. Long enough to survive a
    /// lift or a tunnel, short enough that nobody sits staring at a dead
    /// picture wondering.
    func testADeadPeerIsNoticedInAWindowAPersonWouldAccept() {
        XCTAssertEqual(tuning.secondsUntilADeadPeerIsNoticed, 60 + 15 * 4)
        XCTAssertGreaterThanOrEqual(tuning.secondsUntilADeadPeerIsNoticed, 45)
        XCTAssertLessThanOrEqual(tuning.secondsUntilADeadPeerIsNoticed, 180)
    }

    /// Long enough for a slow cellular handshake, short enough that a host that
    /// has moved says so instead of leaving a spinner turning.
    func testConnectingGivesUpInTimeToSaySoRatherThanSpin() {
        XCTAssertGreaterThanOrEqual(tuning.connectionTimeout, 10)
        XCTAssertLessThanOrEqual(tuning.connectionTimeout, 30)
    }
}
