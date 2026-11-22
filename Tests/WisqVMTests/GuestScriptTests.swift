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

    /// **L'image en PPM depuis des pixels** (ceux de l'écran du cœur Rust) :
    /// l'en-tête à la taille donnée, puis rouge, vert, bleu — les pixels
    /// arrivent le bleu d'abord, et leur quatrième octet ne part pas.
    func testAPPMIsWrittenFromPixels() {
        let ppm = GuestScript.ppm(pixels: [1, 2, 3, 0xFF, 4, 5, 6, 0], width: 2, height: 1)
        XCTAssertEqual(ppm, Data("P6\n2 1\n255\n".utf8) + Data([3, 2, 1, 6, 5, 4]))
    }

    /// **La règle des marques**, tenue sur le déroulé du bureau : aucune
    /// frappe ne contient la marque qu'on attend après elle. Sinon la console,
    /// qui répète la ligne tapée, la montrerait tout de suite.
    ///
    /// La marque d'échec d'une attente (`expectUnless`) aussi : écrite en
    /// clair dans la ligne, elle arrêterait la fabrication à coup sûr.
    func testNoTypedLineCarriesItsOwnMarker() {
        let steps = ReadyDesktopBuild.voidXfce
        var checked = 0
        for (index, step) in steps.enumerated() {
            guard case .type(let text) = step, index + 1 < steps.count else { continue }
            let markers: [String]
            switch steps[index + 1] {
            case .expect(let marker): markers = [marker]
            case .expectUnless(let marker, let refused): markers = [marker, refused]
            case .type, .screenLit: continue
            }
            for marker in markers {
                XCTAssertFalse(text.contains(marker), "« \(text) » contient « \(marker) »")
                checked += 1
            }
        }
        XCTAssertEqual(checked, 5, "mot de passe, invite, bureau, et la préparation deux fois")
    }

    /// **Une marque d'échec arrête l'attente tout de suite**, à la tranche où
    /// elle paraît, au lieu d'user tout le budget — deux mille milliards
    /// d'instructions, des heures, pour une préparation qui a dit non.
    func testARefusalStopsTheWaitAtOnce() {
        let (machine, script) = make()
        machine.outputs[2] = "REFUS_4\r\n"
        machine.outputs[3] = "PRET_2\r\n"
        XCTAssertThrowsError(try script.expect("PRET_2", unless: "REFUS_4", budget: 1000 * Self.slice)) {
            XCTAssertEqual($0 as? GuestScript.Failure, .refused("REFUS_4"))
        }
        XCTAssertEqual(machine.advances, 2)
    }

    /// La marque d'échec qui était là **avant** la frappe ne compte pas, et
    /// l'attente trouve sa marque comme `expect`.
    func testARefusalBeforeTheTypingDoesNotCount() throws {
        let (machine, script) = make()
        machine.console.append(Data("REFUS_4\r\n".utf8))
        machine.outputs[3] = "PRET_2\r\n"
        try script.run([.type("prepare\n"), .expectUnless("PRET_2", refused: "REFUS_4")], budget: 10 * Self.slice)
        XCTAssertEqual(machine.advances, 3)
        XCTAssertThrowsError(try script.run([.expectUnless("FIN_2", refused: "PRET_2")], budget: 10 * Self.slice)) {
            XCTAssertEqual($0 as? GuestScript.Failure, .refused("PRET_2"), "et une marque déjà là arrête sans tourner")
        }
        XCTAssertEqual(machine.advances, 3)
    }

    /// **Le bureau prêt est préparé, puis regardé, avant d'être sauvé** : le
    /// cache vidé, et l'écran vérifié en dernier.
    func testTheDesktopIsPreparedThenLookedAtLast() throws {
        let steps = ReadyDesktopBuild.voidXfce
        let prepare = try XCTUnwrap(steps.firstIndex(of: .type(ReadyDesktopBuild.prepare)))
        XCTAssertEqual(steps[prepare + 1], .expectUnless("PRET_2", refused: ReadyDesktopBuild.preparationRefused))
        XCTAssertTrue(ReadyDesktopBuild.prepare.contains("echo 3 > /proc/sys/vm/drop_caches"))
        XCTAssertTrue(ReadyDesktopBuild.prepare.contains("sync;"))
        XCTAssertGreaterThan(prepare, try XCTUnwrap(steps.firstIndex(of: .expect("BUREAU_2"))))
        XCTAssertEqual(steps.last, .screenLit)
    }
}
