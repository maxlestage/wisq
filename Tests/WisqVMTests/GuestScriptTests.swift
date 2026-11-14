import Foundation
import XCTest
@testable import WisqVM

/// **Le pilote du bureau prêt**, contre une fausse machine : celui que
/// `wisq-fabrique` et le banc du bureau partagent (`GuestScript`).
///
/// Un vrai bureau met une demi-heure à venir ; ces cas-ci tiennent en
/// millisecondes ce qui décide d'une fabrication — une marque trouvée, une
/// attente qui rend la main, une marque coupée, une réponse d'avant la
/// frappe qui ne compte pas.
final class GuestScriptTests: XCTestCase {
    /// Une machine qui écrit ce qu'on lui a dit, au tour dit, et répète ce
    /// qu'on lui tape, comme une console.
    final class FakeMachine: ScriptableMachine {
        let console: GuestConsole
        /// Ce que la console reçoit à la n-ième tranche (comptée depuis 1).
        var outputs: [Int: String] = [:]
        /// Ce que la machine répond tout de suite à une frappe.
        var replies: [String: String] = [:]
        /// La tranche où l'invité finit, s'il finit.
        var endsAt: Int?
        /// La tranche où l'écran s'allume.
        var litAt: Int?
        private(set) var advances = 0
        private(set) var typed: [String] = []
        /// Les doigts posés : à quelle tranche, et où.
        private(set) var nudges: [Int: Double] = [:]
        var pixels = [UInt8](repeating: 0, count: 64)

        init(console: GuestConsole) { self.console = console }

        func advance(_ instructions: UInt64) -> String? {
            advances += 1
            if let text = outputs[advances] { console.append(Data(text.utf8)) }
            if advances == litAt { pixels = [UInt8](repeating: 0xFF, count: 64) }
            return advances == endsAt ? "l'invité s'est éteint" : nil
        }

        func send(_ data: Data) {
            let text = String(decoding: data, as: UTF8.self)
            typed.append(text)
            console.append(data)
            if let reply = replies[text] { console.append(Data(reply.utf8)) }
        }

        func nudge(x: Double, y: Double) { nudges[advances] = x }

        var screenPixels: [UInt8]? { pixels }
    }

    static let slice: UInt64 = 1000

    func make() -> (FakeMachine, GuestScript) {
        let console = GuestConsole()
        let machine = FakeMachine(console: console)
        return (machine, GuestScript(machine: machine, console: console, slice: Self.slice))
    }

    /// Une marque qui vient est trouvée à la tranche où elle vient, pas après.
    func testAMarkerThatComesIsFound() throws {
        let (machine, script) = make()
        machine.outputs[3] = "void-live login: "
        try script.expect("login:", budget: 10 * Self.slice)
        XCTAssertEqual(machine.advances, 3)
    }

    /// **Un budget épuisé rend la main**, en disant quoi : exactement le
    /// nombre de tranches que le budget permet, pas une de plus.
    func testASpentBudgetGivesUp() {
        let (machine, script) = make()
        XCTAssertThrowsError(try script.expect("login:", budget: 5 * Self.slice)) { error in
            XCTAssertEqual(error as? GuestScript.Failure, .markerNeverCame("login:", budget: 5 * Self.slice))
        }
        XCTAssertEqual(machine.advances, 5)
    }

    /// **Une marque coupée entre deux écritures** de la machine est une
    /// marque : la console série arrive par morceaux.
    func testAMarkerCutBetweenTwoWritesIsFound() throws {
        let (machine, script) = make()
        machine.outputs[1] = "BURE"
        machine.outputs[2] = "AU_2\r\n"
        try script.expect("BUREAU_2", budget: 10 * Self.slice)
        XCTAssertEqual(machine.advances, 2)
    }

    /// **Ce qui précède la frappe ne compte pas** : une marque déjà écrite
    /// par une commande d'avant ne doit pas faire croire que la nouvelle a
    /// répondu.
    func testWhatCameBeforeTheTypingDoesNotCount() throws {
        let (machine, script) = make()
        machine.outputs[1] = "PRET_2\r\n"
        try script.expect("PRET_2", budget: 10 * Self.slice)
        script.type("echo PRET_$((1+1))\n")
        machine.outputs[4] = "PRET_2\r\n"
        try script.expect("PRET_2", budget: 10 * Self.slice)
        XCTAssertEqual(machine.advances, 4, "la réponse d'avant a été prise pour la nouvelle")
    }

    /// Un invité qui finit en route arrête le déroulé : plus rien ne viendra,
    /// et attendre le reste du budget serait une demi-heure pour rien.
    func testAGuestThatEndsStopsTheScript() {
        let (machine, script) = make()
        machine.endsAt = 2
        XCTAssertThrowsError(try script.expect("login:", budget: 100 * Self.slice)) { error in
            XCTAssertEqual(error as? GuestScript.Failure, .guestEnded("l'invité s'est éteint"))
        }
        XCTAssertEqual(machine.advances, 2)
    }

    /// L'écran attendu jusqu'à ce qu'il soit allumé ; un écran qui reste
    /// noir rend la main, en le disant.
    func testTheScreenIsWaitedFor() throws {
        let (machine, script) = make()
        machine.litAt = 4
        try script.waitUntilLit(budget: 10 * Self.slice)
        XCTAssertEqual(machine.advances, 4)

        let (dark, darkScript) = make()
        XCTAssertThrowsError(try darkScript.waitUntilLit(budget: 3 * Self.slice)) { error in
            XCTAssertEqual(error as? GuestScript.Failure, .screenStayedDark(budget: 3 * Self.slice))
        }
        XCTAssertEqual(dark.advances, 3)
    }

    /// **Le doigt** toutes les trente-quatre tranches, à deux endroits tour à
    /// tour : sans entrée, Xorg éteint l'écran au bout de dix minutes.
    func testTheFingerMovesEveryFiveGuestSeconds() {
        let (machine, script) = make()
        XCTAssertThrowsError(try script.expect("jamais", budget: 70 * Self.slice))
        XCTAssertEqual(machine.nudges, [1: 0.25, 35: 0.5, 69: 0.25])
    }

    /// Un déroulé se lit dans l'ordre : chaque frappe attend l'invite d'avant.
    func testAScriptRunsInOrder() throws {
        let (machine, script) = make()
        machine.outputs[2] = "login: "
        machine.replies["root\n"] = "Password: "
        machine.replies["voidlinux\n"] = "[root@void-live ~]# "
        var said: [String] = []
        script.log = { said.append($0) }
        try script.run([.expect("login:"), .type("root\n"), .expect("Password:"),
                        .type("voidlinux\n"), .expect("# ")], budget: 10 * Self.slice)
        XCTAssertEqual(machine.typed, ["root\n", "voidlinux\n"])
        XCTAssertEqual(said.count, 5)
        XCTAssertEqual(said.first, "pas 1/5 : attendre « login: »")
    }

    /// La part allumée : un point est noir quand ses trois couleurs le sont,
    /// quel que soit son quatrième octet.
    func testTheLitFractionIgnoresTheFourthByte() {
        XCTAssertEqual(GuestScript.litFraction([0, 0, 0, 0xFF, 0, 0, 1, 0]), 0.5)
        XCTAssertEqual(GuestScript.litFraction([]), 0)
    }

    /// **La règle des marques**, tenue sur le déroulé du bureau : aucune
    /// frappe ne contient la marque qu'on attend après elle. Sinon la console,
    /// qui répète la ligne tapée, la montrerait tout de suite.
    func testNoTypedLineCarriesItsOwnMarker() {
        let steps = ReadyDesktopBuild.voidXfce
        for (index, step) in steps.enumerated() {
            guard case .type(let text) = step, index + 1 < steps.count,
                  case .expect(let marker) = steps[index + 1] else { continue }
            XCTAssertFalse(text.contains(marker), "« \(text) » contient « \(marker) »")
        }
    }

    /// **Le bureau prêt est préparé, puis regardé, avant d'être sauvé** : le
    /// cache vidé, et l'écran vérifié en dernier.
    func testTheDesktopIsPreparedThenLookedAtLast() throws {
        let steps = ReadyDesktopBuild.voidXfce
        let prepare = try XCTUnwrap(steps.firstIndex(of: .type(ReadyDesktopBuild.prepare)))
        XCTAssertTrue(ReadyDesktopBuild.prepare.contains("echo 3 > /proc/sys/vm/drop_caches"))
        XCTAssertTrue(ReadyDesktopBuild.prepare.contains("sync;"))
        XCTAssertGreaterThan(prepare, try XCTUnwrap(steps.firstIndex(of: .expect("BUREAU_2"))))
        XCTAssertEqual(steps.last, .screenLit)
    }
}
