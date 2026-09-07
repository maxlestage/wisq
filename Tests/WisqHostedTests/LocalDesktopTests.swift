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
/// **Ce qu'il ne dit pas.** Un simulateur n'est pas un iPhone : ce qui est
/// vérifié ici est que les moitiés s'emboîtent, pas que WebKit garde le droit
/// de compiler sur un appareil. Cette question-là n'a qu'une réponse, la sonde
/// de l'application sur un vrai téléphone.
///
/// **Pourquoi cette suite est hébergée par l'application, et pas sous
/// `swift test`.** Elle y a été, et elle y était non déterministe. Le premier
/// test du processus — celui qui crée le premier `WKWebView`, à froid — a rendu
/// deux verdicts opposés sur **un code identique**, à deux passages
/// consécutifs de la CI, sur `InvalidTransition { phase: idle, targetPhase:
/// failed(deinit) }`. Et ce message sortait d'un `load()` enveloppé **en
/// entier** dans un `do`/`catch` qui traduit n'importe quelle erreur : il ne
/// venait donc d'aucun de nos appels.
///
/// La raison était déjà écrite dans `project.yml`, à la cible qui héberge ce
/// fichier : « WebKit rend dans un processus séparé qu'iOS ne démarre pas pour
/// un `xctest` nu ». `swift test` en est un. Sept des huit tests passaient
/// parce qu'ils héritaient d'un état déjà chaud — ce n'est pas une propriété
/// sur laquelle bâtir une garde.
///
/// Rien n'est retiré ni affaibli : la suite est posée là où WebKit a ce qu'il
/// lui faut, et « App iOS » l'exécute à chaque commit, comme « Cœur (Apple) »
/// le faisait.
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

    // MARK: - L'image du noyau

    /// **Ce que coûte vraiment le chemin de l'image, et ce qu'il pose.**
    ///
    /// L'image du noyau traverse par `evaluateJavaScript`, en tranches de
    /// 48 Kio de base64. C'est écrit « assumé et cher » depuis quatre tranches,
    /// sans qu'aucun nombre ne soit derrière. En voici un — et le remplacer par
    /// un gestionnaire de schéma se décidera sur ce nombre, pas sur
    /// l'impression qu'il est gros.
    ///
    /// **Mesurer une écriture sans pouvoir la relire mesurerait peut-être
    /// zéro octet posé.** Une `place` qui perdrait une tranche sur deux serait
    /// deux fois plus « rapide », et se comporterait comme une `place` qui
    /// marche jusqu'à ce que la machine saute dans le vide bien plus tard. Le
    /// test relit donc, et **aux bords des tranches** : c'est là qu'un décalage
    /// d'offset se voit, pas au milieu.
    func testPlacingAKernelSizedImageLandsIntactAndSaysWhatItCosts() async throws {
        let pages: UInt32 = 128 // huit mébioctets de RAM invitée
        let bytes = 4 * 1024 * 1024
        let chunk = 48 * 1024
        let desktop = try LocalDesktop(pages: pages, entry: base)
        try await desktop.load()

        // **Un motif, pas des zéros.** Une image de zéros arriverait intacte
        // même si la moitié des tranches se perdait : la mémoire est déjà à
        // zéro.
        // Par un tableau plutôt qu'octet par octet dans un `Data` : quatre
        // millions d'indexations de `Data` en debug coûteraient plus cher que
        // ce que ce test mesure.
        var pattern = [UInt8](repeating: 0, count: bytes)
        for index in 0..<bytes {
            pattern[index] = UInt8((index &* 31 &+ 7) & 0xff)
        }
        let image = Data(pattern)

        let started = Date()
        try await desktop.place(image, at: base)
        let seconds = Date().timeIntervalSince(started)
        let rate = Double(bytes) / seconds / 1_048_576
        print("wisq: image de \(bytes / 1_048_576) Mio posée en "
            + String(format: "%.2f", seconds) + " s, "
            + String(format: "%.1f", rate) + " Mio/s")

        // **Les bords de tranche, là où un décalage se voit.** Le début, la
        // dernière et la première paire d'octets de part et d'autre de la
        // première frontière, une frontière lointaine, et la toute fin.
        for offset in [0, chunk - 128, chunk, chunk * 2 - 1, chunk * 40, bytes - 256] {
            let count = min(256, bytes - offset)
            let back = try await desktop.read(count, at: base + UInt64(offset))
            XCTAssertEqual(
                back, image[offset..<offset + count],
                "les octets relus à \(offset) ne sont pas ceux qui ont été posés"
            )
        }
    }

    /// Relire au-delà de la RAM invitée irait chercher la correspondance, que
    /// l'application prendrait pour de la mémoire invitée. Même borne que
    /// l'écriture, dans l'autre sens.
    func testReadingPastTheGuestsRAMIsRefused() async throws {
        let desktop = try LocalDesktop(pages: 1, entry: base)
        try await desktop.load()
        let ram = 65536
        let room = ram - 0x1000 // l'adresse repliée est à 0x1000
        // Hissé hors de l'assertion : `XCTAssertEqual` prend une autoclosure,
        // qui accepte `try` mais **pas** `await`.
        let filled = try await desktop.read(room, at: base)
        XCTAssertEqual(filled.count, room)
        do {
            _ = try await desktop.read(room + 1, at: base)
            XCTFail("une lecture qui déborde doit être refusée")
        } catch let failure as LocalDesktop.Failure {
            XCTAssertEqual(
                failure, .imageDoesNotFit(folded: 0x1000, bytes: room + 1, ram: ram)
            )
        }
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
