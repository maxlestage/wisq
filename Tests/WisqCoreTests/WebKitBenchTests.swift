import XCTest

@testable import WisqCore

/// **Ce qu'un chiffre veut dire, décidé ici plutôt que dans une vue.**
///
/// La sonde WebKit rend deux nombres : un débit et le coût d'un aller-retour.
/// Seuls, ils ne disent rien à personne. Ce qui compte, c'est ce qu'ils
/// impliquent — un bureau démarre-t-il en deux minutes ou en une heure ? — et
/// cette traduction est du calcul, pas de l'affichage. Elle vit donc ici, où
/// un test peut la tenir sur n'importe quelle plateforme, plutôt que dans une
/// vue que seul un iPhone exécute.
final class WebKitBenchTests: XCTestCase {
    /// **Le seuil sépare deux mondes, il ne mesure pas une machine.** Un
    /// JavaScriptCore réduit à son interpréteur rend quelques MIPS sur cette
    /// boucle ; vingt écarte le doute sans dépendre de l'appareil.
    func testAThroughputAboveTheThresholdMeansWebKitCompiles() {
        let verdict = WebKitBench.judge(
            mips: 400, bridgeMilliseconds: 0.5,
            instructions: 160_000_000, expected: 160_000_000)
        guard case .compiles(let reading) = verdict else {
            return XCTFail("400 MIPS est un compilateur, pas un interpréteur : \(verdict)")
        }
        XCTAssertEqual(reading.mips, 400)
    }

    func testAnInterpreterThroughputIsNamedAsSuch() {
        let verdict = WebKitBench.judge(
            mips: 12, bridgeMilliseconds: 0.5,
            instructions: 160_000_000, expected: 160_000_000)
        guard case .interpretsOnly = verdict else {
            return XCTFail("douze MIPS n'est pas un compilateur : \(verdict)")
        }
    }

    /// **Un module qui n'a pas tout exécuté rend un débit magnifique et faux.**
    /// Le compte d'instructions est donc vérifié avant le débit — sinon une
    /// boucle sortie trop tôt passerait pour une machine rapide.
    func testAModuleThatDidNotFinishIsRefusedBeforeItsThroughputIsBelieved() {
        let verdict = WebKitBench.judge(
            mips: 9_000, bridgeMilliseconds: 0.5,
            instructions: 1_000, expected: 160_000_000)
        XCTAssertEqual(verdict, .wrongResult,
                       "un compte d'instructions faux invalide le débit, si beau soit-il")
    }

    /// **Le pont a son propre budget, et il est indépendant du débit.** Une
    /// image à soixante par seconde tient dans 16,7 ms ; un aller-retour qui
    /// mange tout ça rend le bureau inutilisable même si le cœur vole.
    func testAnExpensiveBridgeIsCalledOutEvenWhenTheCoreIsFast() {
        let verdict = WebKitBench.judge(
            mips: 1_000, bridgeMilliseconds: 20,
            instructions: 160_000_000, expected: 160_000_000)
        guard case .compiles(let reading) = verdict else {
            return XCTFail("le cœur compile : \(verdict)")
        }
        XCTAssertFalse(reading.bridgeFitsAFrame, "vingt millisecondes dépassent l'image")
        XCTAssertTrue(
            WebKitBench.sentence(for: verdict).contains("pont"),
            "et la phrase doit le dire, sinon le chiffre est lu de travers")
    }

    /// **Le nombre qui parle à un humain.** « 400 MIPS » ne dit rien ; « un
    /// bureau démarre en deux minutes » dit tout. Cinquante milliards
    /// d'instructions est l'ordre de grandeur d'un démarrage complet, et c'est
    /// une estimation assumée, pas une mesure.
    func testTheThroughputIsTranslatedIntoATimeAHumanCanJudge() {
        XCTAssertEqual(WebKitBench.bootMinutes(atMIPS: 10.6), 78.6, accuracy: 0.5)
        XCTAssertEqual(WebKitBench.bootMinutes(atMIPS: 400), 2.08, accuracy: 0.05)
        XCTAssertEqual(WebKitBench.bootMinutes(atMIPS: 1_103), 0.76, accuracy: 0.05)
    }

    /// **Une vue qui ne démarre pas est un saut, pas une réponse**, et la
    /// phrase doit le dire au lieu de laisser croire à un échec du matériel.
    func testAViewThatNeverStartedSaysSoRatherThanBlamingTheHardware() {
        let sentence = WebKitBench.sentence(for: .unavailable("le WKWebView n'a pas chargé"))
        XCTAssertTrue(sentence.contains("outillage"),
                      "un saut doit se nommer comme tel : \(sentence)")
        XCTAssertFalse(sentence.contains("iOS interdit"),
                       "et ne doit surtout pas conclure à la place de la mesure")
    }

    /// **Le module est celui de la sonde, à l'octet près.** Deux copies
    /// divergeraient, et l'application mesurerait alors autre chose que ce que
    /// la CI mesure — deux chiffres qu'on croirait comparables.
    func testTheModuleIsRealAndWellFormed() {
        let module = Data(base64Encoded: WebKitBench.moduleBase64) ?? Data()
        XCTAssertEqual(Array(module.prefix(4)), [0x00, 0x61, 0x73, 0x6D],
                       "l'en-tête WebAssembly, « \\0asm »")
        XCTAssertGreaterThan(module.count, 300, "et un module, pas un fragment")
    }
}
