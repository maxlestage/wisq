import Foundation
import XCTest
@testable import WisqVM

/// **Ce que devient une machine quand l'application part en arrière-plan** :
/// elle continue quand le réglage le veut, qu'elle tourne et que le
/// garde-en-vie a pris ; sinon elle est mise de côté comme avant.
final class BackgroundRunTests: XCTestCase {
    func testTheMachineKeepsRunningOnlyWhenEverythingAgrees() {
        XCTAssertEqual(BackgroundRun.whenLeaving(enabled: true, machineRunning: true, keepAlive: { true }), .keepRunning)
        XCTAssertEqual(BackgroundRun.whenLeaving(enabled: true, machineRunning: true, keepAlive: { false }), .setAside,
                       "iOS a refusé la session audio : la machine est mise de côté, rien n'est perdu")
        var asked = 0
        let never = { asked += 1; return true }
        XCTAssertEqual(BackgroundRun.whenLeaving(enabled: false, machineRunning: true, keepAlive: never), .setAside)
        XCTAssertEqual(BackgroundRun.whenLeaving(enabled: true, machineRunning: false, keepAlive: never), .setAside)
        XCTAssertEqual(asked, 0, "pas de session audio ouverte pour rien")
    }

    func testTheSettingIsOnByDefaultAndCanBeTurnedOff() {
        let fresh = UserDefaults(suiteName: "wisq-arriere-plan-\(UUID().uuidString)")!
        XCTAssertTrue(BackgroundRun.isEnabled(in: fresh))
        fresh.set(false, forKey: BackgroundRun.key)
        XCTAssertFalse(BackgroundRun.isEnabled(in: fresh))
        XCTAssertGreaterThan(BackgroundRun.restShare, 0.2, "le cœur tenu reste sous 80 %")
        XCTAssertLessThan(BackgroundRun.restShare, CheckpointedRun.maximumRestShare)
    }
}
