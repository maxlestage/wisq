#if canImport(WebKit)
import Foundation
import WisqVMRust
import XCTest

/// **Le bureau local, de bout en bout, dans un vrai `WKWebView`.**
///
/// Toutes les moitiés ont été jugées séparément : l'émetteur contre le
/// silicium, la boucle hôte sous le JavaScriptCore de Bun, la page sous un pont
/// bouchonné, le C ABI par un programme C, le pont Swift sur Linux. Ce test est
/// le premier à les faire tenir ensemble dans le moteur qui les portera —
/// celui de WebKit, avec un vrai gestionnaire de messages entre les deux.
///
/// **Ce qu'il ne dit pas.** Un runner macOS n'est pas un iPhone : ce qui est
/// vérifié ici est que les moitiés s'emboîtent, pas que WebKit garde le droit
/// de compiler sur un appareil. Cette question-là n'a qu'une réponse, la sonde
/// de l'application sur un vrai téléphone.
@MainActor
final class LocalDesktopTests: XCTestCase {
    /// Une RAM d'une page, et une adresse au-dessus de deux puissance
    /// cinquante-trois : c'est là que vivent les noyaux, et c'est ce qui
    /// attrape une adresse passée en nombre plutôt qu'en texte.
    private let base: UInt64 = 0x0100_0000_0000_1000

    /// Deux régions. La première incrémente RDX puis saute dans la seconde par
    /// un registre — un saut indirect, que l'émetteur ne peut pas résoudre à la
    /// traduction, donc la vue devra demander la suite. La seconde incrémente
    /// RDX et s'arrête sur `ud2`.
    private func program() -> Data {
        var image = Data([0x48, 0xff, 0xc2, 0x48, 0xb8])
        withUnsafeBytes(of: (base + 0x100).littleEndian) { image.append(contentsOf: $0) }
        image.append(contentsOf: [0xff, 0xe0])
        image.append(contentsOf: [UInt8](repeating: 0x90, count: 0x100 - image.count))
        image.append(contentsOf: [0x48, 0xff, 0xc2, 0x0f, 0x0b])
        return image
    }

    func testTheDesktopRunsAMachineInsideARealWebView() async throws {
        let desktop = try LocalDesktop(pages: 1, entry: base)
        try await desktop.load()
        try await desktop.place(program(), at: base)

        let stopped = try await desktop.run()
        XCTAssertEqual(stopped.why, "sur place", "le `ud2` arrête la machine")
        XCTAssertEqual(stopped.at, base + 0x103, "et elle dit où")

        // **Deux incréments, et c'est ce qui prouve que la machine a tourné.**
        // Un arrêt au bon endroit se produirait aussi si rien ne s'était
        // exécuté ; RDX à deux veut dire que les deux régions ont couru.
        let rdx = try await desktop.global(2)
        XCTAssertEqual(rdx, 2, "les deux régions se sont exécutées")

        // Trois traductions : les deux régions, plus l'adresse du `ud2` que la
        // seconde atteint en retombant dessus.
        XCTAssertEqual(desktop.translations, 3, "une traduction par adresse atteinte")
        XCTAssertEqual(desktop.refusals, 0)
        XCTAssertEqual(
            desktop.unreadable, 0,
            "une demande illisible voudrait dire que la page et le pont ont divergé"
        )
    }

    /// **Une région que l'émetteur refuse arrête la machine proprement**, au
    /// lieu de la laisser sauter dans le vide. `06` est `push es`, qui n'existe
    /// pas en mode 64 bits.
    func testARegionTheEmitterRefusesStopsTheMachineWithAName() async throws {
        let desktop = try LocalDesktop(pages: 1, entry: base)
        try await desktop.load()
        var refused = Data([0x06])
        refused.append(contentsOf: [UInt8](repeating: 0x90, count: 32))
        try await desktop.place(refused, at: base)

        let stopped = try await desktop.run()
        XCTAssertEqual(stopped.why, "refusée")
        XCTAssertEqual(stopped.at, base)
        XCTAssertEqual(desktop.refusals, 1)
        XCTAssertEqual(desktop.translations, 0)
    }

    /// **Une image qui déborderait de la RAM invitée est refusée.**
    ///
    /// Elle n'écrirait pas « un peu trop loin » : la correspondance vit juste
    /// au-dessus, et la machine sauterait n'importe où au premier changement de
    /// région. La même borne que `host.js` pose sur sa lecture.
    func testAnImageThatWouldSpillIntoTheLookupIsRefused() async throws {
        let desktop = try LocalDesktop(pages: 1, entry: base)
        try await desktop.load()
        // La RAM fait une page ; l'adresse repliée est à 0x1000, donc il reste
        // 0xF000 octets. Un de plus déborde.
        let ram = 65536
        let room = ram - 0x1000
        try await desktop.place(Data(count: room), at: base)
        do {
            try await desktop.place(Data(count: room + 1), at: base)
            XCTFail("une image qui déborde doit être refusée")
        } catch let failure as LocalDesktop.Failure {
            XCTAssertEqual(
                failure, .imageDoesNotFit(folded: 0x1000, bytes: room + 1, ram: ram)
            )
        }
    }

    /// La RAM doit être une puissance de deux ici aussi : le refus doit tomber
    /// à la construction, pas à la première traduction, loin de sa cause.
    func testARAMThatCannotBeConfinedIsRefusedAtTheDoor() {
        XCTAssertThrowsError(try LocalDesktop(pages: 3, entry: base)) { why in
            XCTAssertEqual(why as? LocalDesktop.Failure, .ramIsNotAPowerOfTwo(3))
        }
        XCTAssertThrowsError(try LocalDesktop(pages: 0, entry: base))
    }

    // MARK: - L'écran

    /// **Le bureau peint, et il le dit.**
    ///
    /// C'est le seul chemin d'affichage qu'un test puisse emprunter ici :
    /// `requestAnimationFrame` ne tourne que dans une vue que le système
    /// considère comme affichée, et celle-ci n'est ajoutée à aucune fenêtre.
    /// `wisqPaint` se laisse appeler à la main **précisément pour ça**.
    ///
    /// Il peint **après** avoir fait tourner la machine : une image peinte
    /// avant que quoi que ce soit ne s'exécute ne dirait rien de plus que
    /// « le canvas existe ».
    func testTheDesktopPaintsTheFrameOnDemand() async throws {
        let width: UInt32 = 32
        let height: UInt32 = 16
        let desktop = try LocalDesktop(
            pages: 1,
            entry: base,
            screen: .init(base: base + 0x8000, width: width, height: height)
        )
        try await desktop.load()
        try await desktop.place(program(), at: base)
        let stopped = try await desktop.run()
        XCTAssertEqual(stopped.why, "sur place")

        let pixels = try await desktop.paint()
        XCTAssertEqual(
            pixels, Int(width * height),
            "peindre doit rendre le compte de pixels, pas rien"
        )
    }

    /// **Un bureau sans écran refuse de peindre**, au lieu de laisser croire
    /// qu'une image est passée. C'est le refus qui distingue « rien à montrer »
    /// de « rien ne s'est affiché ».
    func testADesktopWithoutAFrameRefusesToPaint() async throws {
        let desktop = try LocalDesktop(pages: 1, entry: base)
        try await desktop.load()
        do {
            _ = try await desktop.paint()
            XCTFail("un bureau sans cadre doit refuser de peindre")
        } catch let failure as LocalDesktop.Failure {
            XCTAssertEqual(failure, .noFrameWasDeclared)
        }
    }

    /// **Un cadre qui déborderait de la RAM invitée est refusé à la
    /// construction**, comme la RAM elle-même — pas au chargement de la page,
    /// loin de sa cause. La borne est vérifiée des deux côtés : sans le cas qui
    /// passe, un refus qui refuserait tout aurait l'air d'une garde.
    func testAFrameThatWouldSpillIntoTheLookupIsRefusedAtTheDoor() throws {
        // Une page de RAM : 65 536 octets, soit exactement 128×128 pixels.
        XCTAssertNoThrow(
            try LocalDesktop(
                pages: 1, entry: base, screen: .init(base: 0, width: 128, height: 128)
            )
        )
        XCTAssertThrowsError(
            try LocalDesktop(
                pages: 1, entry: base, screen: .init(base: 4, width: 128, height: 128)
            )
        ) { why in
            XCTAssertEqual(
                why as? LocalDesktop.Failure,
                .imageDoesNotFit(folded: 4, bytes: 65536, ram: 65536)
            )
        }
        XCTAssertThrowsError(
            try LocalDesktop(
                pages: 1, entry: base, screen: .init(base: 0, width: 0, height: 128)
            ),
            "un cadre sans surface n'est pas un cadre"
        )
        // **Et une surface qui déborde de soixante-quatre bits est refusée, pas
        // enroulée.** Deux dimensions de deux puissance trente et un donnent
        // exactement deux puissance soixante-quatre : en Swift la
        // multiplication piégerait, ce qui n'est pas un refus.
        XCTAssertThrowsError(
            try LocalDesktop(
                pages: 1, entry: base,
                screen: .init(base: 0, width: 1 << 31, height: 1 << 31)
            )
        )
        XCTAssertThrowsError(
            try LocalDesktop(
                pages: 1, entry: base,
                screen: .init(base: 0, width: .max, height: .max)
            )
        )
        // **Et celui-ci ne déborde pas, mais ne tient pas dans un `Int`** :
        // deux puissance trente et un par deux puissance vingt-neuf font deux
        // puissance soixante en pixels, deux puissance soixante-deux en octets.
        // Convertir ça en `Int` pour le porter dans le refus piégerait — le
        // refus deviendrait un plantage. Vu en relisant, pas en compilant.
        XCTAssertThrowsError(
            try LocalDesktop(
                pages: 1, entry: base,
                screen: .init(base: 0, width: 1 << 31, height: 1 << 30)
            )
        )
    }
}
#endif
