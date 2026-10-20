import XCTest
@testable import WisqVM

/// Le lecteur XFS, sur un système rempli par le noyau et sur la vraie image
/// d'openSUSE.
final class XfsVolumeTests: XCTestCase {
    /// La fixture : la taille de l'image, et ses blocs non nuls par numéro.
    static let image: (size: Int, blocks: [Int: ArraySlice<UInt8>])? = {
        guard let packed = try? Zstd.decompress(XfsFixtures.version5), packed.count >= 12 else { return nil }
        func le(_ at: Int, _ width: Int) -> Int {
            (0..<width).reduce(0) { $0 | Int(packed[at + $1]) << (8 * $1) }
        }
        let size = le(0, 8), count = le(8, 4)
        var blocks: [Int: ArraySlice<UInt8>] = [:]
        for index in 0..<count {
            let start = 12 + 4 * count + 4096 * index
            blocks[le(12 + 4 * index, 4)] = packed[start..<(start + 4096)]
        }
        return (size, blocks)
    }()

    /// Les octets de la fixture, `patch` appliqué par-dessus — pour abîmer un
    /// superbloc sans refaire l'image.
    static func fixture(patch: [Int: UInt8] = [:]) throws -> XfsVolume {
        let image = try XCTUnwrap(Self.image)
        return try XfsVolume(size: UInt64(image.size)) { offset, count in
            guard offset + UInt64(count) <= UInt64(image.size) else { return nil }
            var bytes = [UInt8](repeating: 0, count: count)
            var position = Int(offset)
            while position < Int(offset) + count {
                let block = position / 4096, within = position % 4096
                let take = min(4096 - within, Int(offset) + count - position)
                if let stored = image.blocks[block] {
                    let from = stored.startIndex + within
                    bytes.replaceSubrange((position - Int(offset))..<(position - Int(offset) + take),
                                          with: stored[from..<(from + take)])
                }
                position += take
            }
            for (at, value) in patch where at >= Int(offset) && at < Int(offset) + count {
                bytes[at - Int(offset)] = value
            }
            return bytes
        }
    }

    static let court = Array("wisq lit xfs\n".utf8)

    /// Le superbloc : l'étiquette, un UUID écrit comme `blkid`, les tailles.
    func testTheSuperblockGivesItsLabelAndUUID() throws {
        let volume = try Self.fixture()
        XCTAssertEqual(volume.label, "essai")
        XCTAssertEqual(volume.uuid.count, 36)
        XCTAssertEqual(volume.blockSize, 4096)
        XCTAssertTrue(volume.fileTypes, "mkfs.xfs met le type dans les entrées")
    }

    /// **Un fichier en extents, un fichier vide, un fichier troué rangé en
    /// arbre** — ses trous se lisent en zéros, ses octets à leur place — et
    /// des blocs réservés jamais écrits, qui se lisent en zéros eux aussi.
    func testExtentEmptyAndTreeFilesComeBack() throws {
        let volume = try Self.fixture()
        XCTAssertEqual(try volume.contents(of: "/etc/court"), Self.court)
        XCTAssertEqual(try volume.contents(of: "/etc/vide"), [])
        XCTAssertEqual(try volume.contents(of: "/boot/noyau"), BtrfsVolumeTests.letters(12000))
        XCTAssertEqual(try volume.inode(volume.resolve("/boot/troue").number).format, 3, "un arbre d'extents")
        var expected = [UInt8](repeating: 0, count: 199 * 8192 + 1)
        for index in 0..<200 { expected[index * 8192] = UInt8(65 + index % 26) }
        XCTAssertEqual(try volume.contents(of: "/boot/troue"), expected)
        // Des « Z » sous les blocs réservés : ils se lisent en zéros quand même.
        let reserve = try volume.resolve("/boot/reserve")
        let unwritten = try XCTUnwrap(try volume.extents(of: reserve).first { $0.unwritten })
        let under = Int(volume.byteOffset(ofBlock: unwritten.block))
        let scribbled = try Self.fixture(patch: Dictionary(uniqueKeysWithValues: (under..<(under + 4096)).map { ($0, 90) }))
        var reserved = [UInt8](repeating: 0, count: 1 << 20)
        reserved.replaceSubrange(0..<5, with: Array("debut".utf8))
        XCTAssertEqual(try scribbled.contents(of: "/boot/reserve"), reserved)
        XCTAssertEqual(String(decoding: try volume.contents(of: "/boot/loader/entries/a.conf"), as: UTF8.self),
                       "title openSUSE\nlinux /boot/noyau\ninitrd /etc/court\noptions root=UUID=x\n")
    }

    /// **Chaque forme de répertoire** : en ligne (`/etc`), en un bloc
    /// (`/grand`), et `/immense`, dont les trois mille entrées tiennent dans
    /// plusieurs blocs de données rangés par un arbre.
    func testEveryDirectoryFormListsItsEntries() throws {
        let volume = try Self.fixture()
        XCTAssertEqual(try volume.resolve("/etc").format, 1)
        XCTAssertEqual(try volume.resolve("/grand").format, 2)
        XCTAssertEqual(try volume.resolve("/immense").format, 3)
        XCTAssertEqual(Set(try volume.list("/etc").map(\.name)), ["court", "vide"])
        XCTAssertEqual(try volume.list("/grand").map(\.name).sorted(), (0..<40).map { String(format: "f%03d", $0) })
        let immense = try volume.list("/immense")
        XCTAssertEqual(immense.count, 3000)
        XCTAssertEqual(Set(immense.map(\.name)).count, 3000)
        XCTAssertTrue(immense.allSatisfy { $0.kind == .file })
        XCTAssertEqual(try volume.contents(of: "/immense/fichier-au-nom-assez-long-02999"),
                       Array("le dernier\n".utf8))
        XCTAssertEqual(try volume.list("/vide"), [])
        let top = try volume.list("/")
        XCTAssertEqual(Set(top.map(\.name)), ["boot", "etc", "grand", "immense", "lien-absolu", "lien-long", "vide"])
        XCTAssertEqual(top.first { $0.name == "lien-absolu" }?.kind, .symlink)
        XCTAssertEqual(top.first { $0.name == "boot" }?.kind, .directory)
    }

    /// Les liens, relatifs et absolus, en ligne ou dans un bloc, sont suivis.
    func testLinksAreFollowed() throws {
        let volume = try Self.fixture()
        XCTAssertEqual(try volume.contents(of: "/boot/lien-relatif"), Self.court)
        XCTAssertEqual(try volume.contents(of: "/lien-absolu"), Self.court)
        // Relatif à son répertoire : `noyau` n'existe que dans `/boot`.
        XCTAssertEqual(try volume.contents(of: "/boot/lien-local"), BtrfsVolumeTests.letters(12000))
        XCTAssertEqual(try volume.resolve("/").number, volume.rootInode)
        let long = try volume.linkTarget(volume.inode(Self.childInode(volume, "lien-long")))
        XCTAssertEqual(long.count, 609)
        XCTAssertEqual(try volume.contents(of: "/lien-long"), Self.court)
        XCTAssertTrue(volume.exists("/boot/loader/entries"))
        XCTAssertFalse(volume.exists("/boot/absent"))
    }

    static func childInode(_ volume: XfsVolume, _ name: String) throws -> UInt64 {
        // Le lien lui-même, sans le suivre : `resolve` du répertoire, puis
        // la recherche de l'entrée.
        let root = try volume.inode(volume.rootInode)
        let link = try XCTUnwrap(try volume.entries(of: root).first { $0.name == name })
        return link.inode
    }

    /// **Ce qui ne se lit pas le dit** : un chemin absent, un répertoire lu
    /// comme un fichier, une partition qui n'est pas un XFS, une fonction
    /// inconnue, une version 4.
    func testWhatCannotBeReadSaysSo() throws {
        let volume = try Self.fixture()
        XCTAssertThrowsError(try volume.contents(of: "/boot/absent")) {
            XCTAssertEqual($0 as? XfsVolume.Failure, .notFound("/boot/absent"))
        }
        XCTAssertThrowsError(try volume.contents(of: "/boot")) {
            XCTAssertEqual($0 as? XfsVolume.Failure, .notAFile("/boot"))
        }
        XCTAssertThrowsError(try volume.list("/etc/court/x")) {
            XCTAssertEqual($0 as? XfsVolume.Failure, .notADirectory("/etc/court/x"))
        }
        let zeros = [UInt8](repeating: 0, count: 1 << 20)
        XCTAssertThrowsError(try XfsVolume(size: UInt64(zeros.count)) { offset, count in
            Array(zeros[Int(offset)..<(Int(offset) + count)])
        }) { XCTAssertEqual($0 as? XfsVolume.Failure, .notXfs) }
        // Les pointeurs vers le parent (0x80), qu'active openSUSE : acceptés.
        let image = try XCTUnwrap(Self.image)
        let first = try XCTUnwrap(image.blocks[0])
        XCTAssertEqual(try Self.fixture(patch: [219: first[first.startIndex + 219] | 0x80]).contents(of: "/etc/court"),
                       Self.court)
        // L'octet de poids fort des fonctions incompatibles.
        XCTAssertThrowsError(try Self.fixture(patch: [216: 0x80])) {
            XCTAssertEqual($0 as? XfsVolume.Failure, .unsupported("une fonction inconnue (0x80000000)"))
        }
        // Le quartet bas de `versionnum`, à l'octet 101.
        let version = first[first.startIndex + 101]
        XCTAssertThrowsError(try Self.fixture(patch: [101: version & 0xF0 | 4])) {
            XCTAssertEqual($0 as? XfsVolume.Failure, .unsupported("la version 4"))
        }
    }

    /// **`linuxVolume` reconnaît un XFS** derrière ext4 et btrfs, et une
    /// partition qui n'est rien garde l'erreur d'ext4.
    func testLinuxVolumeFindsAnXfsPartition() throws {
        let image = try XCTUnwrap(Self.image)
        var bytes = [UInt8](repeating: 0, count: image.size)
        for (block, stored) in image.blocks { bytes.replaceSubrange((block * 4096)..<(block * 4096 + 4096), with: stored) }
        func partition(_ length: Int) -> PartitionTable.Partition {
            PartitionTable.Partition(number: 3, kind: .linuxRoot, start: 0, length: UInt64(length), name: "",
                                     uniqueID: "")
        }
        let volume = try linuxVolume(partition(bytes.count), in: MemoryDisk(bytes))
        XCTAssertTrue(volume is XfsVolume)
        XCTAssertEqual(try volume.contents(of: "/lien-absolu"), Self.court)
        XCTAssertThrowsError(try linuxVolume(partition(1 << 20), in: MemoryDisk([UInt8](repeating: 0, count: 1 << 20)))) {
            XCTAssertTrue($0 is Ext4Volume.Failure, "\($0)")
        }
    }

    private final class MemoryDisk: VirtualDiskImage, @unchecked Sendable {
        let bytes: [UInt8]
        init(_ bytes: [UInt8]) { self.bytes = bytes }
        var virtualSize: UInt64 { UInt64(bytes.count) }
        func read(into buffer: inout [UInt8], at offset: UInt64) -> Bool {
            guard offset + UInt64(buffer.count) <= virtualSize else { return false }
            buffer = Array(bytes[Int(offset)..<(Int(offset) + buffer.count)])
            return true
        }
    }

    /// **`/boot` d'openSUSE Tumbleweed**, la partition XFS brute de l'image
    /// « Minimal-VM » : le noyau et l'initramfs que `CloudBoot` y cherche.
    /// Armé par `WISQ_XFS_IMAGE`.
    func testTheRealOpenSUSEBootIsReadable() throws {
        guard let path = ProcessInfo.processInfo.environment["WISQ_XFS_IMAGE"] else {
            throw XCTSkip("définir WISQ_XFS_IMAGE pour ce test")
        }
        let handle = try XCTUnwrap(FileHandle(forReadingAtPath: path))
        let size = try handle.seekToEnd()
        let volume = try XfsVolume(size: size) { offset, count in
            try? handle.seek(toOffset: offset)
            guard let data = try? handle.read(upToCount: count), data.count == count else { return nil }
            return [UInt8](data)
        }
        let boot = try volume.list("/boot").map(\.name)
        XCTAssertTrue(boot.contains { $0.hasPrefix("vmlinuz-") }, "\(boot)")
        XCTAssertTrue(boot.contains { $0.hasPrefix("initrd-") }, "\(boot)")
        let kernel = try volume.contents(of: "/boot/vmlinuz")
        XCTAssertEqual(Array(kernel[0x202..<0x206]), Array("HdrS".utf8), "un bzImage")
        XCTAssertGreaterThan(try volume.list("/usr/bin").count, 100)
    }
}
