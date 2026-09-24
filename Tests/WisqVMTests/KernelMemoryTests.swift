import XCTest

@testable import WisqVM

/// **Les deux faits de `LinuxMachine`, en soixante-quatre bits.**
///
/// `KernelMemory` compte maintenant en `UInt64` — seize gibioctets n'entrent
/// pas dans trente-deux bits — et `LinuxMachine` compte toujours en `UInt32`,
/// parce que son adressage s'arrête là. La conversion vit ici plutôt que de
/// comparer `KernelMemory.defaultSize` à lui-même : les deux côtés doivent
/// rester deux côtés, sans quoi l'assertion ne mesurerait plus leur accord.
private let referenceMachine = UInt64(LinuxMachine.defaultRAMSize)
private let riscvLimit = UInt64(LinuxMachine.maximumRAMSize)

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
            KernelMemory.size(forKernel: "Image", in: folder), referenceMachine)
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
            referenceMachine,
            "le réglage d'un noyau ne doit pas s'appliquer à un autre")
    }

    /// Revenir au défaut efface l'entrée plutôt que d'écrire le nombre : un
    /// fichier qui ne contient que les écarts au défaut reste lisible.
    func testGoingBackToTheDefaultRemovesTheEntry() {
        KernelMemory.setSize(128 << 20, forKernel: "Image", in: folder)
        KernelMemory.setSize(referenceMachine, forKernel: "Image", in: folder)
        XCTAssertEqual(KernelMemory.size(forKernel: "Image", in: folder), referenceMachine)
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
        XCTAssertEqual(KernelMemory.size(forKernel: "Image", in: folder), referenceMachine)
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
        XCTAssertEqual(KernelMemory.size(forKernel: "Image", in: folder), referenceMachine)

        // Et écrit à la main dans le fichier, il est ignoré à la lecture.
        let url = folder.appendingPathComponent(KernelMemory.fileName)
        try Data(#"{"Image":1000000}"#.utf8).write(to: url)
        XCTAssertEqual(KernelMemory.size(forKernel: "Image", in: folder), referenceMachine)
    }

    /// Un fichier illisible se lit comme « aucun choix », pas comme une panne :
    /// le pire résultat est que chaque noyau tourne à la taille de référence,
    /// ce qu'il faisait avant que ce réglage existe.
    func testAnUnreadableFileReadsAsNoChoices() throws {
        let url = folder.appendingPathComponent(KernelMemory.fileName)
        try Data("ceci n'est pas du JSON".utf8).write(to: url)
        XCTAssertEqual(KernelMemory.size(forKernel: "Image", in: folder), referenceMachine)
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
            referenceMachine)
        // 6 Go — un téléphone récent : le huitième fait 768 Mo, et la règle de
        // l'appareil en laisserait 4 Gio, donc c'est bien le huitième qui
        // décide. Les deux bornes existent vraiment, chacune son tour.
        XCTAssertEqual(
            KernelMemory.ceiling(availableBytes: nil, physicalMemory: 6144 << 20), 768 << 20)
        // 16 Go — un iPad : le huitième fait 2 Gio, et la règle de l'appareil
        // en laisserait quatorze. C'est donc le huitième qui décide.
        //
        // **Ce test disait autrefois « la limite d'architecture tient ».** Sans
        // cœur nommé, elle est maintenant celle de la machine PC — seize
        // gibioctets — donc ce qu'on mesure ici est bien la fraction, et plus
        // l'adressage du rv32 par accident. La borne d'architecture a son
        // propre test, par cœur.
        XCTAssertEqual(
            KernelMemory.ceiling(availableBytes: nil, physicalMemory: 16384 << 20), 2048 << 20)
        // 64 Go — un Mac : le huitième fait 8 Gio, et la règle de l'appareil
        // en laisserait soixante-deux. Le huitième encore.
        XCTAssertEqual(
            KernelMemory.ceiling(availableBytes: nil, physicalMemory: 65536 << 20), 8192 << 20)
        // Le plancher : un huitième de 256 Mo vaut 32 Mo, la référence gagne.
        XCTAssertEqual(KernelMemory.ceiling(availableBytes: nil, physicalMemory: 256 << 20), referenceMachine)
        // Et jamais nul, même sur une valeur absurde.
        XCTAssertEqual(KernelMemory.ceiling(availableBytes: nil, physicalMemory: 0), referenceMachine)
        // Monotone.
        var previous: UInt64 = 0
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
                offered.contains(referenceMachine),
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
        for limit in [64 << 20, 256 << 20, 1024 << 20] as [UInt64] {
            XCTAssertEqual(
                KernelMemory.maximumImportableImageBytes(ceiling: limit),
                // Le chargeur rv32 compte en trente-deux bits, et les trois
                // plafonds de cette boucle y tiennent — c'est le sujet du test
                // voisin que de vérifier ce qui arrive au-delà.
                LinuxMachine.maximumKernelImageBytes(forRAMSize: UInt32(limit)),
                "\(limit >> 20) Mo")
        }
        // Et il est strictement plus large que le plafond du défaut dès que
        // l'appareil autorise plus : sinon le réglage ne servirait à rien,
        // puisque le fichier serait refusé avant d'être réglé.
        XCTAssertGreaterThan(
            KernelMemory.maximumImportableImageBytes(ceiling: 256 << 20),
            KernelMemory.maximumImportableImageBytes(ceiling: referenceMachine))
    }

    /// Et chaque taille offerte fait vraiment une machine qui démarre : une
    /// liste de nombres qu'aucune machine n'accepte serait un réglage décoratif.
    func testEveryOfferedSizeBuildsAMachineThatAcceptsAKernel() throws {
        // **Ce test bâtit de vraies machines rv32**, dont la RAM se compte en
        // trente-deux bits : le réglage, lui, en compte soixante-quatre depuis
        // que la machine PC peut recevoir seize gibioctets. La conversion est
        // sûre ici et seulement ici, parce que le plafond passé — un
        // gibioctet — est bien en dessous de ce que le rv32 adresse.
        for size in KernelMemory.offered(ceiling: 1024 << 20) {
            let ram = UInt32(size)
            let machine = LinuxMachine(ramSize: ram) { _ in }
            XCTAssertEqual(machine.ramSize, ram)
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
                .cells([0, 0x8000_0000, 0, ram - UInt32(RV32DeviceTree.memoryTopReserve)]),
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

    /// **Rien de ce qu'on propose à un noyau rv32 ne peut dépasser cette
    /// limite** — et c'est maintenant une question de cœur, non de liste.
    ///
    /// Ce test disait autrefois « ni la liste des choix, ni le plafond de
    /// l'appareil le plus généreux », et cette formulation était le défaut que
    /// la tranche #283 corrige : elle imposait l'adressage du rv32 à *toutes*
    /// les architectures, donc aussi à la machine PC, que rien n'y oblige. La
    /// liste des paliers monte désormais à seize gibioctets ; ce qui doit
    /// rester borné, c'est ce qu'on **offre à ce cœur-là**.
    func testNothingOfferedToTheRISCVCanExceedIt() {
        for physical: UInt64 in [8 << 30, 16 << 30, 64 << 30, .max / 2] {
            let limit = KernelMemory.ceiling(
                availableBytes: nil, physicalMemory: physical, core: .riscv32)
            XCTAssertLessThanOrEqual(limit, riscvLimit, "\(physical >> 30) Gio physiques")
            for size in KernelMemory.offered(ceiling: limit) {
                XCTAssertLessThanOrEqual(
                    size, riscvLimit,
                    "\(KernelMemory.describe(size)) offert à un cœur rv32")
            }
        }
        // Et la limite reste **atteignable** : un appareil assez grand doit
        // pouvoir donner à un noyau rv32 son dernier octet adressable, sinon
        // le plafond serait décoratif.
        XCTAssertEqual(
            KernelMemory.ceiling(
                availableBytes: 20 << 30, physicalMemory: 32 << 30, core: .riscv32),
            riscvLimit,
            "le dernier octet adressable doit rester atteignable")
        XCTAssertTrue(
            KernelMemory.choices.contains(riscvLimit),
            "deux gibioctets doit rester un palier de la liste")
    }

    /// Et un appareil assez grand atteint vraiment les gigaoctets : c'est
    /// l'appareil qui borne, pas l'unité.
    func testALargeDeviceReachesGibibytes() {
        XCTAssertEqual(KernelMemory.ceiling(availableBytes: nil, physicalMemory: 8 << 30), 1024 << 20)
        XCTAssertEqual(
            KernelMemory.ceiling(availableBytes: nil, physicalMemory: 16 << 30), riscvLimit)
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
        XCTAssertEqual(KernelMemory.describe(riscvLimit), "2 Gio")
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
    private func ceiling(available: UInt64?, physical: UInt64 = 8 << 30,
                         core: GuestArchitecture.Core? = nil) -> UInt64 {
        KernelMemory.ceiling(
            availableBytes: available, physicalMemory: physical, core: core)
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
    /// la demande — mais jamais plus que ce que le **cœur nommé** peut
    /// adresser.
    ///
    /// La borne était écrite `riscvLimit` sans cœur, donc elle s'appliquait
    /// aussi à une machine PC : c'est le défaut de la tranche #283. Ici, avec
    /// le cœur, elle redevient ce qu'elle dit être.
    func testAGenerousDeviceGivesGibibytesButNeverPastTheArchitecture() {
        // Huit gibioctets physiques : la règle de l'appareil en laisse six, et
        // le système dit ce qu'on lui fait dire. Un cœur rv32 s'arrête à son
        // dernier octet adressable.
        XCTAssertEqual(ceiling(available: 3 << 30, core: .riscv32), riscvLimit)
        XCTAssertEqual(ceiling(available: 64 << 30, core: .riscv32), riscvLimit)
        // La même place, à une machine PC : elle va plus haut, et c'est la
        // règle de l'appareil — six gibioctets sur huit physiques — qui borne.
        XCTAssertEqual(ceiling(available: 64 << 30, core: .x86_64), 6 << 30)
        XCTAssertGreaterThan(
            ceiling(available: 64 << 30, core: .x86_64),
            ceiling(available: 64 << 30, core: .riscv32),
            "sans quoi le plafond par cœur ne servirait à rien")
        XCTAssertGreaterThanOrEqual(ceiling(available: 2 << 30), 1024 << 20)
    }

    /// Un téléphone à l'étroit ne descend pas sous la machine de référence :
    /// elle a toujours marché, et un plancher qui la rendrait impossible
    /// transformerait une contrainte passagère en panne permanente.
    func testATightDeviceStillOffersTheReferenceMachine() {
        XCTAssertEqual(ceiling(available: 300 << 20), referenceMachine)
        XCTAssertEqual(ceiling(available: 0), referenceMachine)
        // Et la soustraction ne déborde pas quand la réserve est plus grande
        // que ce qui reste.
        XCTAssertEqual(ceiling(available: 1), referenceMachine)
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
        var previous: UInt64 = 0
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
        // Le système dit 3 Gio libres : c'est lui qui borne, pas la règle des
        // deux gibioctets — qui laisserait dix. Trois gibioctets moins les 256
        // Mio que l'application garde pour elle, arrondis au palier du
        // dessous : deux gibioctets. **Sans cœur nommé** le plafond
        // d'architecture est le plus grand, donc c'est bien la réponse du
        // système qu'on mesure ici, et plus l'adressage du rv32 par accident.
        XCTAssertEqual(
            KernelMemory.ceiling(availableBytes: 3 << 30, physicalMemory: physical),
            (3 << 30) - KernelMemory.roomForTheAppItself,
            "3 Gio moins la réserve de l'application")
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
                referenceMachine,
                "\(physical >> 30) Gio physiques")
        }
    }

    /// La marge est bien deux gibioctets, lue plutôt que réaffirmée.
    func testTheMarginIsTwoGibibytes() {
        XCTAssertEqual(KernelMemory.leftToTheDevice, 2 << 30)
        // Un appareil de 4 Gio en laisse exactement 2 à la machine.
        XCTAssertEqual(
            KernelMemory.ceiling(availableBytes: 64 << 30, physicalMemory: 4 << 30),
            riscvLimit)
    }
}

/// **Le plafond est celui de l'architecture, pas celui du rv32.**
///
/// Demande de Maxime : « je souhaite 16go max mais l'utilisateur peut en
/// choisir moins ». Avant cette tranche, `ceiling` bornait *tous* les noyaux à
/// `riscvLimit` — deux gibioctets — qui n'est pas un goût mais
/// un fait d'adressage rv32 : la RAM de l'invité commence à `0x8000_0000` et son
/// hart adresse en trente-deux bits. Une machine x86-64 n'a pas cette
/// contrainte, et se voyait pourtant refuser la même chose.
///
/// Le défaut se lisait dans la capture : une ligne `omarchy-4.0.2.iso`, dont le
/// noyau interne est x86-64, tenue à 2 Gio.
final class PerCoreMemoryCeilingTests: XCTestCase {
    /// Chaque cœur dit son propre plafond, et les deux diffèrent.
    func testEachCoreNamesItsOwnLimit() {
        XCTAssertEqual(
            GuestArchitecture.Core.riscv32.maximumRAMSize,
            UInt64(LinuxMachine.maximumRAMSize),
            "le rv32 est borné par son adressage, pas par un choix")
        XCTAssertEqual(
            GuestArchitecture.Core.x86_64.maximumRAMSize, 16 << 30,
            "le plafond demandé pour la machine PC")
        XCTAssertGreaterThan(
            GuestArchitecture.Core.x86_64.maximumRAMSize,
            GuestArchitecture.Core.riscv32.maximumRAMSize,
            "sans quoi cette tranche n'a pas de sujet")
    }

    /// Sur un appareil assez grand, une machine PC dépasse les deux
    /// gibioctets — et une machine rv32 non.
    func testAGenerousDeviceReachesSixteenForThePCAndTwoForTheRISCV() {
        // Assez grand pour que ni la règle de l'appareil ni celle du moment ne
        // mordent : 32 Gio physiques, rien d'autre en mémoire.
        let physical: UInt64 = 32 << 30
        let pc = KernelMemory.ceiling(
            availableBytes: 20 << 30, physicalMemory: physical, core: .x86_64)
        XCTAssertEqual(pc, 16 << 30, "la machine PC doit atteindre le plafond demandé")

        let riscv = KernelMemory.ceiling(
            availableBytes: 20 << 30, physicalMemory: physical, core: .riscv32)
        XCTAssertEqual(
            riscv, UInt64(LinuxMachine.maximumRAMSize),
            "le rv32 reste à son dernier octet adressable")
    }

    /// **Et l'utilisateur peut en choisir moins** : les paliers en dessous sont
    /// tous offerts, pas seulement le plus grand.
    func testTheUserCanPickLess() {
        let offered = KernelMemory.offered(
            ceiling: KernelMemory.ceiling(
                availableBytes: 20 << 30, physicalMemory: 32 << 30, core: .x86_64))
        for size: UInt64 in [64 << 20, 256 << 20, 1024 << 20, 2 << 30, 4 << 30, 8 << 30, 16 << 30] {
            XCTAssertTrue(
                offered.contains(size),
                "\(KernelMemory.describe(size)) doit être proposable")
        }
        XCTAssertEqual(offered.first, KernelMemory.choices.first, "le plus petit palier reste")
    }

    /// Le téléphone borne avant l'architecture, et c'est lui qui gagne.
    ///
    /// La règle de Maxime — deux gibioctets de moins que l'appareil — plafonne
    /// un iPhone de douze gibioctets à dix, donc **16 Gio n'est pas offert sur
    /// le téléphone d'aujourd'hui**. C'est voulu : le réglage ne promet pas ce
    /// que l'appareil ne peut pas tenir.
    func testThePhoneStillBindsBeforeTheArchitecture() {
        let twelve = KernelMemory.ceiling(
            availableBytes: 11 << 30, physicalMemory: 12 << 30, core: .x86_64)
        XCTAssertLessThanOrEqual(twelve, 10 << 30, "douze gibioctets en laissent dix")
        XCTAssertFalse(
            KernelMemory.offered(ceiling: twelve).contains(16 << 30),
            "16 Gio ne doit pas être proposé là où il ne tient pas")
        XCTAssertTrue(
            KernelMemory.offered(ceiling: twelve).contains(8 << 30),
            "mais 8 Gio, oui")
    }

    /// Un fichier que personne n'a reconnu garde la permission du dépôt —
    /// `unknown` est une permission, pas un doute — donc le plus grand
    /// plafond. C'est le démarrage qui borne ensuite, cœur connu.
    func testAnUnknownCoreGetsTheLargestCeiling() {
        let unknown = KernelMemory.ceiling(
            availableBytes: 20 << 30, physicalMemory: 32 << 30, core: nil)
        XCTAssertEqual(unknown, 16 << 30)
    }

    /// **La garde qui empêche le réglage de mentir**, et la machine qu'elle
    /// protège, construite pour de vrai.
    ///
    /// Le premier jet de ce test était vide : il asserait
    /// `min(réglage, plafond) <= plafond`, vrai quoi que fasse le démarrage —
    /// une tautologie sur `min`, pas une mesure. Il passe maintenant par
    /// `KernelMemory.askedOf`, la fonction que le démarrage appelle, **et** il
    /// charge un noyau dans la machine qui en sort : c'est le refus
    /// `ramSizeUnsupported` qu'on veut ne jamais voir, donc c'est lui qu'il
    /// faut aller chercher.
    func testEveryChoiceBuildsARISCVMachineThatAcceptsAKernel() throws {
        let image = Data([0x13, 0x00, 0x00, 0x00])
        for chosen in KernelMemory.choices {
            let asked = KernelMemory.askedOf(.riscv32, setting: chosen)
            XCTAssertLessThanOrEqual(
                UInt64(asked), UInt64(LinuxMachine.maximumRAMSize),
                "\(KernelMemory.describe(chosen)) : borné à l'adressage")
            let machine = LinuxMachine(ramSize: UInt32(asked)) { _ in }
            XCTAssertNoThrow(
                try machine.load(kernelImage: image),
                "\(KernelMemory.describe(chosen)) : la machine doit accepter un noyau")
        }
        // Et la machine PC reçoit ce qu'on lui a réglé, sans rabotage : sans
        // cette moitié, borner tout le monde à deux gibioctets passerait.
        XCTAssertEqual(
            KernelMemory.askedOf(.x86_64, setting: 16 << 30), 16 << 30,
            "une machine PC ne doit pas être bornée par l'adressage du rv32")
        XCTAssertEqual(KernelMemory.askedOf(.x86_64, setting: 8 << 30), 8 << 30)
    }

    /// Les seize gibioctets se lisent en gibioctets, et pas en mébioctets.
    func testSixteenGibibytesReadsAsSuch() {
        XCTAssertEqual(KernelMemory.describe(16 << 30), "16 Gio")
        XCTAssertEqual(KernelMemory.describe(8 << 30), "8 Gio")
        XCTAssertEqual(KernelMemory.describe(2 << 30), "2 Gio")
    }
}
