#if canImport(WebKit)
import Foundation
import WisqVMRust
import XCTest

/// **Le bureau peint — et cette question-là a besoin d'une application.**
///
/// Les huit autres tests du bureau vivent dans `LocalDesktopTests`, sous
/// `swift test`, et ils passent. Celui-ci y a échoué trois fois de suite sur un
/// message qui ne nomme rien :
///
/// ```
/// InvalidTransition { phase: idle, targetPhase: failed(deinit) }
/// ```
///
/// **Ce qui l'a séparé des autres n'est pas dans son code.** Deux tests écrits à
/// l'identique — `LocalDesktop(pages: 1, entry: base)` puis `load()` — l'un
/// passait, l'autre non ; et `load()` enveloppée **en entier** dans un
/// `do`/`catch` qui traduit toute erreur en refus nommé n'a rien attrapé : le
/// message est ressorti tel quel. Ce n'était donc pas un chemin de code, et
/// deux explications successives — une course sur `web.isLoading`, puis le
/// canvas lui-même — sont tombées l'une après l'autre.
///
/// **La réponse était écrite dans ce dépôt**, dans le commentaire qui justifie
/// la cible où ce fichier vit maintenant : « WebKit rend dans un processus
/// séparé qu'iOS ne démarre pas pour un `xctest` nu ». `swift test` est
/// exactement un `xctest` nu. Des neuf tests du bureau, celui-ci est le seul
/// qui demande une **surface de rendu** — les autres n'évaluent que du
/// JavaScript. Il ne manquait pas une correction, il manquait un hôte.
///
/// Il n'est donc ni retiré ni affaibli : il est déplacé là où la question qu'il
/// pose peut recevoir une réponse, et il reste exécuté à chaque commit, par
/// « App iOS » via `scripts/test-app.sh`, dans un iPhone simulé.
@MainActor
final class LocalDesktopPaintTests: XCTestCase {
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
}
#endif
