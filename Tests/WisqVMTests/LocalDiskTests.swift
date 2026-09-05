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

    // MARK: - Ce qui est un disque

    /// **Il n'y a plus de plafond.** Le disque est lu sur place ; une image
    /// de plusieurs gigaoctets passe, et c'est la correction que Maxime a
    /// demandée : « n'importe quelle image doit fonctionner ».
    func testThereIsNoCeilingAnyMore() {
        XCTAssertNil(LocalDisk.refusal(size: 6 << 30, name: "grosse.img"))
        XCTAssertNil(LocalDisk.refusal(size: Int.max, name: "immense.img"))
    }

    /// Le plancher reste, et il nomme le nombre qui bloque.
    func testTheRefusalNamesTheNumberThatBlocks() {
        XCTAssertNil(LocalDisk.refusal(size: 512, name: "r.img"),
                     "un secteur exactement est un disque")
        let tooSmall = LocalDisk.refusal(size: 511, name: "r.img")
        XCTAssertNotNil(tooSmall, "moins d'un secteur n'en est pas un")
        XCTAssertTrue(tooSmall?.contains("r.img") == true, "le refus nomme le fichier")
        XCTAssertTrue(tooSmall?.contains("511") == true, "et le nombre")
        XCTAssertFalse(tooSmall?.contains("mémoire") == true,
                       "et ne parle plus de mémoire : le disque n'y est plus")
    }

    // MARK: - La couche d'écriture

    /// La couche d'un disque a une place, sous son nom, dans un dossier à
    /// côté des machines sauvegardées.
    func testTheOverlayLivesUnderTheDiskName() throws {
        let url = try LocalDisk.writesURL(for: "racine.img", in: folder)
        XCTAssertEqual(url.lastPathComponent, "racine.img.writes")
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "disk-writes")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: url.deletingLastPathComponent().path), "le dossier est créé")
    }

    /// Jeter la couche jette les deux fichiers — et rien d'autre.
    func testDiscardingTheOverlayRemovesBothFilesAndNothingElse() throws {
        let url = try LocalDisk.writesURL(for: "racine.img", in: folder)
        try Data([1]).write(to: url)
        try Data([2]).write(to: URL(fileURLWithPath: url.path + ".map"))
        let other = try LocalDisk.writesURL(for: "autre.img", in: folder)
        try Data([3]).write(to: other)

        LocalDisk.discardWrites(for: "racine.img", in: folder)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path + ".map"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path), "le voisin reste")
    }

    /// **Ce que la couche occupe, c'est ce que l'invité a écrit** — et rien
    /// de plus, quelle que soit la taille du disque. Un disque de quatre mille
    /// secteurs dont un seul est touché ne doit pas se lire « deux mébioctets »
    /// dans le rapport de stockage ; c'est ce qu'il faisait quand la couche
    /// était éparse et que le système de fichiers ne l'était pas.
    func testOverlayBytesAreWhatTheGuestWroteAndNothingMore() throws {
        XCTAssertEqual(LocalDisk.overlayBytes(for: "racine.img", in: folder), 0, "rien avant")
        var base = [UInt8](repeating: 0, count: 4000 * 512)
        base[0] = 1
        let baseURL = folder.appendingPathComponent("racine.img")
        try Data(base).write(to: baseURL)
        let store = try FileDiskStore(
            base: baseURL, writes: try LocalDisk.writesURL(for: "racine.img", in: folder))
        XCTAssertTrue(store.write(at: 3999 * 512, [UInt8](repeating: 7, count: 512)))
        store.flush()

        // Un secteur rangé, plus l'en-tête de la carte et le nom de son
        // emplacement : 512 + 16 + 8.
        XCTAssertEqual(LocalDisk.overlayBytes(for: "racine.img", in: folder), 536)
    }

    // MARK: - Le disque que personne n'a touché

    /// **La seule limite que wisq ne peut pas lever, dite plutôt que subie.**
    ///
    /// Le périphérique existe des deux côtés maintenant. Ce qui reste hors de
    /// portée, c'est le pilote bloc dans le noyau que quelqu'un apporte : sans
    /// lui, la fenêtre n'est jamais sondée et le disque est parfaitement muet
    /// — indiscernable d'un disque cassé ou d'un réglage qui n'a pas pris.
    func testADiskNobodyTouchedSaysSo() throws {
        let note = try XCTUnwrap(
            LocalDisk.silenceNote(activity: (served: 0, refused: 0), disk: "racine.img"))
        XCTAssertTrue(note.contains("racine.img"), note)
        XCTAssertTrue(note.contains("/dev/vda"), "et où il était")
        XCTAssertTrue(note.contains("pilote"), "et pourquoi personne n'est venu")
    }

    /// **Une seule requête suffit à faire taire la phrase**, même refusée.
    ///
    /// Un refus prouve que le pilote est là et qu'il a parlé ; le silence
    /// vient alors d'ailleurs, et répéter « votre noyau n'a pas de pilote »
    /// enverrait chercher au mauvais endroit.
    func testOneRequestIsEnoughToSilenceTheNote() {
        XCTAssertNil(LocalDisk.silenceNote(activity: (served: 1, refused: 0), disk: "r.img"))
        XCTAssertNil(LocalDisk.silenceNote(activity: (served: 0, refused: 1), disk: "r.img"),
                     "un refus est une preuve que quelqu'un est venu")
    }

    /// Et sans disque du tout, il n'y a rien à dire.
    func testWithNoDiskThereIsNothingToSay() {
        XCTAssertNil(LocalDisk.silenceNote(activity: nil, disk: "r.img"))
    }

    // MARK: - Ce que c'est, avant ce que ça pèse

    /// **Un ISO d'installation trop gros s'entend dire ce qu'il est.**
    ///
    /// C'est le refus qu'un vrai import a produit sur un téléphone : une image
    /// d'Arch de 5,8 Gio, refusée avec un chiffre et une phrase sur la
    /// mémoire. Le nombre était juste et la réponse inutile — la personne
    /// n'avait pas apporté un disque trop gros, elle avait apporté une image
    /// d'installation, et aucun plafond de mémoire ne la fera démarrer.
    ///
    /// C'est la leçon de l'ISO refusé pour sa taille, reprise par l'autre
    /// bout : pointer un nombre envoie le lecteur au réglage de mémoire, où
    /// il n'y a rien à trouver.
    func testATinyDiscImageIsToldWhatItIsBeforeWhatItWeighs() throws {
        let refusal = try XCTUnwrap(LocalDisk.refusal(
            size: 100, name: "omarchy-4.0.2.iso", kind: .discImage("ISO 9660")))
        let what = try XCTUnwrap(refusal.range(of: "ISO 9660"))
        let weight = try XCTUnwrap(refusal.range(of: "100 octets"))
        XCTAssertLessThan(what.lowerBound, weight.lowerBound,
                          "ce que c'est passe avant ce que ça pèse")
        XCTAssertTrue(refusal.contains("/boot"),
                      "et le noyau qu'elle cherche est dedans, à cet endroit-là")
        // Et surtout : pas le conseil de la garder comme disque. Il est vrai
        // pour une image qui tient, et c'est exactement celui-là qui ne l'est
        // pas ici — l'offrir serait renvoyer quelqu'un vers la porte qu'on
        // vient de lui fermer.
        XCTAssertFalse(refusal.contains("garder comme"),
                       "on ne propose pas ce qu'on vient de refuser")
    }

    /// La même composition pour un système de fichiers, et le pronom qui suit.
    func testATinyFilesystemImageNamesItselfThenItsSize() throws {
        let refusal = try XCTUnwrap(LocalDisk.refusal(
            size: 300, name: "racine.img", kind: .filesystemImage("ext4")))
        XCTAssertTrue(refusal.contains("ext4"))
        XCTAssertTrue(refusal.contains("Elle fait"),
                      "la seconde phrase reprend l'image, sans réciter le nom")
        XCTAssertEqual(refusal.components(separatedBy: "racine.img").count - 1, 1,
                       "le nom du fichier est dit une fois")
    }

    /// **Une image d'installation n'est pas refusée**, quelle que soit sa
    /// taille. C'est l'ISO d'Omarchy de 5,8 Gio que l'application avait
    /// renvoyé ; il passe, et c'est T3 qui démarrera dessus.
    func testADiscImageOfAnySizeIsNotRefusedAtAll() {
        XCTAssertNil(LocalDisk.refusal(size: 200 << 20, name: "petit.iso",
                                       kind: .discImage("ISO 9660")))
        XCTAssertNil(LocalDisk.refusal(size: 5_800 << 20, name: "omarchy-4.0.2.iso",
                                       kind: .discImage("ISO 9660")))
    }

    /// Un fichier que personne n'a reconnu garde le refus qu'il avait.
    ///
    /// C'est le refus écrit le jour où l'application a disparu sans un mot
    /// devant une image de deux gigaoctets ; le composer avec une identité
    /// qu'on n'a pas serait le remplacer par du vide.
    func testAnUnrecognisedFileKeepsThePlainRefusal() {
        XCTAssertEqual(
            LocalDisk.refusal(size: 511, name: "x.bin", kind: .unknown),
            LocalDisk.refusal(size: 511, name: "x.bin"))
    }

    /// Ce que `whatItIs` dit, et ce qu'il se garde de dire.
    func testWhatItIsNamesTheTwoDiskKindsAndNothingElse() {
        XCTAssertNotNil(KernelImageKind.whatItIs(.discImage("ISO 9660"), name: "a.iso"))
        XCTAssertNotNil(KernelImageKind.whatItIs(.filesystemImage("ext4"), name: "a.img"))
        XCTAssertNil(KernelImageKind.whatItIs(.unknown, name: "a"))
        XCTAssertNil(KernelImageKind.whatItIs(.compressedKernel("gzip"), name: "a.gz"))
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
