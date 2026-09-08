import Foundation
import XCTest

import WisqVM

@testable import WisqVMRust

/// **Ce qu'on tire d'une image pour en démarrer une machine.**
///
/// Le lecteur sait déjà lire une recette et sortir un membre ; ce fichier-ci
/// juge la décision qui en découle — quel noyau charger, avec quelle ligne de
/// commande, et **quand refuser**.
///
/// Le refus est la moitié qui compte. Un noyau de PC chargé sans son initramfs
/// démarre entièrement, écrit deux cent soixante-deux lignes de journal, puis
/// s'arrête sur « VFS: Unable to mount root fs on unknown-block(0,0) ». La
/// personne voit une panne trois cents lignes après sa cause. Le dire avant de
/// démarrer vaut mieux que de le faire vivre.
///
/// **Et ces gardes-là ne se voient pas dans le verdict.** Que le dossier soit
/// vidé avant d'écrire, que les noms sur le disque ne viennent pas de l'image,
/// qu'un refus ne laisse rien derrière : dans chaque cas le plan rendu est le
/// même. Ce qui change est ce qui reste sur le disque — donc c'est cela qu'on
/// regarde.
final class IsoBootTests: XCTestCase {
    private var folder = URL(fileURLWithPath: "/")

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("wisq-deballage-\(getpid())-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// Ce que le dossier porte, trié — le vrai état du disque, pas ce qu'on
    /// croit y avoir mis.
    private func onDisk() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }

    /// **Un refus inattendu tombe, il ne se saute pas.** Le premier jet de ce
    /// fichier levait un `XCTSkip` ici : un déballage cassé aurait rendu « 10
    /// tests, 0 échec » en n'ayant rien vérifié du tout.
    private func plan(_ result: Result<IsoBoot.Plan, IsoBoot.Refusal>) throws -> IsoBoot.Plan {
        switch result {
        case .success(let plan): return plan
        case .failure(let refusal): throw refusal
        }
    }

    /// **Le noyau qui démarre est celui qui était dans l'image.**
    ///
    /// Pas l'image elle-même : c'est tout le branchement en une assertion. Les
    /// octets sont comparés, pas la taille — une extraction décalée d'un
    /// secteur donnerait le bon nombre d'octets et le mauvais noyau.
    func testTheKernelThatBootsIsTheOneInsideTheImage() throws {
        let image = try IsoGravure().write()
        defer { try? FileManager.default.removeItem(at: image) }

        let plan = try plan(IsoBoot.unpack(image, into: folder, ceiling: 1 << 20))
        XCTAssertNotEqual(plan.kernel, image, "c'est le noyau extrait qui démarre, pas l'image")
        XCTAssertEqual(try Data(contentsOf: plan.kernel), IsoGravure.kernel)
        let initrd = try XCTUnwrap(plan.initrd)
        XCTAssertEqual(try Data(contentsOf: initrd), IsoGravure.initramfs)
    }

    /// **La ligne de commande est lue, pas inventée.**
    ///
    /// Une ligne fabriquée démarre un noyau qui ne trouve pas sa racine, et la
    /// panne tombe très loin de sa cause. Elle est comparée au caractère près :
    /// un `root=` perdu en chemin ne se voit nulle part ailleurs.
    func testTheCommandLineComesFromTheImage() throws {
        let ordered = "root=/dev/vda2 ro console=ttyS0 modules=loop,squashfs quiet"
        let image = try IsoGravure(commandLine: ordered).write()
        defer { try? FileManager.default.removeItem(at: image) }

        let plan = try plan(IsoBoot.unpack(image, into: folder, ceiling: 1 << 20))
        XCTAssertEqual(plan.commandLine, ordered)
        // D'où elle vient, pour que la console puisse le nommer quand un
        // démarrage tourne mal.
        XCTAssertEqual(plan.recipe, "/boot/syslinux/syslinux.cfg")
    }

    /// Une recette sans initramfs démarre quand même : un noyau qui porte ses
    /// pilotes existe, et refuser serait une supposition de plus.
    func testARecipeWithoutAnInitramfsStillBoots() throws {
        let image = try IsoGravure(recipeInitrd: nil, carriesInitrd: false).write()
        defer { try? FileManager.default.removeItem(at: image) }

        let plan = try plan(IsoBoot.unpack(image, into: folder, ceiling: 1 << 20))
        XCTAssertNil(plan.initrd)
        XCTAssertEqual(try Data(contentsOf: plan.kernel), IsoGravure.kernel)
        XCTAssertEqual(onDisk(), ["vmlinuz"], "rien d'autre n'a été écrit")
    }

    /// **Un initramfs promis et absent est un refus, pas un démarrage.**
    ///
    /// C'est le cas qui vaut la tranche : sans lui, la machine démarre et meurt
    /// trois cents lignes plus loin sur sa racine.
    func testAnInitramfsPromisedAndAbsentIsRefused() throws {
        let image = try IsoGravure(carriesInitrd: false).write()
        defer { try? FileManager.default.removeItem(at: image) }

        switch IsoBoot.unpack(image, into: folder, ceiling: 1 << 20) {
        case .success(let plan):
            XCTFail("démarré sans l'initramfs que la recette promet : \(plan)")
        case .failure(let refusal):
            XCTAssertEqual(refusal, .cannotExtractInitrd("/boot/initramfs-virt"))
        }
        // **Et le noyau déjà sorti ne reste pas.** Un `vmlinuz` seul sur le
        // disque du téléphone se ferait prendre pour un noyau importé.
        XCTAssertEqual(onDisk(), [], "un refus ne laisse rien derrière lui")
    }

    /// Le noyau que la recette nomme, absent de l'image : refus qui le nomme.
    func testAKernelPromisedAndAbsentIsRefused() throws {
        let image = try IsoGravure(carriesKernel: false).write()
        defer { try? FileManager.default.removeItem(at: image) }

        switch IsoBoot.unpack(image, into: folder, ceiling: 1 << 20) {
        case .success: XCTFail("démarré sans noyau")
        case .failure(let refusal):
            XCTAssertEqual(refusal, .cannotExtractKernel("/boot/vmlinuz-virt"))
        }
        XCTAssertEqual(onDisk(), [])
    }

    /// Ce qui n'est pas une image, et ce qui n'en porte aucune recette,
    /// donnent le même refus — l'appelant en fait la même chose.
    func testWhatCarriesNoRecipeIsRefused() throws {
        let notAnImage = folder.deletingLastPathComponent()
            .appendingPathComponent("wisq-pas-une-image-\(getpid())")
        try Data("CD001, presque".utf8).write(to: notAnImage)
        defer { try? FileManager.default.removeItem(at: notAnImage) }

        switch IsoBoot.unpack(notAnImage, into: folder, ceiling: 1 << 20) {
        case .success: XCTFail("une recette a été inventée")
        case .failure(let refusal): XCTAssertEqual(refusal, .noRecipe)
        }
    }

    /// **Aucun nom sur le disque ne vient de l'image.**
    ///
    /// Les chemins de la recette sont écrits par qui a gravé l'image, et ce
    /// n'est pas nous. S'ils décidaient où les octets atterrissent, un
    /// `../../` bien placé écrirait ailleurs que dans ce dossier. Les deux
    /// noms sont fixes et posés ici : la garde est dans la forme, pas dans un
    /// filtre qu'il faudrait tenir à jour.
    func testNoNameOnDiskComesFromTheImage() throws {
        let image = try IsoGravure(
            recipeKernel: "/boot/vmlinuz-virt", recipeInitrd: "/boot/initramfs-virt"
        ).write()
        defer { try? FileManager.default.removeItem(at: image) }

        let plan = try plan(IsoBoot.unpack(image, into: folder, ceiling: 1 << 20))
        XCTAssertEqual(plan.kernel.deletingLastPathComponent().path, folder.path)
        XCTAssertEqual(plan.kernel.lastPathComponent, "vmlinuz")
        XCTAssertEqual(try XCTUnwrap(plan.initrd).lastPathComponent, "initramfs")
        XCTAssertEqual(onDisk(), ["initramfs", "vmlinuz"])
    }

    /// **Ce qu'un déballage précédent a laissé ne survit pas au suivant.**
    ///
    /// C'est la garde la plus discrète et la plus dangereuse à perdre : sans
    /// elle, l'initramfs d'une image chargerait avec le noyau d'une autre.
    /// Rien dans le verdict ne le dirait — le plan rendu est le même.
    func testWhatAPreviousUnpackLeftDoesNotSurvive() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("l'initramfs d'une autre image".utf8)
            .write(to: folder.appendingPathComponent("initramfs"))
        try Data("un noyau d'une autre image".utf8)
            .write(to: folder.appendingPathComponent("vmlinuz"))

        let image = try IsoGravure(recipeInitrd: nil, carriesInitrd: false).write()
        defer { try? FileManager.default.removeItem(at: image) }

        let plan = try plan(IsoBoot.unpack(image, into: folder, ceiling: 1 << 20))
        XCTAssertNil(plan.initrd)
        XCTAssertEqual(onDisk(), ["vmlinuz"], "l'initramfs de l'image précédente est parti")
        XCTAssertEqual(try Data(contentsOf: plan.kernel), IsoGravure.kernel)
    }

    /// Le plafond refuse avant d'écrire, et le dossier reste vide.
    func testTheCeilingRefusesAndLeavesNothing() throws {
        let image = try IsoGravure().write()
        defer { try? FileManager.default.removeItem(at: image) }

        switch IsoBoot.unpack(
            image, into: folder, ceiling: UInt64(IsoGravure.kernel.count - 1)) {
        case .success: XCTFail("un noyau plus gros que le plafond est passé")
        case .failure(let refusal):
            XCTAssertEqual(refusal, .cannotExtractKernel("/boot/vmlinuz-virt"))
        }
        XCTAssertEqual(onDisk(), [])
    }

    /// **Le refus dit ce qui s'est passé, sans inventer pourquoi.**
    ///
    /// wisq ne sait pas distinguer « ce membre n'est pas dans l'image » de
    /// « il dépasse le plafond » — la frontière rend un seul échec. Écrire
    /// « l'image ne le contient pas » serait une cause fabriquée, et enverrait
    /// chercher une autre image quand le problème est la mémoire.
    func testTheRefusalNamesWithoutInventing() {
        let said = IsoBoot.explanation(
            .cannotExtractInitrd("/boot/initramfs-virt"), name: "alpine-virt-3.20.3.iso")
        XCTAssertTrue(said.contains("alpine-virt-3.20.3.iso"), said)
        XCTAssertTrue(said.contains("/boot/initramfs-virt"), said)
        XCTAssertFalse(said.contains("ne contient pas"), "cause fabriquée : \(said)")

        let none = IsoBoot.explanation(.noRecipe, name: "quelconque.iso")
        XCTAssertTrue(none.contains("quelconque.iso"), none)
    }
}

/// **La décision que le modèle de vue prend, prise ici.**
///
/// `WisqUI` vit derrière `#if os(iOS)` : seule la CI d'Apple le compile, et
/// aucun test de ce dépôt ne l'exécute. Ce qui se décide là-bas n'est donc
/// tenu par rien. C'est pour ça que la décision est ici — jugée par la CI
/// Linux à chaque commit — et que le modèle n'en garde qu'une liaison de
/// champs.
final class IsoBootDecisionTests: XCTestCase {
    private var folder = URL(fileURLWithPath: "/")

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("wisq-decision-\(getpid())-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// **Un fichier qui n'est pas une image traverse sans être touché.**
    ///
    /// Pas de dossier créé, pas un octet écrit : le déballage est une branche,
    /// et un noyau importé normalement ne doit pas en payer le prix.
    func testAPlainKernelPassesThroughUntouched() throws {
        let kernel = FileManager.default.temporaryDirectory
            .appendingPathComponent("wisq-noyau-\(getpid())-\(UUID().uuidString)")
        // Un bzImage : la signature que le reconnaisseur cherche au bon décalage.
        var bytes = [UInt8](repeating: 0, count: 1024)
        bytes.replaceSubrange(514..<518, with: Array("HdrS".utf8))
        try Data(bytes).write(to: kernel)
        defer { try? FileManager.default.removeItem(at: kernel) }

        switch IsoBoot.decide(kernel, into: folder, ceiling: 1 << 20) {
        case .failure(let refusal): XCTFail("refus sur un fichier ordinaire : \(refusal)")
        case .success(let boot):
            XCTAssertEqual(boot.kernel, kernel)
            XCTAssertNil(boot.disk, "rien à brancher comme disque")
            XCTAssertNil(boot.commandLine, "aucune ligne n'est inventée")
            XCTAssertNil(boot.initrd)
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: folder.path),
            "aucun dossier de déballage pour un fichier qui n'est pas une image")
    }

    /// **Sur une image, les quatre champs changent ensemble.**
    ///
    /// Le noyau devient celui de l'image, l'image devient le disque, la ligne
    /// de commande arrive, et le genre est celui du noyau **sorti** — pas
    /// celui de l'image, qui ferait refuser le démarrage une ligne plus loin.
    func testAnImageBecomesAKernelAndADisk() throws {
        let image = try IsoGravure(
            commandLine: "root=/dev/vda2 ro quiet"
        ).write()
        defer { try? FileManager.default.removeItem(at: image) }

        switch IsoBoot.decide(image, into: folder, ceiling: 1 << 20) {
        case .failure(let refusal): XCTFail("refus inattendu : \(refusal)")
        case .success(let boot):
            XCTAssertEqual(boot.disk, image, "l'image est le disque")
            XCTAssertNotEqual(boot.kernel, image, "et ce n'est pas elle qu'on exécute")
            XCTAssertEqual(try Data(contentsOf: boot.kernel), IsoGravure.kernel)
            XCTAssertEqual(boot.commandLine, "root=/dev/vda2 ro quiet")
            XCTAssertNotNil(boot.initrd)
            // Le noyau d'essai n'est pas un vrai bzImage : ce qui compte est
            // que le genre soit jugé sur **lui**, donc plus jamais `discImage`.
            if case .discImage = boot.kind {
                XCTFail("le genre est resté celui de l'image, le démarrage serait refusé")
            }
        }
    }

    /// Le refus de l'image remonte tel quel : la décision n'en fabrique pas
    /// un autre au passage.
    func testARefusalTravelsUnchanged() throws {
        let image = try IsoGravure(carriesInitrd: false).write()
        defer { try? FileManager.default.removeItem(at: image) }

        switch IsoBoot.decide(image, into: folder, ceiling: 1 << 20) {
        case .success: XCTFail("démarré sans l'initramfs promis")
        case .failure(let refusal):
            XCTAssertEqual(refusal, .cannotExtractInitrd("/boot/initramfs-virt"))
        }
    }
}

/// **Reprendre où l'on s'est arrêté, quand la machine vient d'une image.**
///
/// Une session sauvegardée est classée sous l'empreinte du noyau qu'elle
/// exécutait — pas sous son nom, parce que la moitié des noyaux importés
/// s'appellent `Image` et que le second reprendrait la machine du premier.
///
/// Or quand le noyau sort d'une image, il est **ré-extrait à chaque
/// démarrage**. Si cette extraction variait d'une fois sur l'autre — un octet,
/// un ordre — l'empreinte changerait, la session précédente ne serait plus
/// trouvée, et la personne perdrait son travail **en silence** : pas d'erreur,
/// juste une machine qui redémarre à zéro.
///
/// Rien dans le verdict d'un démarrage ne dirait ça. C'est pour ça que ce
/// test-ci existe.
final class IsoBootResumeTests: XCTestCase {
    private var folders: [URL] = []

    override func tearDownWithError() throws {
        for folder in folders { try? FileManager.default.removeItem(at: folder) }
        folders = []
    }

    private func freshFolder() -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("wisq-reprise-\(getpid())-\(UUID().uuidString)")
        folders.append(folder)
        return folder
    }

    func testTheSameImageAlwaysNamesTheSameMachine() throws {
        let image = try IsoGravure().write()
        defer { try? FileManager.default.removeItem(at: image) }

        // Deux démarrages, deux dossiers de déballage : exactement ce qui se
        // passe quand on quitte l'application et qu'on y revient.
        var identities: [String] = []
        var kernels: [Data] = []
        for _ in 0..<2 {
            switch IsoBoot.decide(image, into: freshFolder(), ceiling: 1 << 20) {
            case .failure(let refusal): XCTFail("refus inattendu : \(refusal)")
            case .success(let boot):
                let bytes = try Data(contentsOf: boot.kernel)
                kernels.append(bytes)
                identities.append(
                    SuspendedMachine.identity(of: bytes, named: image.lastPathComponent))
            }
        }
        XCTAssertEqual(kernels.count, 2)
        XCTAssertEqual(kernels[0], kernels[1], "le noyau extrait doit être le même octet pour octet")
        XCTAssertEqual(
            identities[0], identities[1],
            "l'empreinte change : la session précédente ne serait jamais retrouvée")
    }

    /// **Deux noyaux différents ne se partagent pas une machine sauvegardée.**
    ///
    /// Le cas réel : vous remplacez `linux.iso` par une version plus récente,
    /// du même nom. Si la session était classée sur le nom, l'instantané de
    /// l'ancien noyau serait rendu au nouveau — un état mémoire écrit par un
    /// programme, restauré dans un autre. C'est le noyau **extrait** qui
    /// signe, donc deux images de même nom mais de contenu différent ne se
    /// confondent pas.
    func testTwoKernelsUnderTheSameNameDoNotShareAMachine() throws {
        let one = try IsoGravure().write()
        let other = try IsoGravure(
            kernel: Data((0..<3000).map { UInt8(($0 &+ 7) % 251) })
        ).write()
        defer {
            try? FileManager.default.removeItem(at: one)
            try? FileManager.default.removeItem(at: other)
        }

        func identity(of image: URL) throws -> String {
            switch IsoBoot.decide(image, into: freshFolder(), ceiling: 1 << 20) {
            case .failure(let refusal): throw refusal
            case .success(let boot):
                // **Le même nom des deux côtés**, exprès : c'est le contenu
                // qui doit séparer, et rien d'autre.
                return SuspendedMachine.identity(
                    of: try Data(contentsOf: boot.kernel), named: "linux.iso")
            }
        }
        XCTAssertNotEqual(
            try identity(of: one), try identity(of: other),
            "un instantané écrit par un noyau serait rendu à un autre")
    }
}
