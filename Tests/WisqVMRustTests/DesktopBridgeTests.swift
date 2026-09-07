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
        let request = try DesktopBridge.request(from: [
            "kind": "traduire", "id": 7, "address": "\(high)", "slot": 12,
        ])
        XCTAssertEqual(request, .translate(id: 7, address: high, slot: 12))
    }

    /// **L'adresse est lue en base dix**, et ce test le tient pour la bonne
    /// raison. Le sabotage « lue en hexadécimal » tombe aussi sur une grande
    /// adresse, mais seulement parce qu'un long nombre décimal déborde en base
    /// seize — une chance, pas une garde. Seize et vingt-deux, eux, ne peuvent
    /// pas se confondre par accident.
    func testTheAddressIsReadInBaseTen() throws {
        let request = try DesktopBridge.request(from: [
            "kind": "traduire", "id": 1, "address": "16", "slot": 0,
        ])
        XCTAssertEqual(request, .translate(id: 1, address: 16, slot: 0))
    }

    /// **L'adresse traverse en texte, et un nombre est refusé plutôt que
    /// tronqué.** Un `Number` JavaScript perd ses bits au-delà de deux
    /// puissance cinquante-trois ; accepter le nombre ferait traduire une
    /// région ailleurs, en silence, et c'est le pire des deux comportements.
    func testAnAddressThatArrivesAsANumberIsRefused() {
        XCTAssertThrowsError(
            try DesktopBridge.request(from: [
                "kind": "traduire", "id": 1, "address": Int(high), "slot": 0,
            ])
        ) { why in
            XCTAssertEqual(why as? DesktopBridge.Unreadable, .addressIsNotText)
        }
    }

    func testAnAddressThatIsNotANumberIsRefused() {
        XCTAssertThrowsError(
            try DesktopBridge.request(from: [
                "kind": "traduire", "id": 1, "address": "0x1000", "slot": 0,
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
            (["kind": "traduire", "address": "16", "slot": 0], .missingField("id")),
            (["kind": "traduire", "id": 1, "slot": 0], .missingField("address")),
            (["kind": "traduire", "id": 1, "address": "16"], .missingField("slot")),
            (["kind": "arrêt", "at": "16"], .missingField("stopped")),
        ]
        for (body, expected) in refused {
            XCTAssertThrowsError(try DesktopBridge.request(from: body), "\(body)") { why in
                XCTAssertEqual(why as? DesktopBridge.Unreadable, expected, "\(body)")
            }
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
