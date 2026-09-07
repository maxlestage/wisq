import Foundation
import WisqVMRust
import XCTest

/// **Le pont, éprouvé sans la vue.**
///
/// Ce que `WKScriptMessage` livre est un dictionnaire de valeurs Foundation ;
/// ce que la vue attend en retour est du JavaScript. Ni l'un ni l'autre n'a
/// besoin d'un `WKWebView` pour être jugé, et c'est ce qui met la moitié
/// utile de l'application sous la CI Linux.
final class DesktopBridgeTests: XCTestCase {
    /// **Une adresse au-dessus de deux puissance cinquante-trois**, choisie
    /// exprès : avec une petite, les sabotages qui perdent les bits de poids
    /// fort survivent tous.
    private let high: UInt64 = 0x0100_0000_0000_1000

    // MARK: - Lire une demande

    func testATranslationRequestIsRead() throws {
        let code = Data([0x48, 0x01, 0xc2, 0x75, 0xfb])
        let request = try DesktopBridge.request(from: [
            "kind": "traduire", "id": 7, "address": "\(high)", "slot": 12,
            "octets": code.base64EncodedString(),
        ])
        XCTAssertEqual(request, .translate(id: 7, address: high, slot: 12, code: code))
    }

    /// **Une demande sans octets est refusée, pas traduite à vide.**
    ///
    /// C'est la garde qui empêche de revenir au contrat d'avant, où
    /// l'application devait deviner les octets depuis l'image qu'elle avait
    /// chargée — juste pour le noyau, faux en silence pour un module que
    /// l'invité charge lui-même.
    func testATranslationRequestWithoutBytesIsRefused() {
        let refused: [([String: Any], DesktopBridge.Unreadable)] = [
            (["kind": "traduire", "id": 1, "address": "16", "slot": 0], .missingField("octets")),
            (
                ["kind": "traduire", "id": 1, "address": "16", "slot": 0, "octets": ""],
                .bytesAreNotBase64
            ),
            (
                ["kind": "traduire", "id": 1, "address": "16", "slot": 0, "octets": "pas du b64 !"],
                .bytesAreNotBase64
            ),
        ]
        for (body, expected) in refused {
            XCTAssertThrowsError(try DesktopBridge.request(from: body), "\(body)") { why in
                XCTAssertEqual(why as? DesktopBridge.Unreadable, expected, "\(body)")
            }
        }
    }

    /// **Une fenêtre entière fait l'aller-retour**, tous les octets compris —
    /// un base64 tronqué au dernier groupe passerait un test sur cinq octets.
    func testAWholeWindowSurvivesTheCrossing() throws {
        var window = Data(count: 4096)
        for at in 0..<window.count { window[at] = UInt8(truncatingIfNeeded: at &* 31 &+ 7) }
        XCTAssertTrue(window.contains(0))
        XCTAssertTrue(window.contains(0xff))
        let request = try DesktopBridge.request(from: [
            "kind": "traduire", "id": 1, "address": "16", "slot": 0,
            "octets": window.base64EncodedString(),
        ])
        guard case .translate(_, _, _, let code) = request else {
            return XCTFail("la demande doit être une traduction")
        }
        XCTAssertEqual(code, window)
    }

    /// **« Il m'en faut plus » est une réponse à part**, que la vue reconnaît.
    /// Le nom de la fonction est celui que le pilote de la page déclare ; un
    /// test du côté Rust tient l'autre moitié.
    func testNeedingMoreIsItsOwnAnswer() {
        XCTAssertEqual(DesktopBridge.needsMore(id: 5), "wisqNeedsMore(5)")
        XCTAssertNotEqual(DesktopBridge.needsMore(id: 5), DesktopBridge.translated(id: 5, module: nil))
    }

    /// **L'adresse est lue en base dix**, et ce test le tient pour la bonne
    /// raison. Le sabotage « lue en hexadécimal » tombe aussi sur une grande
    /// adresse, mais seulement parce qu'un long nombre décimal déborde en base
    /// seize — une chance, pas une garde. Seize et vingt-deux, eux, ne peuvent
    /// pas se confondre par accident.
    func testTheAddressIsReadInBaseTen() throws {
        let request = try DesktopBridge.request(from: [
            "kind": "traduire", "id": 1, "address": "16", "slot": 0, "octets": "AAA=",
        ])
        XCTAssertEqual(
            request, .translate(id: 1, address: 16, slot: 0, code: Data([0, 0]))
        )
    }

    /// **L'adresse traverse en texte, et un nombre est refusé plutôt que
    /// tronqué.** Un `Number` JavaScript perd ses bits au-delà de deux
    /// puissance cinquante-trois ; accepter le nombre ferait traduire une
    /// région ailleurs, en silence, et c'est le pire des deux comportements.
    func testAnAddressThatArrivesAsANumberIsRefused() {
        XCTAssertThrowsError(
            try DesktopBridge.request(from: [
                "kind": "traduire", "id": 1, "address": Int(high), "slot": 0, "octets": "AAA=",
            ])
        ) { why in
            XCTAssertEqual(why as? DesktopBridge.Unreadable, .addressIsNotText)
        }
    }

    func testAnAddressThatIsNotANumberIsRefused() {
        XCTAssertThrowsError(
            try DesktopBridge.request(from: [
                "kind": "traduire", "id": 1, "address": "0x1000", "slot": 0, "octets": "AAA=",
            ])
        ) { why in
            XCTAssertEqual(
                why as? DesktopBridge.Unreadable, .addressIsNotANumber("0x1000")
            )
        }
    }

    func testTheStopRequestIsRead() throws {
        let request = try DesktopBridge.request(from: [
            "kind": "arrêt", "stopped": "refusée", "at": "\(high)",
        ])
        XCTAssertEqual(request, .stopped(why: "refusée", at: high))
    }

    /// La page est engendrée par wisq : une demande illisible veut dire que les
    /// deux moitiés ont divergé, pas qu'un utilisateur a mal saisi quelque
    /// chose. Elle doit donc être bruyante, et nommer ce qui manque.
    func testADemandTheContractDoesNotDescribeIsRefused() {
        let refused: [([String: Any], DesktopBridge.Unreadable)] = [
            ([:], .noKind),
            (["kind": "bonjour"], .unknownKind("bonjour")),
            (
                ["kind": "traduire", "address": "16", "slot": 0, "octets": "AAA="],
                .missingField("id")
            ),
            (
                ["kind": "traduire", "id": 1, "slot": 0, "octets": "AAA="],
                .missingField("address")
            ),
            (
                ["kind": "traduire", "id": 1, "address": "16", "octets": "AAA="],
                .missingField("slot")
            ),
            (["kind": "arrêt", "at": "16"], .missingField("stopped")),
        ]
        for (body, expected) in refused {
            XCTAssertThrowsError(try DesktopBridge.request(from: body), "\(body)") { why in
                XCTAssertEqual(why as? DesktopBridge.Unreadable, expected, "\(body)")
            }
        }
    }

    // MARK: - Les deux moitiés du pont

    /// **Swift appelle des fonctions que la page déclare, et rien ne le tenait.**
    ///
    /// `translated` et `needsMore` produisent du JavaScript qui nomme
    /// `wisqTranslated` et `wisqNeedsMore` ; c'est le pilote, écrit en Rust
    /// dans `crates/wisq-vm/src/desktop.rs`, qui les pose sur `window`. Deux
    /// littéraux dans deux langues, qu'aucun compilateur ne rapproche : renommer
    /// d'un côté donnerait une application qui parle dans le vide, et l'écran
    /// resterait figé sans un mot.
    ///
    /// Le test lit donc le pilote et vérifie que ce que Swift appelle y est
    /// déclaré. Même raison que le miroir des constantes de `web/host.js` : une
    /// répétition que rien ne compare finit toujours par mentir.
    func testTheFunctionsSwiftCallsAreTheOnesThePageDeclares() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let driver = try String(
            contentsOf: root.appendingPathComponent("crates/wisq-vm/src/desktop.rs"),
            encoding: .utf8
        )
        for produced in [
            DesktopBridge.translated(id: 1, module: nil),
            DesktopBridge.needsMore(id: 1),
        ] {
            let name = String(produced.prefix(while: { $0 != "(" }))
            XCTAssertTrue(
                driver.contains("window.\(name) ="),
                "le pilote de la page ne déclare pas « \(name) »"
            )
        }
    }

    // MARK: - Répondre

    func testARefusalIsAnswerdAsNull() {
        XCTAssertEqual(DesktopBridge.translated(id: 3, module: nil), "wisqTranslated(3, null)")
    }

    /// **Le vrai module fait l'aller-retour, octet pour octet.** Le test relit
    /// le JavaScript produit et reconstruit les octets : une virgule de trop,
    /// un zéro perdu, un 255 devenu -1 se voient là et nulle part ailleurs.
    func testAWholeModuleSurvivesTheCrossing() throws {
        let loop = Data([0x48, 0x01, 0xc2, 0x75, 0xfb])
        let module = try XCTUnwrap(
            DesktopTranslator.resolvingRegion(
                loop, base: 0x3000_0000, entry: 0, slot: 0, pages: 16
            )
        )
        XCTAssertTrue(module.contains(0), "le module doit porter des zéros")
        XCTAssertTrue(module.contains(0xff), "le module doit porter des 255")

        let script = DesktopBridge.translated(id: 41, module: module)
        let read = try XCTUnwrap(bytes(of: script, id: 41))
        XCTAssertEqual(read, [UInt8](module))
    }

    /// Relit `wisqTranslated(<id>, [<octets>])` sans rien deviner : un format
    /// différent rend `nil`, et le test échoue plutôt que de comparer deux
    /// tableaux vides.
    private func bytes(of script: String, id: Int) -> [UInt8]? {
        let opening = "wisqTranslated(\(id), ["
        guard script.hasPrefix(opening), script.hasSuffix("])") else { return nil }
        let inside = script.dropFirst(opening.count).dropLast(2)
        if inside.isEmpty { return [] }
        var read: [UInt8] = []
        for piece in inside.split(separator: ",", omittingEmptySubsequences: false) {
            guard let byte = UInt8(piece) else { return nil }
            read.append(byte)
        }
        return read
    }
}
