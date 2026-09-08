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
/// **Une duplication assumée, et dite** : l'image d'essai est gravée ici, en
/// plus de celle des tests Rust et de celle du harnais d'ABI. C'est le
/// gréement, pas le lecteur — celui-ci n'existe qu'en un seul exemplaire, en
/// Rust. Chaque langue doit pouvoir en poser une sur le disque, et une image
/// fausse fait tomber le test bruyamment plutôt que passer en silence.
final class IsoImageTests: XCTestCase {
    private static let sector = 2048

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

    // MARK: - L'image d'essai

    /// Le noyau que l'image porte : un motif reconnaissable, pour qu'une
    /// lecture au mauvais secteur se voie.
    private static let kernel = Data((0..<3000).map { UInt8($0 % 251) })

    private func write<Bytes: DataProtocol>(_ bytes: Bytes) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wisq-essai-\(getpid())-\(UUID().uuidString).iso")
        try Data(bytes).write(to: url)
        return url
    }

    private func both32(_ value: UInt32) -> [UInt8] {
        withUnsafeBytes(of: value.littleEndian, Array.init)
            + withUnsafeBytes(of: value.bigEndian, Array.init)
    }

    private func both16(_ value: UInt16) -> [UInt8] {
        withUnsafeBytes(of: value.littleEndian, Array.init)
            + withUnsafeBytes(of: value.bigEndian, Array.init)
    }

    private func record(
        lba: UInt32, size: UInt32, directory: Bool, name: [UInt8], rock: String?
    ) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 33)
        out.replaceSubrange(2..<10, with: both32(lba))
        out.replaceSubrange(10..<18, with: both32(size))
        out[25] = directory ? 2 : 0
        out.replaceSubrange(28..<32, with: both16(1))
        out[32] = UInt8(name.count)
        out += name
        // Un octet de bourrage quand la longueur du nom est paire, pour que la
        // zone d'usage système commence sur un mot.
        if name.count % 2 == 0 { out.append(0) }
        if let rock {
            out += Array("NM".utf8)
            out.append(UInt8(5 + rock.utf8.count))
            out.append(1)
            out.append(0)
            out += Array(rock.utf8)
        }
        out[0] = UInt8(out.count)
        return out
    }

    private func directory(own: UInt32, children: [[UInt8]]) -> [UInt8] {
        var out = record(
            lba: own, size: UInt32(Self.sector), directory: true, name: [0], rock: nil)
        out += record(lba: 0, size: UInt32(Self.sector), directory: true, name: [1], rock: nil)
        for child in children { out += child }
        return out
    }

    /// L'image, gravée secteur par secteur. Volontairement pauvre : ni
    /// bourrage, ni entrée de chargeur, ni intrus — ces cas-là sont jugés du
    /// côté Rust, où vit le lecteur.
    private func gravure(withInitrd: Bool = true) -> Data {
        var sectors = [[UInt8]](repeating: [UInt8](repeating: 0, count: Self.sector), count: 18)

        func push(_ bytes: [UInt8]) -> (lba: UInt32, size: UInt32) {
            let lba = UInt32(sectors.count)
            var at = 0
            while at < bytes.count {
                var sector = [UInt8](repeating: 0, count: Self.sector)
                let end = min(at + Self.sector, bytes.count)
                sector.replaceSubrange(0..<(end - at), with: bytes[at..<end])
                sectors.append(sector)
                at = end
            }
            return (lba, UInt32(bytes.count))
        }

        // **Le noyau est gravé en dernier**, et son adresse est promise ici.
        // C'est ce qui permet de tronquer l'image sans emporter les
        // répertoires : sans ça, une image coupée n'ouvrirait même pas, et le
        // test de l'effacement ne pourrait pas exister.
        let kernelLBA: UInt32 = 23
        let initrd = push([0x1f, 0x8b, 0x08, 0x00])
        let recipeText =
            withInitrd
            ? "DEFAULT virt\nLABEL virt\n  KERNEL /boot/vmlinuz-virt\n  INITRD /boot/initramfs-virt\n  APPEND modules=loop,squashfs quiet\n"
            : "DEFAULT virt\nLABEL virt\n  KERNEL /boot/vmlinuz-virt\n  APPEND modules=loop,squashfs quiet\n"
        let recipe = push(Array(recipeText.utf8))

        let syslinuxLBA = UInt32(sectors.count)
        let syslinux = directory(
            own: syslinuxLBA,
            children: [
                record(
                    lba: recipe.lba, size: recipe.size, directory: false,
                    name: Array("SYSLINUX.CFG;1".utf8), rock: "syslinux.cfg")
            ])
        let syslinuxAt = push(syslinux)

        let bootLBA = UInt32(sectors.count)
        var children = [
            record(
                lba: kernelLBA, size: UInt32(Self.kernel.count), directory: false,
                name: Array("VMLINUZ_.VIR;1".utf8), rock: "vmlinuz-virt"),
            record(
                lba: syslinuxAt.lba, size: UInt32(Self.sector), directory: true,
                name: Array("SYSLINUX".utf8), rock: nil),
        ]
        if withInitrd {
            children.insert(
                record(
                    lba: initrd.lba, size: initrd.size, directory: false,
                    name: Array("INITRAMF.VIR;1".utf8), rock: "initramfs-virt"), at: 1)
        }
        let bootAt = push(directory(own: bootLBA, children: children))

        let rootLBA = UInt32(sectors.count)
        let rootAt = push(
            directory(
                own: rootLBA,
                children: [
                    record(
                        lba: bootAt.lba, size: UInt32(Self.sector), directory: true,
                        name: Array("BOOT".utf8), rock: nil)
                ]))

        var pvd = [UInt8](repeating: 0, count: Self.sector)
        pvd[0] = 1
        pvd.replaceSubrange(1..<6, with: Array("CD001".utf8))
        pvd[6] = 1
        pvd.replaceSubrange(8..<40, with: [UInt8](repeating: 0x20, count: 32))
        pvd.replaceSubrange(40..<72, with: [UInt8](repeating: 0x20, count: 32))
        pvd.replaceSubrange(40..<48, with: Array("WISQPONT".utf8))
        pvd.replaceSubrange(80..<88, with: both32(UInt32(sectors.count)))
        pvd.replaceSubrange(128..<132, with: both16(UInt16(Self.sector)))
        let rootRecord = record(
            lba: rootAt.lba, size: UInt32(Self.sector), directory: true, name: [0], rock: nil)
        pvd.replaceSubrange(156..<(156 + rootRecord.count), with: rootRecord)
        sectors[16] = pvd

        var end = [UInt8](repeating: 0, count: Self.sector)
        end[0] = 255
        end.replaceSubrange(1..<6, with: Array("CD001".utf8))
        end[6] = 1
        sectors[17] = end

        // La promesse tenue. Un décalage ici donnerait une image dont le noyau
        // n'est pas là où son enregistrement le dit, et les tests tomberaient
        // sur le gréement plutôt que sur le pont.
        precondition(
            sectors.count == Int(kernelLBA),
            "le noyau doit être gravé au secteur promis, pas au \(sectors.count)")
        _ = push([UInt8](Self.kernel))

        return Data(sectors.flatMap { $0 })
    }
}
