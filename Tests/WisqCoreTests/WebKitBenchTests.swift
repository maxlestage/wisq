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

    /// **La question des deux mémoires est portée à côté du débit, pas dedans.**
    ///
    /// Elle ne parle pas de vitesse : elle décide de *où* peut vivre la table
    /// qui rendrait l'enchaînement rapide. La correspondance adresse → indice
    /// ne peut pas tenir dans la mémoire de l'invité — un noyau qui écrit au
    /// mauvais endroit la détruirait, exactement comme il écrasait RCX avant
    /// que les registres n'en sortent. Il lui faut une seconde mémoire.
    ///
    /// Un « non » n'arrête pas le bureau, et la phrase doit le dire : il ferme
    /// un chemin et en laisse un autre, plus lourd.
    func testTheTwoMemoriesQuestionIsCarriedBesideTheThroughputNotInsideIt() {
        let accepted = WebKitBench.judge(
            mips: 400, bridgeMilliseconds: 0.5,
            instructions: 160_000_000, expected: 160_000_000, multiMemory: true)
        guard case .compiles(let reading) = accepted else {
            return XCTFail("400 MIPS compile : \(accepted)")
        }
        XCTAssertTrue(reading.multiMemory, "la réponse doit survivre au jugement")

        let refused = WebKitBench.judge(
            mips: 400, bridgeMilliseconds: 0.5,
            instructions: 160_000_000, expected: 160_000_000, multiMemory: false)
        guard case .compiles(let without) = refused else {
            return XCTFail("le débit ne dépend pas des mémoires : \(refused)")
        }
        XCTAssertFalse(without.multiMemory)
        XCTAssertEqual(reading.mips, without.mips,
                       "et elle ne doit pas changer le débit d'un iota")

        XCTAssertTrue(WebKitBench.multiMemorySentence(true).contains("hors de portée"),
                      "un oui dit ce qu'il ouvre")
        let no = WebKitBench.multiMemorySentence(false)
        XCTAssertTrue(no.contains("pas un mur"), "un non ne doit pas se lire comme une fin : \(no)")
        XCTAssertTrue(no.contains("trois cœurs"),
                      "et doit nommer ce que l'autre chemin coûte : \(no)")
    }

    /// **L'appareil peut refuser le module, et c'est une réponse.** Le module
    /// de l'émetteur importe 768 Mio de RAM invitée ; le module écrit à la main
    /// qu'il remplace en déclarait deux pages et ne pouvait rien refuser. Ranger
    /// ce mur dans « indisponible » ferait lire un fait sur ce que wisq engendre
    /// comme un contretemps de la sonde.
    func testARefusedModuleIsNotFiledAsAToolingHiccup() {
        let sentence = WebKitBench.sentence(for: .refused("Memory import env:mem is too large"))
        XCTAssertTrue(sentence.contains("refus"),
                      "un refus doit se nommer comme tel : \(sentence)")
        XCTAssertTrue(sentence.contains("\(WebKitBench.guestPages)"),
                      "et dire ce qui a été demandé : \(sentence)")
        XCTAssertFalse(sentence.contains("outillage"),
                       "ce n'est pas de l'outillage, c'est une réponse")
    }

    /// **Le module est celui de l'émetteur, et les constantes sont les
    /// siennes.** L'égalité octet pour octet est tenue côté Rust, par
    /// `bench_module_matches_the_probe`, qui refait le module et le compare à
    /// cette chaîne. Ce test-ci tient l'autre moitié, celle que le Rust ne voit
    /// pas : que `globalCount` décrive **ce module-là**. Instancier vingt-huit
    /// globales pour un module qui en importe vingt-neuf ne rend pas un mauvais
    /// chiffre, il ne rend rien — et la sonde dirait « refusé » là où c'est une
    /// constante fausse.
    func testTheModuleIsTheEmittersAndTheConstantsDescribeIt() {
        let module = Data(base64Encoded: WebKitBench.moduleBase64) ?? Data()
        XCTAssertEqual(Array(module.prefix(4)), [0x00, 0x61, 0x73, 0x6D],
                       "l'en-tête WebAssembly, « \\0asm »")
        XCTAssertGreaterThan(module.count, 300, "et un module, pas un fragment")

        // L'entrée d'import d'une globale : « env », son nom, puis le type
        // `i64` mutable. La chercher telle quelle évite d'écrire un analyseur
        // de WebAssembly dans un test.
        func importEntry(_ slot: Int) -> Data {
            var bytes: [UInt8] = [0x03]
            bytes.append(contentsOf: Array("env".utf8))
            let name = Array("g\(slot)".utf8)
            bytes.append(UInt8(name.count))
            bytes.append(contentsOf: name)
            bytes.append(contentsOf: [0x03, 0x7E, 0x01])
            return Data(bytes)
        }
        XCTAssertNotNil(module.range(of: importEntry(WebKitBench.globalCount - 1)),
                        "la dernière globale annoncée doit être importée par le module")
        XCTAssertNil(module.range(of: importEntry(WebKitBench.globalCount)),
                     "et il ne doit pas en importer une de plus que ce qui est annoncé")
        // La mémoire importée, et sa taille minimale en pages : « env », « mem »,
        // le type mémoire, puis l'entier à longueur variable de WebAssembly.
        var memoryEntry: [UInt8] = [0x03]
        memoryEntry.append(contentsOf: Array("env".utf8))
        memoryEntry.append(0x03)
        memoryEntry.append(contentsOf: Array("mem".utf8))
        memoryEntry.append(contentsOf: [0x02, 0x00])
        var pages = WebKitBench.guestPages
        while true {
            var byte = UInt8(pages & 0x7F)
            pages >>= 7
            if pages != 0 { byte |= 0x80 }
            memoryEntry.append(byte)
            if pages == 0 { break }
        }
        XCTAssertNotNil(module.range(of: Data(memoryEntry)),
                        "le module doit importer exactement les \(WebKitBench.guestPages) "
                            + "pages que la sonde crée")

        XCTAssertNotNil(module.range(of: Data("run".utf8)),
                        "le module exporte « run », c'est ce que la sonde appelle")
    }
}
