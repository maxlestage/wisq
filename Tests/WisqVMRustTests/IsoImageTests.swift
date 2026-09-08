import Foundation
import XCTest

@testable import WisqVMRust

/// **Le pont vers le lecteur d'image, jugé de bout en bout.**
///
/// Le lecteur lui-même vit en Rust et ses tests sont là-bas — bourrage entre
/// deux secteurs, noms Rock Ridge qui mentent sur leur longueur, entrées de
/// chargeur, plafonds. Ici on juge autre chose : **ce que Swift reçoit**. Les
/// quatre chaînes se recomposent-elles dans le bon ordre ? Un initramfs absent
/// devient-il `nil` plutôt qu'une chaîne vide ? Un membre trop gros laisse-t-il
/// le disque propre ?
///
/// L'image d'essai est gravée par `IsoGravure`, à côté — le même gréement sert
/// à `IsoBootTests`, et une seule copie vaut mieux que deux qui divergent.
final class IsoImageTests: XCTestCase {
    private static let kernel = IsoGravure.kernel

    private func gravure(withInitrd: Bool = true) -> Data {
        IsoGravure(
            recipeInitrd: withInitrd ? "/boot/initramfs-virt" : nil,
            carriesInitrd: withInitrd
        ).data()
    }

    private func write<Bytes: DataProtocol>(_ bytes: Bytes) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wisq-essai-\(getpid())-\(UUID().uuidString).iso")
        try Data(bytes).write(to: url)
        return url
    }

    /// **La recette arrive entière, et dans l'ordre.**
    ///
    /// Quatre chaînes traversent la frontière, séparées par l'octet nul. Un
    /// ordre inversé donnerait un noyau nommé par une ligne de commande, ce
    /// qu'aucun compilateur ne peut voir.
    func testTheRecipeCrossesWholeAndInOrder() throws {
        let image = try write(gravure())
        defer { try? FileManager.default.removeItem(at: image) }
        let recipe = try XCTUnwrap(IsoImage.recipe(of: image))
        XCTAssertEqual(recipe.from, "/boot/syslinux/syslinux.cfg")
        XCTAssertEqual(recipe.kernel, "/boot/vmlinuz-virt")
        XCTAssertEqual(recipe.initrd, "/boot/initramfs-virt")
        XCTAssertEqual(recipe.commandLine, "modules=loop,squashfs quiet")
    }

    /// **Une recette sans initramfs rend `nil`, pas une chaîne vide.**
    ///
    /// La frontière transmet un champ vide ; c'est ici qu'il redevient une
    /// absence. Laisser passer `""` ferait chercher un fichier nommé par rien.
    func testAMissingInitramfsBecomesNothing() throws {
        let image = try write(gravure(withInitrd: false))
        defer { try? FileManager.default.removeItem(at: image) }
        let recipe = try XCTUnwrap(IsoImage.recipe(of: image))
        XCTAssertNil(recipe.initrd)
        XCTAssertEqual(recipe.kernel, "/boot/vmlinuz-virt")
    }

    /// Ce qui n'est pas une image se refuse, sans rien inventer.
    func testWhatIsNotAnImageIsRefused() throws {
        let notAnImage = FileManager.default.temporaryDirectory
            .appendingPathComponent("wisq-pas-une-image-\(getpid())")
        try Data("CD001, presque".utf8).write(to: notAnImage)
        defer { try? FileManager.default.removeItem(at: notAnImage) }
        XCTAssertNil(IsoImage.recipe(of: notAnImage))
        XCTAssertNil(IsoImage.recipe(of: notAnImage.appendingPathComponent("absent")))
    }

    /// **Un membre ressort octet pour octet.**
    func testAMemberComesOutWhole() throws {
        let image = try write(gravure())
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("wisq-extrait-\(getpid())")
        defer {
            try? FileManager.default.removeItem(at: image)
            try? FileManager.default.removeItem(at: destination)
        }
        XCTAssertTrue(
            IsoImage.extract("/boot/vmlinuz-virt", from: image, to: destination, ceiling: 1 << 20))
        XCTAssertEqual(try Data(contentsOf: destination), Self.kernel)
    }

    /// **Sous le plafond, refus — et rien sur le disque.**
    ///
    /// L'ABI laisse le fichier incomplet : elle ne décide pas à la place de qui
    /// l'a nommé. C'est ce pont-ci qui décide, et il efface. Un reste tronqué
    /// sur le disque d'un téléphone se ferait prendre pour un noyau au
    /// démarrage suivant.
    func testBelowTheCeilingNothingIsLeftBehind() throws {
        let image = try write(gravure())
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("wisq-jamais-\(getpid())")
        defer {
            try? FileManager.default.removeItem(at: image)
            try? FileManager.default.removeItem(at: destination)
        }
        XCTAssertFalse(
            IsoImage.extract(
                "/boot/vmlinuz-virt", from: image, to: destination,
                ceiling: UInt64(Self.kernel.count - 1)))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: destination.path),
            "un noyau à moitié extrait se charge, et meurt ailleurs")
    }

    /// Un membre absent se refuse comme le reste.
    func testAMemberThatIsNotThereIsRefused() throws {
        let image = try write(gravure())
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("wisq-absent-\(getpid())")
        defer {
            try? FileManager.default.removeItem(at: image)
            try? FileManager.default.removeItem(at: destination)
        }
        XCTAssertFalse(
            IsoImage.extract("/boot/rien-du-tout", from: image, to: destination, ceiling: 1 << 20))
    }

    /// **Une copie qui échoue en chemin ne laisse rien derrière elle.**
    ///
    /// Ce test-ci vient d'un sabotage qui a survécu. Le précédent — le plafond
    /// — refuse **avant** que l'ABI ne crée le fichier, donc il ne peut pas
    /// voir si on efface. Il faut un échec **après** la création : une image
    /// tronquée, dont l'enregistrement promet trois mille octets que le
    /// fichier ne porte plus.
    ///
    /// Sans l'effacement, il reste un fichier vide portant le nom d'un noyau.
    /// Sur le disque d'un téléphone, il se ferait prendre pour un noyau au
    /// démarrage suivant.
    func testACopyThatFailsPartwayLeavesNothingBehind() throws {
        // Le noyau est gravé en dernier : couper la fin ne coupe que lui, et
        // l'image s'ouvre encore.
        let whole = gravure()
        let image = try write(whole.prefix(whole.count - 2048))
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("wisq-tronque-\(getpid())")
        defer {
            try? FileManager.default.removeItem(at: image)
            try? FileManager.default.removeItem(at: destination)
        }
        // L'image reste lisible : c'est bien la copie qui échoue, pas
        // l'ouverture — sinon ce test ne vérifierait pas ce qu'il croit.
        XCTAssertNotNil(IsoImage.recipe(of: image), "l'image tronquée s'ouvre encore")
        XCTAssertFalse(
            IsoImage.extract("/boot/vmlinuz-virt", from: image, to: destination, ceiling: 1 << 20))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: destination.path),
            "un fichier vide portant le nom d'un noyau se ferait prendre pour un noyau")
    }
}
