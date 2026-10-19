import XCTest
@testable import WisqVM

/// Le lecteur btrfs, sur des systèmes écrits par `mkfs.btrfs` et sur la vraie
/// image de Fedora.
final class BtrfsVolumeTests: XCTestCase {
    /// Un fichier de partition brute, lu comme une partition.
    static func volume(at path: String) throws -> BtrfsVolume {
        let handle = try XCTUnwrap(FileHandle(forReadingAtPath: path))
        let size = try handle.seekToEnd()
        return try BtrfsVolume(size: size) { offset, count in
            try? handle.seek(toOffset: offset)
            guard let data = try? handle.read(upToCount: count), data.count == count else { return nil }
            return [UInt8](data)
        }
    }

    /// La fixture : la taille de l'image, et ses blocs non nuls par numéro.
    static let image: (size: Int, blocks: [Int: ArraySlice<UInt8>])? = {
        guard let packed = try? Zstd.decompress(BtrfsFixtures.sparseImage), packed.count >= 12 else { return nil }
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

    /// Le btrfs de la fixture, ouvert : les blocs rangés, et des zéros ailleurs.
    static func fixture() throws -> BtrfsVolume {
        let image = try XCTUnwrap(Self.image)
        return try BtrfsVolume(size: UInt64(image.size)) { offset, count in
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
            return bytes
        }
    }

    /// Les douze mille lettres de `/boot/noyau`, du même générateur que le
    /// script qui a écrit la fixture.
    static func letters(_ count: Int) -> [UInt8] {
        var x: UInt64 = 1
        return (0..<count).map { _ in
            x = (x &* 1_103_515_245 &+ 12345) & 0x7FFF_FFFF
            return UInt8(97 + (x >> 16) % 26)
        }
    }

    /// Le superbloc : l'étiquette, et un UUID écrit comme `blkid`.
    func testTheSuperblockGivesItsLabelAndUUID() throws {
        let volume = try Self.fixture()
        XCTAssertEqual(volume.label, "essai")
        XCTAssertEqual(volume.uuid.count, 36)
        XCTAssertEqual(volume.nodeSize, 16384)
        XCTAssertEqual(try volume.subvolumes(), [:], "aucun sous-volume dans la fixture")
    }

    /// **Un fichier en ligne et un fichier dans un extent ordinaire**, et un
    /// fichier vide, qui n'a pas d'extent du tout.
    func testInlineRegularAndEmptyFilesComeBack() throws {
        let volume = try Self.fixture()
        XCTAssertEqual(try volume.contents(of: "/etc/court"), Array("wisq lit btrfs\n".utf8))
        XCTAssertEqual(try volume.contents(of: "/boot/noyau"), Self.letters(12000))
        XCTAssertEqual(try volume.contents(of: "/etc/vide"), [])
        XCTAssertEqual(String(decoding: try volume.contents(of: "/boot/loader/entries/a.conf"), as: UTF8.self),
                       "title Fedora\nlinux /noyau\noptions root=UUID=x rootflags=subvol=root\n")
    }

    /// Les liens symboliques, relatifs et absolus, sont suivis ; et un
    /// répertoire se liste avec la nature de chaque entrée.
    func testLinksAreFollowedAndDirectoriesListed() throws {
        let volume = try Self.fixture()
        XCTAssertEqual(try volume.contents(of: "/boot/lien-relatif"), Array("wisq lit btrfs\n".utf8))
        XCTAssertEqual(try volume.contents(of: "/lien-absolu"), Array("wisq lit btrfs\n".utf8))
        // Un lien relatif se lit depuis son répertoire, pas depuis le sommet :
        // `noyau` n'existe que dans `/boot`.
        XCTAssertEqual(try volume.contents(of: "/boot/lien-local"), Self.letters(12000))
        let top = try volume.list("/")
        XCTAssertEqual(Set(top.map(\.name)), ["boot", "etc", "lien-absolu", "vide"])
        XCTAssertEqual(top.first { $0.name == "lien-absolu" }?.kind, .symlink)
        XCTAssertEqual(top.first { $0.name == "boot" }?.kind, .directory)
        XCTAssertEqual(try volume.list("/vide"), [])
        XCTAssertTrue(volume.exists("/boot/loader/entries"))
        XCTAssertFalse(volume.exists("/boot/absent"))
    }

    /// **Ce qui ne se lit pas le dit**, et une partition qui n'est pas un
    /// btrfs n'en est pas un.
    func testWhatCannotBeReadSaysSo() throws {
        let volume = try Self.fixture()
        XCTAssertThrowsError(try volume.contents(of: "/boot/absent")) {
            XCTAssertEqual($0 as? BtrfsVolume.Failure, .notFound("/boot/absent"))
        }
        XCTAssertThrowsError(try volume.contents(of: "/boot")) {
            XCTAssertEqual($0 as? BtrfsVolume.Failure, .notAFile("/boot"))
        }
        XCTAssertThrowsError(try volume.list("/etc/court/x")) {
            XCTAssertEqual($0 as? BtrfsVolume.Failure, .notADirectory("/etc/court/x"))
        }
        let zeros = [UInt8](repeating: 0, count: 1 << 20)
        XCTAssertThrowsError(try BtrfsVolume(size: UInt64(zeros.count)) { offset, count in
            Array(zeros[Int(offset)..<(Int(offset) + count)])
        }) { XCTAssertEqual($0 as? BtrfsVolume.Failure, .notBtrfs) }
    }

    /// **Chaque fichier du sous-volume `boot` de Fedora 44**, identique à ce
    /// qu'en extrait `btrfs restore`. Armé par `WISQ_BTRFS_IMAGE` (la
    /// partition btrfs brute) et `WISQ_BTRFS_REFERENCE` (le dossier extrait).
    func testTheRealFedoraBootSubvolumeMatchesBtrfsRestore() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let image = environment["WISQ_BTRFS_IMAGE"], let reference = environment["WISQ_BTRFS_REFERENCE"] else {
            throw XCTSkip("définir WISQ_BTRFS_IMAGE et WISQ_BTRFS_REFERENCE pour ce test")
        }
        let volume = try Self.volume(at: image)
        XCTAssertEqual(volume.label, "fedora")
        XCTAssertEqual(try volume.subvolumes().keys.sorted(), ["boot", "home", "root", "var"])
        let walker = try XCTUnwrap(FileManager.default.enumerator(atPath: reference))
        var compared = 0
        while let relative = walker.nextObject() as? String {
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: reference + "/" + relative, isDirectory: &isDirectory)
            if isDirectory.boolValue { continue }
            let expected = try [UInt8](Data(contentsOf: URL(fileURLWithPath: reference + "/" + relative)))
            XCTAssertEqual(try volume.contents(of: "/boot/" + relative), expected, relative)
            compared += 1
        }
        XCTAssertGreaterThan(compared, 10)
    }
}
