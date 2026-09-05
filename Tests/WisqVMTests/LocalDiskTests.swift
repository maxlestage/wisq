import XCTest

@testable import WisqVM

/// Le disque d'un noyau : ce qui peut en être un, lequel a été choisi, et ce
/// que la place permet.
final class LocalDiskTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wisq-disque-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func file(_ name: String, _ bytes: [UInt8]) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url
    }

    /// Une image ext4 : la marque du superbloc, à sa place.
    private func ext4(_ name: String, bytes count: Int = 4096) throws -> URL {
        var image = [UInt8](repeating: 0, count: max(count, 0x43A))
        image[0x438] = 0x53
        image[0x439] = 0xEF
        return try file(name, image)
    }

    // MARK: - Ce dont on se souvient

    /// Un premier lancement : rien d'enregistré, et rien d'écrit non plus.
    func testWithNothingRecordedAKernelHasNoDisk() {
        XCTAssertNil(LocalDisk.recordedName(forKernel: "vmlinuz-lts", in: folder))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: folder.appendingPathComponent(LocalDisk.fileName).path),
            "aucun fichier ne doit être créé par une simple lecture")
    }

    /// Un choix survit, et n'appartient qu'à son noyau.
    func testAChoiceIsRememberedForItsOwnKernelOnly() {
        LocalDisk.attach("racine.img", forKernel: "vmlinuz-lts", in: folder)
        XCTAssertEqual(LocalDisk.recordedName(forKernel: "vmlinuz-lts", in: folder), "racine.img")
        XCTAssertNil(LocalDisk.recordedName(forKernel: "vmlinuz-edge", in: folder))
    }

    /// « Aucun » efface l'entrée, et le fichier avec quand il ne reste rien.
    func testChoosingNoneRemovesTheEntryAndTheFile() {
        LocalDisk.attach("racine.img", forKernel: "vmlinuz-lts", in: folder)
        LocalDisk.attach(nil, forKernel: "vmlinuz-lts", in: folder)
        XCTAssertNil(LocalDisk.recordedName(forKernel: "vmlinuz-lts", in: folder))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: folder.appendingPathComponent(LocalDisk.fileName).path),
            "un fichier vide ne doit pas rester derrière")
    }

    /// **Un disque supprimé depuis se lit comme « pas de disque ».** Le nom
    /// est encore écrit ; le fichier, lui, n'est plus là, et refuser de
    /// démarrer pour ça coûterait la session pour une raison sans rapport.
    func testARecordedDiskThatNoLongerExistsReadsAsNone() throws {
        let disk = try ext4("racine.img")
        // Un autre fichier **avant** lui dans la bibliothèque : c'est le nom
        // qui désigne le disque, pas la position, et une recherche qui prend
        // le premier venu rendrait celui-ci.
        let other = try ext4("autre.img")
        LocalDisk.attach("racine.img", forKernel: "vmlinuz-lts", in: folder)
        XCTAssertEqual(
            LocalDisk.attached(kernel: "vmlinuz-lts", among: [other, disk], in: folder), disk)
        XCTAssertNil(
            LocalDisk.attached(kernel: "vmlinuz-lts", among: [], in: folder),
            "le fichier a disparu de la bibliothèque : la machine démarre sans disque")
        XCTAssertEqual(
            LocalDisk.recordedName(forKernel: "vmlinuz-lts", in: folder), "racine.img",
            "le choix reste écrit — c'est le fichier qui manque, pas le réglage")
    }

    /// Supprimer une image l'oublie chez **tous** les noyaux qui l'avaient.
    func testDeletingADiskForgetsItEverywhereAndSaysHowManyTimes() {
        LocalDisk.attach("racine.img", forKernel: "vmlinuz-lts", in: folder)
        LocalDisk.attach("racine.img", forKernel: "vmlinuz-edge", in: folder)
        LocalDisk.attach("autre.img", forKernel: "vmlinuz-virt", in: folder)
        XCTAssertEqual(LocalDisk.forgetDisk(named: "racine.img", in: folder), 2)
        XCTAssertNil(LocalDisk.recordedName(forKernel: "vmlinuz-lts", in: folder))
        XCTAssertNil(LocalDisk.recordedName(forKernel: "vmlinuz-edge", in: folder))
        XCTAssertEqual(
            LocalDisk.recordedName(forKernel: "vmlinuz-virt", in: folder), "autre.img",
            "un autre disque n'a pas à être emporté")
        XCTAssertEqual(
            LocalDisk.forgetDisk(named: "racine.img", in: folder), 0,
            "rien à oublier une seconde fois")
    }

    /// Supprimer un noyau oublie le disque qu'on lui avait donné.
    func testDeletingAKernelForgetsItsDisk() {
        LocalDisk.attach("racine.img", forKernel: "vmlinuz-lts", in: folder)
        LocalDisk.forget(kernel: "vmlinuz-lts", in: folder)
        XCTAssertNil(LocalDisk.recordedName(forKernel: "vmlinuz-lts", in: folder))
    }

    /// Un fichier illisible se lit comme « aucun choix », pas comme une panne.
    func testAnUnreadableFileReadsAsNoChoices() throws {
        try Data("ceci n'est pas du JSON".utf8)
            .write(to: folder.appendingPathComponent(LocalDisk.fileName))
        XCTAssertNil(LocalDisk.recordedName(forKernel: "vmlinuz-lts", in: folder))
    }

    // MARK: - Ce que la place permet

    /// Le plafond laisse la place d'une machine, et jamais moins que rien.
    func testTheCeilingLeavesRoomForTheSmallestMachine() {
        let ceiling: UInt32 = 1024 << 20
        XCTAssertEqual(
            LocalDisk.maximumBytes(ceiling: ceiling),
            Int(ceiling) - X86Machine.minimumRAMSize)
        XCTAssertEqual(
            LocalDisk.maximumBytes(ceiling: 64 << 20), 0,
            "un téléphone qui ne peut pas porter la plus petite machine ne porte aucun disque")
    }

    /// Les deux bords du refus, et le milieu qui passe.
    func testTheRefusalNamesTheNumberThatBlocks() {
        let ceiling: UInt32 = 1024 << 20
        let maximum = LocalDisk.maximumBytes(ceiling: ceiling)
        XCTAssertNil(LocalDisk.refusal(size: maximum, name: "r.img", ceiling: ceiling),
                     "exactement le plafond passe")
        let tooBig = LocalDisk.refusal(size: maximum + 1, name: "r.img", ceiling: ceiling)
        XCTAssertNotNil(tooBig)
        XCTAssertTrue(tooBig?.contains("r.img") == true, "le refus nomme le fichier")
        XCTAssertTrue(tooBig?.contains("mémoire") == true,
                      "et dit pourquoi : le disque est tenu en mémoire")
        XCTAssertNil(LocalDisk.refusal(size: 512, name: "r.img", ceiling: ceiling),
                     "un secteur exactement est un disque")
        XCTAssertNotNil(LocalDisk.refusal(size: 511, name: "r.img", ceiling: ceiling),
                        "moins d'un secteur n'en est pas un")
    }

    // MARK: - Ce qu'on peut proposer

    /// Ce qui peut être un disque, et ce qui n'en sera jamais un.
    func testWhatCanBeADiskAndWhatCannot() {
        XCTAssertTrue(LocalDisk.couldBeDisk(.filesystemImage("ext2/3/4")))
        XCTAssertTrue(LocalDisk.couldBeDisk(.discImage("ISO 9660")))
        XCTAssertTrue(LocalDisk.couldBeDisk(.unknown), "inconnu est une permission")
        // **Mais « peut l'être » n'est pas « l'est ».** C'est cette
        // différence-là qui décide du refus qu'on reçoit quand le fichier est
        // trop gros, et la confondre rendrait un plafond de disque à quelqu'un
        // qui apportait un noyau.
        XCTAssertFalse(LocalDisk.isDiskImage(.unknown))
        XCTAssertTrue(LocalDisk.isDiskImage(.filesystemImage("ext2/3/4")))
        XCTAssertTrue(LocalDisk.isDiskImage(.discImage("ISO 9660")))
        XCTAssertFalse(
            LocalDisk.couldBeDisk(.compressedKernel("gzip")),
            "un fichier compressé dans cette bibliothèque est l'initramfs d'à côté")
        XCTAssertFalse(LocalDisk.couldBeDisk(
            .linuxKernel(KernelImage(GuestArchitecture(.x86, bits: 64), format: "bzImage"))))
        XCTAssertFalse(LocalDisk.couldBeDisk(.executable(GuestArchitecture(.arm, bits: 64))))
    }

    /// Ce qu'on offre : les disques de la bibliothèque, sans le noyau lui-même.
    func testTheCandidatesAreTheDisksAndNotTheKernelItself() throws {
        let disk = try ext4("racine.img")
        let initramfs = try file("initramfs-lts", [0x1F, 0x8B, 0x08, 0x00])
        // Un `bzImage` reconnaissable demanderait un vrai en-tête ; le nom du
        // noyau suffit ici, puisque c'est l'exclusion par le nom qu'on mesure.
        let kernel = try ext4("vmlinuz-lts")
        let candidates = LocalDisk.candidates(
            among: [disk, initramfs, kernel], kernel: "vmlinuz-lts")
        XCTAssertEqual(candidates, [disk])
    }
}
