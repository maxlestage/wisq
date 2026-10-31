import XCTest
@testable import WisqVM

/// Une machine qui redémarre repart d'elle-même, mais pas en boucle : voir
/// `AutomaticRestart`.
final class AutomaticRestartTests: XCTestCase {
    let start = Date(timeIntervalSince1970: 2_000_000_000)

    /// **Trois d'affilée, pas quatre** : un noyau qui panique et redémarre
    /// toutes les dix secondes s'arrête au quatrième.
    func testThreeRestartsThenTheMachineStops() {
        var restarts = AutomaticRestart()
        for step in 0..<3 {
            XCTAssertTrue(restarts.shouldRestart(at: start.addingTimeInterval(Double(step) * 10)), "redémarrage \(step + 1)")
        }
        XCTAssertFalse(restarts.shouldRestart(at: start.addingTimeInterval(30)), "le quatrième en deux minutes")
        XCTAssertFalse(restarts.shouldRestart(at: start.addingTimeInterval(40)), "et les suivants")
    }

    /// **Un redémarrage de temps en temps repart toujours** : la fenêtre
    /// glisse, et ce qui en est sorti ne compte plus.
    func testRestartsSpreadOutAlwaysGoThrough() {
        var restarts = AutomaticRestart()
        for step in 0..<10 {
            XCTAssertTrue(restarts.shouldRestart(at: start.addingTimeInterval(Double(step) * 60)), "toutes les minutes, le \(step + 1)e")
        }
        XCTAssertLessThanOrEqual(restarts.recent.count, AutomaticRestart.limit)
    }

    /// Arrêtée pour boucle, la machine repart une fois la fenêtre passée.
    func testTheWindowForgets() {
        var restarts = AutomaticRestart()
        for step in 0..<3 { _ = restarts.shouldRestart(at: start.addingTimeInterval(Double(step))) }
        XCTAssertFalse(restarts.shouldRestart(at: start.addingTimeInterval(10)))
        XCTAssertTrue(restarts.shouldRestart(at: start.addingTimeInterval(AutomaticRestart.window + 3)))
    }

    /// **L'heure du téléphone qui recule** n'arrête pas une machine : ce qui
    /// est daté du futur ne compte plus.
    func testAClockGoingBackDoesNotStopTheMachine() {
        var restarts = AutomaticRestart()
        for step in 0..<3 { _ = restarts.shouldRestart(at: start.addingTimeInterval(Double(step))) }
        XCTAssertTrue(restarts.shouldRestart(at: start.addingTimeInterval(-3600)))
        XCTAssertEqual(restarts.recent.count, 1)
    }
}
