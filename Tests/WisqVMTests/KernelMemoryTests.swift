import XCTest

@testable import WisqVM

/// Le réglage de mémoire, tel qu'il survit à un lancement et à un changement
/// de téléphone.
final class KernelMemoryTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wisq-memoire-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// Un premier lancement : rien d'enregistré, donc la machine de référence.
    func testWithNothingRecordedAKernelGetsTheReferenceMachine() {
        XCTAssertEqual(
            KernelMemory.size(forKernel: "Image", in: folder), LinuxMachine.defaultRAMSize)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: folder.appendingPathComponent(KernelMemory.fileName).path),
            "aucun fichier ne doit être créé par une simple lecture")
    }

    /// Un choix survit, et n'appartient qu'à son noyau.
    func testAChoiceIsRememberedForItsOwnKernelOnly() {
        KernelMemory.setSize(256 << 20, forKernel: "Image", in: folder)
        XCTAssertEqual(KernelMemory.size(forKernel: "Image", in: folder), 256 << 20)
        XCTAssertEqual(
            KernelMemory.size(forKernel: "autre-noyau", in: folder),
            LinuxMachine.defaultRAMSize,
            "le réglage d'un noyau ne doit pas s'appliquer à un autre")
    }

    /// Revenir au défaut efface l'entrée plutôt que d'écrire le nombre : un
    /// fichier qui ne contient que les écarts au défaut reste lisible.
    func testGoingBackToTheDefaultRemovesTheEntry() {
        KernelMemory.setSize(128 << 20, forKernel: "Image", in: folder)
        KernelMemory.setSize(LinuxMachine.defaultRAMSize, forKernel: "Image", in: folder)
        XCTAssertEqual(KernelMemory.size(forKernel: "Image", in: folder), LinuxMachine.defaultRAMSize)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: folder.appendingPathComponent(KernelMemory.fileName).path),
            "le dernier écart retiré doit emporter le fichier")
    }

    /// Un noyau supprimé emporte son réglage.
    func testForgettingAKernelRemovesItsChoice() {
        KernelMemory.setSize(128 << 20, forKernel: "Image", in: folder)
        KernelMemory.setSize(256 << 20, forKernel: "garde", in: folder)
        KernelMemory.forget(kernel: "Image", in: folder)
        XCTAssertEqual(KernelMemory.size(forKernel: "Image", in: folder), LinuxMachine.defaultRAMSize)
        XCTAssertEqual(
            KernelMemory.size(forKernel: "garde", in: folder), 256 << 20,
            "oublier un noyau ne doit pas emporter les autres")
    }

    /// Le téléphone remplacé par un plus petit : le choix enregistré est
    /// **rogné**, pas honoré. Une application qui meurt au lancement parce
    /// qu'un fichier se souvient d'un choix que le matériel ne peut pas tenir
    /// est pire qu'une qui tourne plus petit sans rien dire.
    func testARecordedSizeAboveTheDeviceCeilingIsClamped() {
        KernelMemory.setSize(1024 << 20, forKernel: "Image", in: folder)
        XCTAssertEqual(
            KernelMemory.size(forKernel: "Image", in: folder, ceiling: 128 << 20),
            128 << 20)
        XCTAssertEqual(
            KernelMemory.size(forKernel: "Image", in: folder, ceiling: 1024 << 20),
            1024 << 20,
            "et honoré quand la machine peut le tenir")
    }

    /// Une valeur qui n'est pas dans la liste offerte n'est ni écrite ni lue.
    /// Le seul appelant est un sélecteur construit sur `offered` ; une autre
    /// provenance est un défaut, pas une donnée à encoder.
    func testAnUnofferedSizeIsRefusedOnBothSides() throws {
        KernelMemory.setSize(1_000_000, forKernel: "Image", in: folder)
        XCTAssertEqual(KernelMemory.size(forKernel: "Image", in: folder), LinuxMachine.defaultRAMSize)

        // Et écrit à la main dans le fichier, il est ignoré à la lecture.
        let url = folder.appendingPathComponent(KernelMemory.fileName)
        try Data(#"{"Image":1000000}"#.utf8).write(to: url)
        XCTAssertEqual(KernelMemory.size(forKernel: "Image", in: folder), LinuxMachine.defaultRAMSize)
    }

    /// Un fichier illisible se lit comme « aucun choix », pas comme une panne :
    /// le pire résultat est que chaque noyau tourne à la taille de référence,
    /// ce qu'il faisait avant que ce réglage existe.
    func testAnUnreadableFileReadsAsNoChoices() throws {
        let url = folder.appendingPathComponent(KernelMemory.fileName)
        try Data("ceci n'est pas du JSON".utf8).write(to: url)
        XCTAssertEqual(KernelMemory.size(forKernel: "Image", in: folder), LinuxMachine.defaultRAMSize)
    }

    /// Le plafond : un huitième de la mémoire physique, borné par ce que
    /// l'architecture permet, et jamais sous la machine de référence.
    ///
    /// Les trois bords, avec les téléphones réels derrière. Le plancher compte
    /// autant que le plafond : sans lui, la machine par défaut deviendrait
    /// impossible sur un appareil où elle a toujours marché.
    func testTheCeilingIsAnEighthCappedAndFloored() {
        // 2 Go — le plus petit appareil sous iOS 17 : 256 Mo.
        XCTAssertEqual(KernelMemory.ceiling(physicalMemory: 2048 << 20), 256 << 20)
        // 6 Go — un téléphone récent : 768 Mo, sous le plafond.
        XCTAssertEqual(KernelMemory.ceiling(physicalMemory: 6144 << 20), 768 << 20)
        // 16 Go — un iPad : le huitième fait 2 Gio, exactement ce que le
        // processeur 32 bits de l'invité peut adresser. Le plafond était écrit
        // « un gibioctet » et coïncidait donc avec cette limite par accident,
        // ce qui faisait passer une contrainte d'architecture pour un choix.
        XCTAssertEqual(
            KernelMemory.ceiling(physicalMemory: 16384 << 20), LinuxMachine.maximumRAMSize)
        // 64 Go — un Mac : le huitième ferait 8 Gio, la limite tient.
        XCTAssertEqual(
            KernelMemory.ceiling(physicalMemory: 65536 << 20), LinuxMachine.maximumRAMSize)
        // Le plancher : un huitième de 256 Mo vaut 32 Mo, la référence gagne.
        XCTAssertEqual(KernelMemory.ceiling(physicalMemory: 256 << 20), LinuxMachine.defaultRAMSize)
        // Et jamais nul, même sur une valeur absurde.
        XCTAssertEqual(KernelMemory.ceiling(physicalMemory: 0), LinuxMachine.defaultRAMSize)
        // Monotone.
        var previous: UInt32 = 0
        for gigabytes in [1, 2, 3, 4, 6, 8, 12, 16, 32] {
            let limit = KernelMemory.ceiling(physicalMemory: UInt64(gigabytes) << 30)
            XCTAssertGreaterThanOrEqual(limit, previous, "\(gigabytes) Go")
            previous = limit
        }
    }

    /// Ce qu'on propose est ce que l'appareil peut tenir, et la référence y est
    /// toujours — un sélecteur sans le réglage par défaut serait un piège.
    func testWhatIsOfferedFitsUnderTheCeilingAndAlwaysHoldsTheDefault() {
        for physical: UInt64 in [1024 << 20, 2048 << 20, 4096 << 20, 8192 << 20] {
            let limit = KernelMemory.ceiling(physicalMemory: physical)
            let offered = KernelMemory.offered(ceiling: limit)
            XCTAssertFalse(offered.isEmpty, "\(physical >> 20) Mo physiques")
            XCTAssertTrue(
                offered.contains(LinuxMachine.defaultRAMSize),
                "la machine de référence doit toujours être proposée")
            for size in offered {
                XCTAssertLessThanOrEqual(size, limit)
                XCTAssertTrue(KernelMemory.choices.contains(size))
            }
            XCTAssertEqual(offered, offered.sorted(), "la liste doit rester ordonnée")
        }
    }

    /// Ce qu'on accepte à l'import est jugé sur la plus grande machine que
    /// l'appareil autorise, pas sur le réglage du noyau — qui n'existe pas
    /// encore au moment où le fichier arrive. Refuser sur le défaut refuserait
    /// un fichier importé exprès pour tourner plus grand.
    func testTheImportCeilingIsTheLargestMachineTheDeviceAllows() {
        for limit in [64 << 20, 256 << 20, 1024 << 20] as [UInt32] {
            XCTAssertEqual(
                KernelMemory.maximumImportableImageBytes(ceiling: limit),
                LinuxMachine.maximumKernelImageBytes(forRAMSize: limit),
                "\(limit >> 20) Mo")
        }
        // Et il est strictement plus large que le plafond du défaut dès que
        // l'appareil autorise plus : sinon le réglage ne servirait à rien,
        // puisque le fichier serait refusé avant d'être réglé.
        XCTAssertGreaterThan(
            KernelMemory.maximumImportableImageBytes(ceiling: 256 << 20),
            KernelMemory.maximumImportableImageBytes(ceiling: LinuxMachine.defaultRAMSize))
    }

    /// Et chaque taille offerte fait vraiment une machine qui démarre : une
    /// liste de nombres qu'aucune machine n'accepte serait un réglage décoratif.
    func testEveryOfferedSizeBuildsAMachineThatAcceptsAKernel() throws {
        for size in KernelMemory.offered(ceiling: 1024 << 20) {
            let machine = LinuxMachine(ramSize: size) { _ in }
            XCTAssertEqual(machine.ramSize, size)
            XCTAssertGreaterThan(machine.maximumKernelImageBytes, 0, "\(size >> 20) Mo")
            XCTAssertNoThrow(
                try machine.load(kernelImage: Data([0x13, 0x00, 0x00, 0x00])),
                "\(size >> 20) Mo : une machine offerte doit accepter un noyau")
            XCTAssertEqual(
                Int(DefaultDTB.declaredMemory(in: machine.deviceTreeHandedToTheGuest)),
                Int(size) - DefaultDTB.memoryTopReserve,
                "\(size >> 20) Mo : l'invité doit apprendre la taille choisie")
        }
    }
}

/// Oublier les machines sauvegardées d'un noyau, par son nom.
///
/// C'est ce qu'un changement de taille doit faire : un instantané pris à une
/// autre taille **ne peut pas** être restauré — les deux cœurs refusent
/// l'écart — donc le laisser sur le disque est laisser un fichier que rien ne
/// relira jamais.
final class ForgettingSavedMachinesTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wisq-oubli-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func save(_ bytes: [UInt8], named name: String) throws -> String {
        let image = Data(bytes)
        let identity = SuspendedMachine.identity(of: image, named: name)
        try SuspendedMachine.save(Data([0xAA]), kernel: identity, in: folder)
        return identity
    }

    /// Deux fichiers différents portant le même nom : les deux sont oubliés,
    /// et on n'a lu aucun octet d'image pour le savoir.
    func testEveryMachineFromOneNameIsForgotten() throws {
        let first = try save([1, 2, 3], named: "Image")
        let second = try save([4, 5, 6], named: "Image")
        XCTAssertNotEqual(first, second, "deux images différentes, deux identités")
        XCTAssertTrue(SuspendedMachine.exists(kernel: first, in: folder))
        XCTAssertTrue(SuspendedMachine.exists(kernel: second, in: folder))

        XCTAssertEqual(SuspendedMachine.clearAll(named: "Image", in: folder), 2)
        XCTAssertFalse(SuspendedMachine.exists(kernel: first, in: folder))
        XCTAssertFalse(SuspendedMachine.exists(kernel: second, in: folder))
    }

    /// Et rien d'autre. Le piège est réel : `machine-Image-2-ff.wisqvm`
    /// commence par `machine-Image-`, donc un simple test de préfixe oublierait
    /// « Image-2 » en croyant oublier « Image ».
    func testANameThatIsAPrefixOfAnotherIsLeftAlone() throws {
        let target = try save([1], named: "Image")
        let neighbour = try save([1], named: "Image-2")
        let unrelated = try save([1], named: "vmlinux")

        XCTAssertEqual(SuspendedMachine.clearAll(named: "Image", in: folder), 1)
        XCTAssertFalse(SuspendedMachine.exists(kernel: target, in: folder))
        XCTAssertTrue(
            SuspendedMachine.exists(kernel: neighbour, in: folder),
            "« Image-2 » n'est pas « Image »")
        XCTAssertTrue(SuspendedMachine.exists(kernel: unrelated, in: folder))
    }

    /// Un nom sans machine sauvegardée ne coûte rien et ne dit pas le
    /// contraire : le compte rendu est ce qui permet de dire quelque chose de
    /// vrai à qui vient de faire le geste.
    func testForgettingNothingReportsNothing() {
        XCTAssertEqual(SuspendedMachine.clearAll(named: "jamais-vu", in: folder), 0)
    }

    /// Un fichier étranger dans le même répertoire survit — le réglage de
    /// mémoire vit là aussi.
    func testTheDirectoryIsNotSweptClean() throws {
        let saved = try save([1], named: "Image")
        KernelMemory.setSize(128 << 20, forKernel: "Image", in: folder)
        XCTAssertEqual(SuspendedMachine.clearAll(named: "Image", in: folder), 1)
        XCTAssertFalse(SuspendedMachine.exists(kernel: saved, in: folder))
        XCTAssertEqual(
            KernelMemory.size(forKernel: "Image", in: folder), 128 << 20,
            "oublier une machine ne doit pas oublier le réglage")
    }
}

/// La limite que l'architecture impose, et qui n'est pas une politique.
///
/// La mémoire de l'invité commence à `0x8000_0000` et son processeur adresse
/// en trente-deux bits : deux gibioctets tombent exactement sur le dernier
/// octet possible (`0x8000_0000 + 2 Gio == 2^32`), un de plus n'a nulle part
/// où vivre.
///
/// Ce test existe parce que l'échec était **silencieux**. Mesuré avant d'être
/// corrigé : une machine de trois gibioctets se chargeait sans se plaindre,
/// annonçait 3 221 209 088 octets dans son device tree, puis ne produisait
/// rien du tout — ni bannière, ni console, ni erreur.
final class ArchitecturalMemoryLimitTests: XCTestCase {
    /// La limite est bien le dernier octet adressable, calculée plutôt que
    /// réaffirmée.
    func testTheLimitIsWhereTheAddressSpaceEnds() {
        let end = UInt64(RV32Core.ramBase) + UInt64(LinuxMachine.maximumRAMSize)
        XCTAssertEqual(end, 0x1_0000_0000, "le dernier octet doit être 0xFFFF_FFFF")
        XCTAssertGreaterThan(
            UInt64(RV32Core.ramBase) + UInt64(LinuxMachine.maximumRAMSize) + 1,
            0x1_0000_0000, "un octet de plus doit déborder")
    }

    /// Une machine plus grande est refusée, pas construite en silence.
    func testAMachineLargerThanTheAddressSpaceIsRefused() throws {
        let image = Data([0x13, 0x00, 0x00, 0x00])
        let tooLarge = LinuxMachine(ramSize: 3 * 1024 * 1024 * 1024) { _ in }
        XCTAssertThrowsError(try tooLarge.load(kernelImage: image)) { error in
            XCTAssertEqual(error as? LinuxMachineError, .ramSizeUnsupported)
        }
        // Et le bord exact est accepté : refuser 2 Gio serait aussi faux.
        let atTheLimit = LinuxMachine(ramSize: LinuxMachine.maximumRAMSize) { _ in }
        XCTAssertNoThrow(try atTheLimit.load(kernelImage: image))
    }

    /// Rien de ce que l'application propose ne peut dépasser cette limite —
    /// ni la liste des choix, ni le plafond de l'appareil le plus généreux.
    func testNothingOfferedCanExceedIt() {
        for size in KernelMemory.choices {
            XCTAssertLessThanOrEqual(size, LinuxMachine.maximumRAMSize)
        }
        XCTAssertEqual(
            KernelMemory.choices.last, LinuxMachine.maximumRAMSize,
            "le dernier palier doit être la limite, sinon elle est inatteignable")
        for physical: UInt64 in [8 << 30, 16 << 30, 64 << 30, .max / 2] {
            XCTAssertLessThanOrEqual(
                KernelMemory.ceiling(physicalMemory: physical),
                LinuxMachine.maximumRAMSize,
                "\(physical >> 30) Gio physiques")
        }
    }

    /// Et un appareil assez grand atteint vraiment les gigaoctets : c'est
    /// l'appareil qui borne, pas l'unité.
    func testALargeDeviceReachesGibibytes() {
        XCTAssertEqual(KernelMemory.ceiling(physicalMemory: 8 << 30), 1024 << 20)
        XCTAssertEqual(
            KernelMemory.ceiling(physicalMemory: 16 << 30), LinuxMachine.maximumRAMSize)
        XCTAssertTrue(
            KernelMemory.offered(ceiling: KernelMemory.ceiling(physicalMemory: 8 << 30))
                .contains(1024 << 20))
    }

    /// Les tailles se lisent en gigaoctets dès qu'elles en sont.
    ///
    /// « 1024 Mo » est ce que le plus grand choix affichait, et c'est
    /// exactement ainsi qu'un réglage qui atteint le gibioctet passe pour un
    /// réglage qui s'arrête aux mégaoctets.
    func testSizesReadInGibibytesOnceTheyAreGibibytes() {
        XCTAssertEqual(KernelMemory.describe(64 << 20), "64 Mo")
        XCTAssertEqual(KernelMemory.describe(512 << 20), "512 Mo")
        XCTAssertEqual(KernelMemory.describe(1024 << 20), "1 Gio")
        XCTAssertEqual(KernelMemory.describe(1536 << 20), "1,5 Gio")
        XCTAssertEqual(KernelMemory.describe(LinuxMachine.maximumRAMSize), "2 Gio")
        for size in KernelMemory.choices {
            XCTAssertFalse(
                KernelMemory.describe(size).hasPrefix("1024"),
                "aucun palier ne doit s'annoncer en milliers de mégaoctets")
        }
    }
}
