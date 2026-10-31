import XCTest

@testable import WisqVM

/// **Trente mises à jour de la console par seconde au plus**, et une frappe
/// isolée sans attente : voir `ConsolePacer`.
final class ConsolePacerTests: XCTestCase {
    static let millisecond: UInt64 = 1_000_000

    /// La première mise à jour, et celle qui suit une longue pause, partent
    /// tout de suite : l'écho d'une frappe n'attend rien.
    func testAnIsolatedRefreshDoesNotWait() {
        var pacer = ConsolePacer()
        XCTAssertEqual(pacer.delay(at: 5 * Self.millisecond), 0, "rien n'a encore été repeint")
        pacer.refreshed(at: 5 * Self.millisecond)
        XCTAssertEqual(pacer.delay(at: 500 * Self.millisecond), 0, "la précédente est loin")
        XCTAssertEqual(pacer.delay(at: 5 * Self.millisecond + ConsolePacer.interval), 0,
                       "un intervalle pile suffit")
    }

    /// **Pendant un flot**, la mise à jour suivante attend la fin de
    /// l'intervalle, et pas un instant de plus.
    func testARefreshDuringAFloodWaitsForTheRestOfTheInterval() {
        var pacer = ConsolePacer()
        pacer.refreshed(at: 100 * Self.millisecond)
        XCTAssertEqual(pacer.delay(at: 100 * Self.millisecond), ConsolePacer.interval)
        XCTAssertEqual(pacer.delay(at: 110 * Self.millisecond), ConsolePacer.interval - 10 * Self.millisecond)
        XCTAssertEqual(pacer.delay(at: 100 * Self.millisecond + ConsolePacer.interval - 1), 1)
    }

    /// Trente fois par seconde, comme l'écran.
    func testTheIntervalIsAThirtiethOfASecond() {
        XCTAssertEqual(Double(ConsolePacer.interval) / 1e9, 1.0 / 30, accuracy: 1e-6)
    }

    /// Une horloge qui recule — un instant lu avant la dernière mise à jour,
    /// sur un autre fil — n'attend pas une éternité.
    func testAClockThatGoesBackDoesNotWait() {
        var pacer = ConsolePacer()
        pacer.refreshed(at: 100 * Self.millisecond)
        XCTAssertEqual(pacer.delay(at: 90 * Self.millisecond), 0)
    }
}
