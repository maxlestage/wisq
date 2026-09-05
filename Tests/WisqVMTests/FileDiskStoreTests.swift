import Foundation
import XCTest

@testable import WisqVM

/// **Un disque lu depuis un fichier, dont les écritures ne se perdent pas.**
///
/// Le disque était tenu en mémoire, entier : c'était le fait qui commandait
/// tout — le plafond, le refus, la phrase de l'écran. Il commandait aussi ce
/// que quelqu'un pouvait brancher : rien au-dessus de ce que le téléphone
/// laisse, donc jamais l'image d'installation qu'il avait apportée.
///
/// Ce store lit la base **sur place**, en lecture seule, et range chaque
/// secteur écrit par l'invité dans une couche à part : un fichier épars qui
/// n'occupe que ce qui a été écrit, et une carte d'un bit par secteur qui dit
/// où lire. La base ne change jamais ; la couche survit à une suspension, à
/// un redémarrage de l'application, et à la mort de celle-ci — c'est ce que
/// « je ne veux rien perdre » veut dire, et c'est tenu ici.
///
/// **Le même format des deux côtés.** Le cœur Rust écrit exactement la même
/// couche ; un test différentiel compare les deux fichiers octet pour octet.
final class FileDiskStoreTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("wisq-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// Une base de `sectors` secteurs, chacun rempli de son propre numéro
    /// plus un — pour qu'une lecture au mauvais endroit se voie à l'octet.
    private func base(sectors: Int, named name: String = "base.img") throws -> URL {
        var bytes = [UInt8](repeating: 0, count: sectors * 512)
        for sector in 0..<sectors {
            for byte in 0..<512 { bytes[sector * 512 + byte] = UInt8(truncatingIfNeeded: sector + 1) }
        }
        let url = folder.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url
    }

    private var writes: URL { folder.appendingPathComponent("disk.writes") }

    // MARK: - Lire, écrire, et la base qui ne bouge pas

    /// **La base n'est jamais touchée.** Écrire dans le disque écrit dans la
    /// couche ; relire le fichier de base rend ce qu'il a toujours eu.
    func testWritesGoToTheOverlayAndTheBaseIsNeverTouched() throws {
        let baseURL = try base(sectors: 8)
        let before = try Data(contentsOf: baseURL)
        let store = try FileDiskStore(base: baseURL, writes: writes)
        XCTAssertEqual(store.sectors, 8)

        XCTAssertEqual(store.read(at: 512, count: 4), [2, 2, 2, 2], "le secteur 1, depuis la base")
        XCTAssertTrue(store.write(at: 512, [UInt8](repeating: 0xAB, count: 512)))
        XCTAssertEqual(store.read(at: 512, count: 4), [0xAB, 0xAB, 0xAB, 0xAB], "puis depuis la couche")
        XCTAssertEqual(store.read(at: 1024, count: 2), [3, 3], "le voisin n'a pas bougé")

        store.flush()
        XCTAssertEqual(try Data(contentsOf: baseURL), before, "la base est intacte, octet pour octet")
    }

    /// **Et les écritures survivent.** Fermer le store, le rouvrir sur les
    /// mêmes fichiers : ce qui a été écrit est là, le reste vient encore de la
    /// base. C'est le test qui tient « je ne veux rien perdre ».
    func testWritesSurviveClosingAndReopening() throws {
        let baseURL = try base(sectors: 8)
        do {
            let store = try FileDiskStore(base: baseURL, writes: writes)
            XCTAssertTrue(store.write(at: 3 * 512, [UInt8](repeating: 0x5A, count: 512)))
            store.flush()
        }
        let reopened = try FileDiskStore(base: baseURL, writes: writes)
        XCTAssertEqual(reopened.read(at: 3 * 512, count: 3), [0x5A, 0x5A, 0x5A])
        XCTAssertEqual(reopened.read(at: 2 * 512, count: 3), [3, 3, 3], "un secteur jamais écrit vient de la base")
        XCTAssertEqual(reopened.bytesWritten, 512, "et la couche sait ce qu'elle porte")
    }

    /// Une écriture qui ne couvre pas un secteur entier garde le reste du
    /// secteur : la couche est faite de secteurs complets, donc le premier
    /// passage recopie la base avant d'appliquer les octets.
    func testAPartialSectorWriteKeepsTheRestOfTheSector() throws {
        let store = try FileDiskStore(base: try base(sectors: 4), writes: writes)
        XCTAssertTrue(store.write(at: 512 + 8, [9, 9, 9, 9]))
        let sector = try XCTUnwrap(store.read(at: 512, count: 512))
        XCTAssertEqual(Array(sector[0..<8]), [UInt8](repeating: 2, count: 8), "avant : la base")
        XCTAssertEqual(Array(sector[8..<12]), [9, 9, 9, 9], "les quatre octets écrits")
        XCTAssertEqual(Array(sector[12..<512]), [UInt8](repeating: 2, count: 500), "après : la base")
    }

    /// Une écriture à cheval sur deux secteurs touche les deux, et seulement
    /// les deux.
    func testAWriteStraddlingTwoSectorsLandsInBoth() throws {
        let store = try FileDiskStore(base: try base(sectors: 4), writes: writes)
        XCTAssertTrue(store.write(at: 1020, [7, 7, 7, 7, 7, 7, 7, 7]))
        XCTAssertEqual(store.read(at: 1018, count: 12), [2, 2, 7, 7, 7, 7, 7, 7, 7, 7, 3, 3])
        XCTAssertEqual(store.bytesWritten, 1024, "deux secteurs dans la couche")
    }

    // MARK: - Les bords

    /// Au-delà de la fin, rien : ni lecture qui invente, ni écriture qui
    /// agrandit. Le périphérique répond alors une erreur de statut, ce qui est
    /// la réponse d'un vrai disque.
    func testBeyondTheEndIsRefused() throws {
        let store = try FileDiskStore(base: try base(sectors: 4), writes: writes)
        XCTAssertNil(store.read(at: 4 * 512 - 2, count: 4), "à cheval sur la fin")
        XCTAssertNil(store.read(at: 4 * 512, count: 1))
        XCTAssertFalse(store.write(at: 4 * 512, [1]))
        XCTAssertEqual(store.read(at: 4 * 512 - 1, count: 1), [4], "le dernier octet, lui, existe")
    }

    /// **La couche est tassée**, et c'est une mesure qui l'a imposé.
    ///
    /// Le premier jet rangeait chaque secteur à son propre décalage dans un
    /// fichier épars, en comptant sur le système de fichiers pour ne rien
    /// allouer entre les trous. Sur APFS — celui du Mac **et de l'iPhone** —
    /// il alloue : un seul secteur écrit à deux mébioctets du début coûtait
    /// 2 052 096 octets, mesuré par la CI Apple. Une image de six gigaoctets
    /// dont l'invité touche le dernier secteur aurait rempli le téléphone.
    ///
    /// Tassée, la couche coûte 512 octets par secteur touché, sur n'importe
    /// quel système de fichiers — et ce test le vérifie sur la **taille du
    /// fichier**, pas sur ce que le système de fichiers a bien voulu allouer.
    func testTheOverlayIsPackedNotSpread() throws {
        let store = try FileDiskStore(base: try base(sectors: 4000), writes: writes)
        XCTAssertTrue(store.write(at: 3999 * 512, [UInt8](repeating: 1, count: 512)))
        store.flush()
        XCTAssertEqual(try Data(contentsOf: writes).count, 512,
                       "un secteur touché, un secteur rangé — pas deux mébioctets")
        let map = try Data(contentsOf: URL(fileURLWithPath: writes.path + ".map"))
        XCTAssertEqual(map.count, 16 + 8, "l'en-tête, et un nom d'emplacement")
        XCTAssertEqual(Array(map[0..<8]), Array("wisqdisk".utf8))
        XCTAssertEqual(store.bytesWritten, 512)

        // Un second secteur ajoute un emplacement ; le réécrire n'en ajoute pas.
        XCTAssertTrue(store.write(at: 0, [7, 7, 7]))
        XCTAssertTrue(store.write(at: 3999 * 512, [UInt8](repeating: 2, count: 512)))
        store.flush()
        XCTAssertEqual(try Data(contentsOf: writes).count, 1024, "deux emplacements, pas trois")
        XCTAssertEqual(store.bytesWritten, 1024)
        XCTAssertEqual(store.read(at: 3999 * 512, count: 2), [2, 2], "et la réécriture a pris")
        XCTAssertEqual(store.read(at: 0, count: 4), [7, 7, 7, 1], "le secteur zéro aussi")
    }

    /// **Un emplacement écrit mais pas encore nommé n'appartient à personne.**
    ///
    /// C'est l'application tuée entre les deux `pwrite`. À la réouverture, la
    /// carte est en retard d'une entrée : l'emplacement est ignoré, le secteur
    /// revient de la base, et le prochain secteur écrit reprend la place. Sans
    /// ça, un emplacement orphelin décalerait tous les suivants.
    func testASlotWrittenButNotYetNamedIsIgnored() throws {
        let baseURL = try base(sectors: 8)
        do {
            let store = try FileDiskStore(base: baseURL, writes: writes)
            XCTAssertTrue(store.write(at: 512, [UInt8](repeating: 0xAB, count: 512)))
            XCTAssertTrue(store.write(at: 1024, [UInt8](repeating: 0xCD, count: 512)))
            store.flush()
        }
        // La mort brutale : le second nom n'est jamais arrivé.
        let mapURL = URL(fileURLWithPath: writes.path + ".map")
        let map = try Data(contentsOf: mapURL)
        try map.prefix(16 + 8).write(to: mapURL)

        let reopened = try FileDiskStore(base: baseURL, writes: writes)
        XCTAssertEqual(reopened.read(at: 512, count: 2), [0xAB, 0xAB], "le premier tient")
        XCTAssertEqual(reopened.read(at: 1024, count: 2), [3, 3], "le second revient de la base")
        XCTAssertEqual(reopened.bytesWritten, 512)
        XCTAssertTrue(reopened.write(at: 2048, [UInt8](repeating: 0xEE, count: 512)))
        XCTAssertEqual(try Data(contentsOf: writes).count, 1024,
                       "le nouveau secteur a repris l'emplacement orphelin")
        XCTAssertEqual(reopened.read(at: 2048, count: 2), [0xEE, 0xEE])
    }

    /// Une couche qui vient d'un autre disque est refusée, nommément : son
    /// en-tête ne décrit pas celui-ci, et la lire donnerait des secteurs d'un
    /// autre fichier là où on attend ceux de la base.
    ///
    /// **L'en-tête, et non plus la taille.** Tant que la carte faisait un bit
    /// par secteur, sa taille identifiait le disque ; une carte tassée ne dit
    /// plus rien de la base, et deux disques du même nombre de secteurs
    /// seraient passés l'un pour l'autre.
    func testAnOverlayFromAnotherDiskIsRefused() throws {
        _ = try FileDiskStore(base: try base(sectors: 8), writes: writes)
        let other = try base(sectors: 16, named: "other.img")
        XCTAssertThrowsError(try FileDiskStore(base: other, writes: writes)) { error in
            XCTAssertEqual(error as? FileDiskStore.Failure, .overlayBelongsToAnotherDisk)
        }
        // Et un fichier qui n'est pas une carte du tout.
        let bogus = folder.appendingPathComponent("bogus.writes")
        try Data("pas une carte du tout".utf8)
            .write(to: URL(fileURLWithPath: bogus.path + ".map"))
        XCTAssertThrowsError(
            try FileDiskStore(base: try base(sectors: 8, named: "b.img"), writes: bogus)
        ) { error in
            XCTAssertEqual(error as? FileDiskStore.Failure, .overlayBelongsToAnotherDisk)
        }
    }

    /// Une base qui n'est pas un disque — moins d'un secteur — est refusée
    /// aussi, pour la raison que `LocalDisk` donne : l'invité verrait un disque
    /// de zéro secteur, ce qui est un piège et pas un disque.
    func testABaseSmallerThanASectorIsRefused() throws {
        let tiny = folder.appendingPathComponent("tiny")
        try Data([1, 2, 3]).write(to: tiny)
        XCTAssertThrowsError(try FileDiskStore(base: tiny, writes: writes)) { error in
            XCTAssertEqual(error as? FileDiskStore.Failure, .notADisk)
        }
    }

    /// **Une couche tronquée est refusée, pas devinée.** Un nom dont
    /// l'emplacement n'existe plus veut dire que le fichier des écritures a
    /// été coupé : rendre le secteur de la base à sa place serait servir un
    /// contenu périmé sans le dire, ce qu'un système de fichiers ne pardonne
    /// pas. C'est l'autre sens du désaccord — celui que l'ordre d'écriture ne
    /// peut pas produire.
    func testATruncatedOverlayIsRefusedRatherThanGuessed() throws {
        let baseURL = try base(sectors: 8)
        do {
            let store = try FileDiskStore(base: baseURL, writes: writes)
            XCTAssertTrue(store.write(at: 512, [UInt8](repeating: 0xAB, count: 512)))
            XCTAssertTrue(store.write(at: 1024, [UInt8](repeating: 0xCD, count: 512)))
            store.flush()
        }
        let content = try Data(contentsOf: writes)
        XCTAssertEqual(content.count, 1024)
        try content.prefix(512).write(to: writes)

        XCTAssertThrowsError(try FileDiskStore(base: baseURL, writes: writes)) { error in
            XCTAssertEqual(error as? FileDiskStore.Failure, .overlayIsTruncated)
        }
    }

    /// Une base absente est refusée avant qu'on ait créé la moindre couche.
    func testAMissingBaseIsRefusedAndLeavesNoOverlayBehind() {
        let missing = folder.appendingPathComponent("nope.img")
        XCTAssertThrowsError(try FileDiskStore(base: missing, writes: writes))
        XCTAssertFalse(FileManager.default.fileExists(atPath: writes.path))
    }

    // MARK: - À travers le périphérique

    /// **Le périphérique sert un disque sur fichier comme un disque en
    /// mémoire**, par la file, et l'écriture est là après réouverture.
    func testTheDeviceServesAFileBackedDiskAndTheWriteOutlivesIt() throws {
        let baseURL = try base(sectors: 8)
        let queue = VirtioQueue(base: 0)
        do {
            let device = VirtioBlock(store: try FileDiskStore(base: baseURL, writes: writes))
            let memory = X86Memory(size: 0x10000, base: 0)
            queue.start(device, memory)

            // Lire le secteur 5 : ses octets valent six.
            try queue.request(memory, kind: 0, sector: 5,
                              buffer: .init(at: 0x6000, length: 512, writable: true))
            device.write(0x050, 4, 0, memory)
            XCTAssertEqual(try queue.status(memory), 0)
            XCTAssertEqual(try memory.read(0x6000, 1), 6)
            XCTAssertEqual(try memory.read(0x6000 + 511, 1), 6)

            // Écrire le secteur 2 — après une nouvelle poignée de main, parce
            // que le harnais publie toujours la première entrée de l'anneau.
            queue.start(device, memory)
            for byte in 0..<UInt64(512) { try memory.write(0x7000 + byte, 1, 0xCD) }
            try queue.request(memory, kind: 1, sector: 2,
                              buffer: .init(at: 0x7000, length: 512, writable: false))
            device.write(0x050, 4, 0, memory)
            XCTAssertEqual(try queue.status(memory), 0)
            XCTAssertEqual(device.served, 2)
            device.flush()
        }
        let reopened = try FileDiskStore(base: baseURL, writes: writes)
        XCTAssertEqual(reopened.read(at: 2 * 512, count: 2), [0xCD, 0xCD], "l'écriture a survécu au périphérique")
        XCTAssertEqual(try Data(contentsOf: baseURL)[2 * 512], 3, "et la base n'a rien vu")
    }

    /// **L'instantané ne porte plus l'image.** Il porte les registres et une
    /// marque « le contenu vit ailleurs » ; la reprise se fait sur le store que
    /// l'application a rebranché. Sans ça, une machine avec un disque de six
    /// gigaoctets ferait un instantané de six gigaoctets à chaque passage en
    /// arrière-plan.
    func testASnapshotOfAFileBackedDiskIsSmallAndRestoresOntoTheStore() throws {
        let baseURL = try base(sectors: 8)
        let device = VirtioBlock(store: try FileDiskStore(base: baseURL, writes: writes))
        let memory = X86Memory(size: 0x10000, base: 0)
        let queue = VirtioQueue(base: 0)
        queue.start(device, memory)
        try queue.request(memory, kind: 0, sector: 1,
                          buffer: .init(at: 0x6000, length: 512, writable: true))
        device.write(0x050, 4, 0, memory)

        var writer = Snapshot.Writer()
        device.save(into: &writer)
        XCTAssertLessThan(writer.bytes.count, 512, "pas l'image : \(writer.bytes.count) octets")

        var reader = try Snapshot.Reader(writer.bytes)
        let store = try FileDiskStore(base: baseURL, writes: writes)
        let restored = try VirtioBlock.restored(from: &reader, keeping: store)
        XCTAssertTrue(reader.isAtEnd)
        XCTAssertEqual(restored.served, 1, "les registres sont revenus")
        XCTAssertTrue(restored.store === store, "et le contenu est celui qu'on a rebranché")
        XCTAssertEqual(restored.sectors, 8)
    }

    /// Une marque « ailleurs » sans store à rebrancher donne un disque de zéro
    /// secteur, pas un plantage : c'est le cas du fichier supprimé entre deux
    /// sessions, et l'invité verra des erreurs d'entrée-sortie, comme pour un
    /// disque qu'on a débranché.
    func testRestoringAnExternalDiskWithNothingToKeepGivesAnEmptyDisk() throws {
        let device = VirtioBlock(store: try FileDiskStore(base: try base(sectors: 8), writes: writes))
        var writer = Snapshot.Writer()
        device.save(into: &writer)
        var reader = try Snapshot.Reader(writer.bytes)
        let restored = try VirtioBlock.restored(from: &reader, keeping: nil)
        XCTAssertEqual(restored.sectors, 0)
    }

    /// Et un instantané d'avant — un disque en mémoire — se relit toujours
    /// tel quel : ceux des téléphones en dépendent.
    func testAMemoryDiskSnapshotStillCarriesItsImage() throws {
        let device = VirtioBlock(image: [UInt8](repeating: 0x42, count: 1024))
        var writer = Snapshot.Writer()
        device.save(into: &writer)
        var reader = try Snapshot.Reader(writer.bytes)
        let restored = try VirtioBlock.restored(from: &reader, keeping: nil)
        XCTAssertEqual(restored.image, [UInt8](repeating: 0x42, count: 1024))
    }
}
