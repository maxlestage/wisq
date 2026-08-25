import XCTest
@testable import WisqRemote
@testable import WisqCore

/// Which session events are worth a haptic.
///
/// The rules live in `WisqRemote` rather than in the view precisely so that
/// they can be tested: `WisqUI` is not built on Linux, so a decision made there
/// is a decision no runner here can reach.
final class SessionHapticTests: XCTestCase {
    /// The one event that earns a tap. Connecting is a wait with nothing to
    /// watch, often with the phone in a pocket.
    func testTheDesktopArrivingIsWorthATap() {
        XCTAssertEqual(
            SessionEvent.ready(desktopName: "debian", width: 800, height: 600).haptic,
            .success
        )
    }

    /// **Only the first attempt.** A dropped link retries for as long as the app
    /// is open, and a haptic per attempt is a phone buzzing every few seconds in
    /// someone's pocket. The news is "the connection dropped", and that is true
    /// once.
    func testOnlyTheFirstReconnectionAttemptBuzzes() {
        XCTAssertEqual(SessionEvent.reconnecting(attempt: 1).haptic, .warning)
        for attempt in 2...50 {
            XCTAssertNil(
                SessionEvent.reconnecting(attempt: attempt).haptic,
                "tentative \(attempt) : le téléphone vibrerait en boucle"
            )
        }
    }

    /// Hanging up is not a failure. The user closed the session; telling them
    /// again with the platform's error pattern reads as "something went wrong".
    func testHangingUpIsNotReportedAsAFailure() {
        XCTAssertNil(SessionEvent.disconnected(nil).haptic)
        XCTAssertEqual(
            SessionEvent.disconnected(.connectionFailed("hôte injoignable")).haptic, .error
        )
    }

    /// The rule is an allow-list, and this is why.
    ///
    /// `.framebufferChanged` arrives tens of times a second for the whole
    /// session. One slip in the other direction — a `default` that returned a
    /// haptic — and the phone becomes a buzzer until the battery gives out.
    func testTheEventsThatArriveConstantlyAreSilent() {
        let constant: [SessionEvent] = [
            .framebufferChanged([Rect(x: 0, y: 0, width: 8, height: 8)]),
            .framebufferChanged([]),
            .cursor(RemoteCursor(width: 0, height: 0, hotspotX: 0, hotspotY: 0, bgra: [])),
            .resized(width: 1024, height: 768),
            .clipboard("du texte"),
            .bell,
            .connecting,
            .authenticating,
        ]
        for event in constant {
            XCTAssertNil(event.haptic, "\(event) ne doit rien déclencher")
        }
    }
}
