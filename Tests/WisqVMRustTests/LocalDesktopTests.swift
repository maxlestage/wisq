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

    /// La RAM doit être une puissance de deux ici aussi : le refus doit tomber
    /// à la construction, pas à la première traduction, loin de sa cause.
    func testARAMThatCannotBeConfinedIsRefusedAtTheDoor() {
        XCTAssertThrowsError(try LocalDesktop(pages: 3, entry: base)) { why in
            XCTAssertEqual(why as? LocalDesktop.Failure, .ramIsNotAPowerOfTwo(3))
        }
        XCTAssertThrowsError(try LocalDesktop(pages: 0, entry: base))
    }
}
#endif
