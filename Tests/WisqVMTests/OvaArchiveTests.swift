import XCTest
@testable import WisqVM

/// Le disque d'une appliance OVA, lu dans l'archive : contre des archives de
/// GNU tar dans ses trois formats, et des décalages relevés par le module
/// `tarfile` de Python plutôt que par ce code.
final class OvaArchiveTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("wisq-ova-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func bytes(_ base64: String, size: Int) throws -> [UInt8] {
        let packed = try XCTUnwrap(Data(base64Encoded: base64))
        return try XCTUnwrap(Inflate.raw([UInt8](packed), limit: size, exact: true))
    }

    private func file(_ bytes: [UInt8], name: String) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url
    }

    private func archive(_ base64: String, size: Int, name: String) throws -> URL {
        try file(bytes(base64, size: size), name: name)
    }

    private func members(_ url: URL) throws -> [OvaArchive.Member] {
        let fd = open(url.path, O_RDONLY)
        defer { close(fd) }
        return try OvaArchive.members(of: fd)
    }

    private func disk(_ url: URL) throws -> any VirtualDiskImage {
        let fd = open(url.path, O_RDONLY)
        let image: (any VirtualDiskImage)?
        do { image = try VirtualDiskImages.image(takingOwnershipOf: fd) } catch { close(fd); throw error }
        return try XCTUnwrap(image)
    }

    static let long = "un-nom-de-disque-bien-plus-long-que-les-cent-octets-que-le-champ-ustar"
        + "-garde-pour-un-nom-de-fichier-disk1.vmdk"

    /// Les trois formats de tar rangent le même disque à des places
    /// différentes, et un nom trop long pour l'en-tête de trois façons
    /// différentes : ustar tel quel, pax dans un en-tête étendu, GNU dans un
    /// membre `L`. Les décalages sont ceux que lit `tarfile` — et, pour les
    /// dates de GNU, ceux de `tar tvf`, puisque `tarfile` s'y trompe.
    func testEveryTarFormatGivesTheMembersWhereTarfileFindsThem() throws {
        let cases: [(String, Int, String, UInt64, UInt64, String)] = [
            (OvaFixtures.a, 81920, "appliance-disk1.vmdk", 1536, 72192, "ustar"),
            (OvaFixtures.b, 143_360, Self.long, 3584, 132_096, "pax"),
            (OvaFixtures.c, 143_360, Self.long, 2560, 132_096, "gnu"),
            // La taille dans l'en-tête pax seulement, l'en-tête du membre
            // disant 0 : ce que porte un disque de plus de 8 Gio.
            (OvaFixtures.g, 81920, "appliance-disk1.vmdk", 2560, 72192, "pax, taille"),
            // Des dates là où ustar met son préfixe : elles ne sont pas un
            // morceau du nom.
            (OvaFixtures.h, 143_360, Self.long, 2560, 132_096, "gnu, dates"),
        ]
        for (fixture, size, name, offset, length, label) in cases {
            let found = try members(archive(fixture, size: size, name: "\(label).ova"))
            XCTAssertEqual(found.map(\.name), ["appliance.ovf", name], label)
            XCTAssertEqual(found.last, OvaArchive.Member(name: name, offset: offset, length: length), label)
            XCTAssertEqual(found.first?.name, "appliance.ovf", label)
        }
    }

    /// Le disque se lit **dans** l'archive, et rend le disque d'origine octet
    /// pour octet — répertoire en fin de fichier (ustar) comme en tête (pax,
    /// gnu).
    func testTheDiskReadsInPlaceAndGivesTheOriginalBytes() throws {
        let archives = [(OvaFixtures.a, 81920, "ustar"), (OvaFixtures.b, 143_360, "pax"),
                        (OvaFixtures.c, 143_360, "gnu"), (OvaFixtures.g, 81920, "pax, taille")]
        for (fixture, size, label) in archives {
            let image = try disk(archive(fixture, size: size, name: "\(label).ova"))
            XCTAssertEqual(image.virtualSize, 1 << 20, label)
            var out = [UInt8](repeating: 0xEE, count: 1 << 20)
            XCTAssertTrue(image.read(into: &out, at: 0), label)
            XCTAssertEqual(out, Qcow2ImageTests.original, label)
        }
    }

    /// Une appliance est reconnue à son premier membre ; un tar dont le
    /// premier membre n'est pas un descripteur OVF n'en est pas une, même
    /// avec un VMDK dedans.
    func testAnApplianceIsRecognisedAndAPlainTarIsNot() throws {
        let ova = try archive(OvaFixtures.a, size: 81920, name: "appliance.ova")
        XCTAssertEqual(KernelImageKind.identify(fileAt: ova), .virtualDisk("OVA"))
        XCTAssertTrue(LocalDisk.isDiskImage(.virtualDisk("OVA")))
        XCTAssertEqual(LibraryEntry.role(of: .virtualDisk("OVA")), .disk("OVA"))
        let pax = try archive(OvaFixtures.b, size: 143_360, name: "pax.ova")
        XCTAssertEqual(KernelImageKind.identify(fileAt: pax), .virtualDisk("OVA"),
                       "l'en-tête étendu de pax porte le nom du descripteur")
        let plain = try archive(OvaFixtures.f, size: 81920, name: "disque.tar")
        XCTAssertEqual(KernelImageKind.identify(fileAt: plain), .unknown)
        XCTAssertFalse(VirtualDiskImages.recognizes(fileAt: plain))
        XCTAssertThrowsError(try members(plain)) {
            XCTAssertEqual($0 as? OvaArchive.Refusal, .notOva, "lu directement, il est refusé aussi")
        }
    }

    /// Ce qu'on ne lit pas en place est refusé, et nommé : un disque compressé
    /// en gzip, une appliance sans disque, un en-tête abîmé, une archive
    /// coupée au milieu de son disque.
    func testWhatCannotBeReadInPlaceIsRefusedByName() throws {
        func refusal(_ url: URL) -> OvaArchive.Refusal? {
            do { _ = try disk(url); return nil } catch { return error as? OvaArchive.Refusal }
        }
        XCTAssertEqual(refusal(try archive(OvaFixtures.d, size: 10240, name: "gz.ova")),
                       .diskNotReadableInPlace("gz.vmdk"))
        XCTAssertEqual(refusal(try archive(OvaFixtures.e, size: 10240, name: "vide.ova")), .noDisk)
        let good = try bytes(OvaFixtures.a, size: 81920)
        var damaged = good
        damaged[1024 + 10] ^= 0x01
        XCTAssertEqual(refusal(try file(damaged, name: "abime.ova")),
                       .malformed("somme d'en-tête fausse"))
        XCTAssertEqual(refusal(try file(Array(good[0..<(1536 + 4096)]), name: "coupe.ova")),
                       .malformed("membre hors du fichier"))
        var first = good
        first[0] ^= 0x01
        XCTAssertFalse(OvaArchive.looksLikeOne(first), "la somme du premier en-tête aussi")
    }

    /// Le lecteur ne sort pas du membre : un membre qui déborderait de
    /// l'archive est refusé, et un VMDK lu dans un membre trop court ne va pas
    /// chercher son pied dans les octets qui suivent.
    func testTheDiskStaysInsideItsMember() throws {
        let fd = open(try archive(OvaFixtures.a, size: 81920, name: "a.ova").path, O_RDONLY)
        XCTAssertThrowsError(try VmdkImage(takingOwnershipOf: fd, member: (1536, 81000))) {
            XCTAssertEqual($0 as? VmdkImage.Refusal, .malformed("le disque déborde de l'archive"))
        }
        // Le membre amputé de son pied : le pied cherché à la fin du membre
        // n'est plus là, même si l'archive continue.
        XCTAssertThrowsError(try VmdkImage(takingOwnershipOf: fd, member: (1536, 72192 - 512))) {
            XCTAssertEqual($0 as? VmdkImage.Refusal,
                           .malformed("répertoire annoncé en fin de fichier, pied absent"))
        }
        close(fd)
    }

    /// La machine branchée sur l'appliance : la couche se pose dessus, et
    /// **l'archive ne change pas d'un octet**.
    func testTheOverlayWritesOnTopAndTheArchiveNeverChanges() throws {
        let base = try archive(OvaFixtures.a, size: 81920, name: "appliance.ova")
        let before = try Data(contentsOf: base)
        let writes = folder.appendingPathComponent("appliance.writes")
        do {
            let store = try FileDiskStore(base: base, writes: writes)
            XCTAssertEqual(store.sectors, (1 << 20) / 512)
            XCTAssertTrue(store.write(at: 70_010, [0xCA, 0xFE]))
            store.flush()
        }
        let store = try FileDiskStore(base: base, writes: writes)
        var expected = Qcow2ImageTests.original
        expected[70_010] = 0xCA
        expected[70_011] = 0xFE
        XCTAssertEqual(store.read(at: 0, count: 1 << 20), expected)
        XCTAssertEqual(try Data(contentsOf: base), before)
        XCTAssertThrowsError(try FileDiskStore(
            base: try archive(OvaFixtures.d, size: 10240, name: "gz.ova"),
            writes: folder.appendingPathComponent("w"))) {
            XCTAssertEqual($0 as? FileDiskStore.Failure, .unreadableImage(
                OvaArchive.Refusal.diskNotReadableInPlace("gz.vmdk").errorDescription!))
        }
    }

    /// **Le descripteur choisit le disque.** L'appliance de VirtualBox a deux
    /// disques : `donnees.vmdk`, 2 Gio, premier dans l'archive et dans
    /// `DiskSection` ; `systeme.vmdk`, 1 Mio, que le matériel branche en
    /// premier. C'est sur lui qu'elle démarre, et c'est lui qui est lu.
    func testTheDescriptorChoosesTheDiskTheApplianceBootsOn() throws {
        let url = try archive(OvaFixtures.i, size: 471_040, name: "deux.ova")
        XCTAssertEqual(try members(url).map(\.name), ["appliance.ovf", "donnees.vmdk", "systeme.vmdk"])
        let image = try disk(url)
        XCTAssertEqual(image.virtualSize, 1 << 20, "le système, pas les données")
        var out = [UInt8](repeating: 0, count: 1 << 20)
        XCTAssertTrue(image.read(into: &out, at: 0))
        XCTAssertEqual(out, Qcow2ImageTests.original)
    }

    /// Une archive faite par `tar -cf x.ova ./appliance.ovf ./disque.vmdk`
    /// range ses membres sous `./` ; le descripteur, lui, nomme le fichier
    /// sans. C'est le même fichier.
    func testAMemberUnderDotSlashIsTheFileTheDescriptorNames() throws {
        let url = try archive(OvaFixtures.k, size: 81920, name: "point.ova")
        XCTAssertEqual(try members(url).map(\.name), ["./appliance.ovf", "./appliance-disk1.vmdk"])
        XCTAssertEqual(try disk(url).virtualSize, 1 << 20)
    }

    /// Un descripteur qui démarre sur un fichier que l'archive n'a pas : le
    /// refus le nomme, plutôt que de démarrer sur un autre disque sans le
    /// dire.
    func testADescriptorNamingAMissingDiskIsRefusedByName() throws {
        let url = try archive(OvaFixtures.j, size: 81920, name: "absent.ova")
        XCTAssertThrowsError(try disk(url)) {
            XCTAssertEqual($0 as? OvaArchive.Refusal, .missingDisk("absent.vmdk"))
        }
    }

    /// La taille en base 256, que GNU écrit au-delà de 8 Gio — l'octal n'y
    /// tient plus — et un champ octal précédé d'espaces.
    func testBothWaysOfWritingASizeAreRead() throws {
        var header = [UInt8](repeating: 0, count: 512)
        header[124] = 0x80
        header[131] = 0x02
        header[135] = 0x01
        XCTAssertEqual(try OvaArchive.size(header), (2 << 32) + 1)
        header.replaceSubrange(124..<136, with: Array("  0000001750 ".utf8.prefix(12)))
        XCTAssertEqual(try OvaArchive.size(header), 0o1750)
        header.replaceSubrange(124..<136, with: Array("00000009000\0".utf8))
        XCTAssertThrowsError(try OvaArchive.size(header), "9 n'est pas octal")
    }
}
