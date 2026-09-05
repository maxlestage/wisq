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

    /// Le plafond **de repli** : un huitième de la mémoire physique, borné par
    /// ce que l'architecture permet, et jamais sous la machine de référence.
    ///
    /// C'est la règle des plateformes qui ne publient pas de budget par
    /// application — macOS, Linux. Sur iOS, `os_proc_available_memory()`
    /// répond et cette fraction ne sert pas ; elle reste parce qu'une valeur
    /// inventée vaut mieux que rien là où le système ne dit rien, et parce que
    /// c'est elle que les tests d'ici peuvent atteindre.
    ///
    /// Les trois bords, avec les téléphones réels derrière. Le plancher compte
    /// autant que le plafond : sans lui, la machine par défaut deviendrait
    /// impossible sur un appareil où elle a toujours marché.
    func testTheCeilingIsAnEighthCappedAndFloored() {
        // 2 Go — le plus petit appareil sous iOS 17. Le huitième ferait
        // 256 Mo, mais la règle de l'appareil (« deux gibioctets de moins que
        // ce qu'il a ») vaut **zéro** ici : c'est le bord net de cette règle,
        // et c'est le plancher qui rattrape, à la machine de référence.
        XCTAssertEqual(
            KernelMemory.ceiling(availableBytes: nil, physicalMemory: 2048 << 20),
            LinuxMachine.defaultRAMSize)
        // 6 Go — un téléphone récent : le huitième fait 768 Mo, et la règle de
        // l'appareil en laisserait 4 Gio, donc c'est bien le huitième qui
        // décide. Les deux bornes existent vraiment, chacune son tour.
        XCTAssertEqual(
            KernelMemory.ceiling(availableBytes: nil, physicalMemory: 6144 << 20), 768 << 20)
        // 16 Go — un iPad : le huitième fait 2 Gio, exactement ce que le
        // processeur 32 bits de l'invité peut adresser. Le plafond était écrit
        // « un gibioctet » et coïncidait donc avec cette limite par accident,
        // ce qui faisait passer une contrainte d'architecture pour un choix.
        XCTAssertEqual(
            KernelMemory.ceiling(availableBytes: nil, physicalMemory: 16384 << 20), LinuxMachine.maximumRAMSize)
        // 64 Go — un Mac : le huitième ferait 8 Gio, la limite tient.
        XCTAssertEqual(
            KernelMemory.ceiling(availableBytes: nil, physicalMemory: 65536 << 20), LinuxMachine.maximumRAMSize)
        // Le plancher : un huitième de 256 Mo vaut 32 Mo, la référence gagne.
        XCTAssertEqual(KernelMemory.ceiling(availableBytes: nil, physicalMemory: 256 << 20), LinuxMachine.defaultRAMSize)
        // Et jamais nul, même sur une valeur absurde.
        XCTAssertEqual(KernelMemory.ceiling(availableBytes: nil, physicalMemory: 0), LinuxMachine.defaultRAMSize)
        // Monotone.
        var previous: UInt32 = 0
        for gigabytes in [1, 2, 3, 4, 6, 8, 12, 16, 32] {
            let limit = KernelMemory.ceiling(availableBytes: nil, physicalMemory: UInt64(gigabytes) << 30)
            XCTAssertGreaterThanOrEqual(limit, previous, "\(gigabytes) Go")
            previous = limit
        }
    }

    /// Ce qu'on propose est ce que l'appareil peut tenir, et la référence y est
    /// toujours — un sélecteur sans le réglage par défaut serait un piège.
    func testWhatIsOfferedFitsUnderTheCeilingAndAlwaysHoldsTheDefault() {
        for physical: UInt64 in [1024 << 20, 2048 << 20, 4096 << 20, 8192 << 20] {
            let limit = KernelMemory.ceiling(availableBytes: nil, physicalMemory: physical)
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
            // Relu comme le noyau le lit — en démontant l'arbre — plutôt qu'à
            // un décalage d'octet. Le décalage marchait tant que l'arbre était
            // un blob figé ; il ne veut plus rien dire depuis qu'il est bâti.
            let tree = try DeviceTree.read(machine.deviceTreeHandedToTheGuest)
            XCTAssertEqual(
                tree.root.child("memory@80000000")?.property("reg"),
                .cells([0, 0x8000_0000, 0, size - UInt32(RV32DeviceTree.memoryTopReserve)]),
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
                KernelMemory.ceiling(availableBytes: nil, physicalMemory: physical),
                LinuxMachine.maximumRAMSize,
                "\(physical >> 30) Gio physiques")
        }
    }

    /// Et un appareil assez grand atteint vraiment les gigaoctets : c'est
    /// l'appareil qui borne, pas l'unité.
    func testALargeDeviceReachesGibibytes() {
        XCTAssertEqual(KernelMemory.ceiling(availableBytes: nil, physicalMemory: 8 << 30), 1024 << 20)
        XCTAssertEqual(
            KernelMemory.ceiling(availableBytes: nil, physicalMemory: 16 << 30), LinuxMachine.maximumRAMSize)
        XCTAssertTrue(
            KernelMemory.offered(ceiling: KernelMemory.ceiling(availableBytes: nil, physicalMemory: 8 << 30))
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

/// Le plafond quand le système, lui, sait répondre.
///
/// Maxime : « je voudrais aussi que tu utilises la mémoire de mon téléphone
/// pour la partager ». La bonne réponse n'était pas d'augmenter la fraction
/// inventée, c'était d'arrêter d'inventer : iOS publie exactement ce nombre —
/// `os_proc_available_memory()` rend ce que l'application peut encore allouer
/// avant que le système ne la tue.
final class SystemBudgetCeilingTests: XCTestCase {
    private func ceiling(available: UInt64?, physical: UInt64 = 8 << 30) -> UInt32 {
        KernelMemory.ceiling(availableBytes: available, physicalMemory: physical)
    }

    /// Ce que le système laisse, moins ce que l'application garde pour elle.
    func testTheCeilingIsWhatTheSystemLeavesMinusWhatTheAppNeeds() {
        // 1,5 Gio disponibles − 256 Mio pour l'application = 1,25 Gio.
        XCTAssertEqual(ceiling(available: 1536 << 20), (1536 - 256) << 20)
        // Et l'écart est exactement la réserve nommée, pas un nombre voisin.
        XCTAssertEqual(
            UInt64(ceiling(available: 1024 << 20)),
            (1024 << 20) - KernelMemory.roomForTheAppItself)
    }

    /// Un téléphone qui a beaucoup de place donne beaucoup — c'est le point de
    /// la demande — mais jamais plus que ce que le processeur peut adresser.
    func testAGenerousDeviceGivesGibibytesButNeverPastTheArchitecture() {
        XCTAssertEqual(ceiling(available: 3 << 30), LinuxMachine.maximumRAMSize)
        XCTAssertEqual(ceiling(available: 64 << 30), LinuxMachine.maximumRAMSize)
        XCTAssertGreaterThanOrEqual(ceiling(available: 2 << 30), 1024 << 20)
    }

    /// Un téléphone à l'étroit ne descend pas sous la machine de référence :
    /// elle a toujours marché, et un plancher qui la rendrait impossible
    /// transformerait une contrainte passagère en panne permanente.
    func testATightDeviceStillOffersTheReferenceMachine() {
        XCTAssertEqual(ceiling(available: 300 << 20), LinuxMachine.defaultRAMSize)
        XCTAssertEqual(ceiling(available: 0), LinuxMachine.defaultRAMSize)
        // Et la soustraction ne déborde pas quand la réserve est plus grande
        // que ce qui reste.
        XCTAssertEqual(ceiling(available: 1), LinuxMachine.defaultRAMSize)
    }

    /// Là où le système ne dit rien, la fraction reprend la main — et donne un
    /// résultat différent, sinon ce paramètre ne servirait à rien.
    func testWhereTheSystemSaysNothingTheFractionTakesOver() {
        XCTAssertEqual(ceiling(available: nil, physical: 8 << 30), 1024 << 20)
        XCTAssertNotEqual(
            ceiling(available: 1024 << 20, physical: 8 << 30),
            ceiling(available: nil, physical: 8 << 30),
            "les deux règles doivent vraiment être deux règles")
    }

    /// La règle est **monotone** : plus le téléphone laisse de place, plus la
    /// machine peut être grande. C'est ce qu'un curseur promet en glissant.
    func testMoreRoomIsNeverLessMachine() {
        var previous: UInt32 = 0
        for megabytes in [0, 128, 256, 512, 1024, 2048, 4096, 8192] {
            let limit = ceiling(available: UInt64(megabytes) << 20)
            XCTAssertGreaterThanOrEqual(limit, previous, "\(megabytes) Mo disponibles")
            previous = limit
        }
    }

    /// Et le refus qui remplace un plantage : les deux chiffres, et quoi faire.
    ///
    /// « Pas assez de mémoire » sans nombre est une impasse — on ne peut pas
    /// savoir s'il faut fermer une application ou baisser le réglage.
    func testTheRefusalNamesBothFiguresAndWhatToDo() {
        let message = KernelMemory.notEnoughRoomExplanation(
            requested: 1024 << 20, ceiling: 512 << 20, name: "Image")
        XCTAssertTrue(message.contains("Image"), message)
        XCTAssertTrue(message.contains("1 Gio"), message)
        XCTAssertTrue(message.contains("512 Mo"), message)
        XCTAssertTrue(message.contains("curseur"), "il faut dire quoi faire : \(message)")
        XCTAssertFalse(
            message.contains("octets"),
            "le message parle à quelqu'un, pas à un journal : \(message)")
    }
}

/// La règle de Maxime : « deux giga plus petit que ce que le téléphone a ».
///
/// Elle vit **à côté** de la réponse du système, pas à sa place, parce que les
/// deux disent des choses différentes : celle-ci dit de combien d'un appareil
/// wisq accepte d'être, `os_proc_available_memory()` dit ce qui est libre à cet
/// instant. La plus petite des deux est la seule qu'on puisse proposer sans
/// proposer un plantage.
final class DeviceMarginCeilingTests: XCTestCase {
    /// Sur un iPhone 17 Pro (12 Go), la règle laisse 10 Gio — et c'est donc la
    /// réponse du système qui décide, comme prévu.
    func testOnALargePhoneTheSystemAnswerIsTheBindingOne() {
        let physical: UInt64 = 12 << 30
        // Le système dit 3 Gio libres : c'est lui qui borne, pas la règle.
        XCTAssertEqual(
            KernelMemory.ceiling(availableBytes: 3 << 30, physicalMemory: physical),
            LinuxMachine.maximumRAMSize,
            "3 Gio moins la réserve dépasse encore la limite d'architecture")
        // Le système dit 600 Mo libres : lui encore, et bien plus bas.
        XCTAssertEqual(
            KernelMemory.ceiling(availableBytes: 600 << 20, physicalMemory: physical),
            (600 - 256) << 20)
    }

    /// Et la règle mord vraiment quand le système est généreux : un appareil de
    /// 3 Gio n'en laisse qu'un, quoi que le système raconte.
    func testTheDeviceRuleBitesWhenTheSystemIsGenerous() {
        XCTAssertEqual(
            KernelMemory.ceiling(availableBytes: 8 << 30, physicalMemory: 3 << 30),
            1 << 30,
            "trois gibioctets moins deux, et le système ne peut pas passer outre")
    }

    /// Le bord net, et il faut le regarder en face : sur un appareil de deux
    /// gibioctets ou moins, « deux gibioctets de moins » vaut zéro. Le plancher
    /// rend alors la machine de référence, celle qui a toujours marché.
    func testOnASmallDeviceTheRuleReachesZeroAndTheFloorAnswers() {
        for physical: UInt64 in [2 << 30, 1 << 30, 0] {
            XCTAssertEqual(
                KernelMemory.ceiling(availableBytes: 8 << 30, physicalMemory: physical),
                LinuxMachine.defaultRAMSize,
                "\(physical >> 30) Gio physiques")
        }
    }

    /// La marge est bien deux gibioctets, lue plutôt que réaffirmée.
    func testTheMarginIsTwoGibibytes() {
        XCTAssertEqual(KernelMemory.leftToTheDevice, 2 << 30)
        // Un appareil de 4 Gio en laisse exactement 2 à la machine.
        XCTAssertEqual(
            KernelMemory.ceiling(availableBytes: 64 << 30, physicalMemory: 4 << 30),
            LinuxMachine.maximumRAMSize)
    }
}
