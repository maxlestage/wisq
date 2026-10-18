import XCTest
@testable import WisqVM
import WisqVMTestKit

/// Le lecteur ext2/ext4 : deux systèmes de fichiers écrits par e2fsprogs, les
/// mêmes fichiers dans chacun, et ce qu'on doit y lire.
final class Ext4VolumeTests: XCTestCase {
    /// Le motif dont `scripts/build-ext4-fixtures.py` remplit les fichiers.
    private func pattern(_ count: Int, _ seed: Int) -> [UInt8] {
        (0..<count).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ ($0 >> 9) &+ seed) }
    }

    private func volume(_ base64: String, patch: ((inout [UInt8]) -> Void)? = nil) throws -> Ext4Volume {
        let packed = try XCTUnwrap(Data(base64Encoded: base64))
        var bytes = try XCTUnwrap(Qcow2Image.inflateRaw([UInt8](packed), expected: Ext4Fixtures.size))
        patch?(&bytes)
        let disk = bytes
        return try Ext4Volume(size: UInt64(disk.count)) { offset, count in
            guard offset + UInt64(count) <= UInt64(disk.count) else { return nil }
            return Array(disk[Int(offset)..<(Int(offset) + count)])
        }
    }

    private var both: [(String, Ext4Volume)] {
        get throws { [("ext4", try volume(Ext4Fixtures.ext4)), ("ext2", try volume(Ext4Fixtures.ext2))] }
    }

    /// Ce que l'image de cloud demande : le noyau, l'initramfs et le
    /// `grub.cfg` qui les nomme, octet pour octet. En ext4, le noyau tient
    /// dans un extent ; en ext2 à blocs d'un kilo-octet, ses 293 blocs passent
    /// par un bloc d'adresses et un bloc de blocs d'adresses.
    func testTheKernelAndItsInitramfsAreReadWhole() throws {
        for (name, volume) in try both {
            XCTAssertEqual(try volume.contents(of: "/boot/vmlinuz-6.1.0-test"), pattern(300_000, 1), name)
            XCTAssertEqual(try volume.contents(of: "/boot/initrd.img-6.1.0-test"), pattern(70_000, 2), name)
            let grub = String(decoding: try volume.contents(of: "/boot/grub/grub.cfg"), as: UTF8.self)
            XCTAssertTrue(grub.contains("linux\t/boot/vmlinuz-6.1.0-test root=/dev/vda1 ro"), name)
            XCTAssertEqual(Set(try volume.list("/boot").map(\.name)),
                           ["grub", "vmlinuz-6.1.0-test", "initrd.img-6.1.0-test", "sparse", "current", "reserved"],
                           name)
            XCTAssertEqual(try volume.list("/boot").first { $0.name == "grub" }?.kind, .directory, name)
        }
    }

    /// L'identité du système de fichiers : ce que vise un `root=UUID=…`.
    func testTheUUIDAndTheLabelAreThoseMkfsWasGiven() throws {
        let ext4 = try volume(Ext4Fixtures.ext4)
        XCTAssertEqual(ext4.uuid, "13223055-e9dd-4810-96ca-8fe4d0ef1d49")
        XCTAssertEqual(ext4.label, "wisq-ext4")
        XCTAssertEqual(ext4.blockSize, 4096)
        let ext2 = try volume(Ext4Fixtures.ext2)
        XCTAssertEqual(ext2.uuid, "2b0f3e8a-1c2d-4e5f-8a9b-0c1d2e3f4a5b")
        XCTAssertEqual(ext2.blockSize, 1024)
    }

    /// Les liens : relatif et court (`/vmlinuz`, comme Debian en posait),
    /// absolu avec des `.` et des `..` en route, relatif qui remonte d'un
    /// répertoire. Deux liens qui se renvoient l'un à l'autre s'arrêtent au
    /// quarantième, et un lien long (plus de 60 octets, rangé dans un bloc)
    /// se lit lui aussi, même s'il ne mène nulle part.
    func testSymbolicLinksAreFollowedTheWayLinuxDoes() throws {
        for (name, volume) in try both {
            XCTAssertEqual(try volume.contents(of: "/vmlinuz"), pattern(300_000, 1), name)
            XCTAssertEqual(try volume.contents(of: "/initrd.img"), pattern(70_000, 2), name)
            XCTAssertEqual(try volume.contents(of: "/etc/initrd-relative"), pattern(70_000, 2), name)
            // Relatif, rangé dans `boot` : il se lit depuis `boot`.
            XCTAssertEqual(try volume.contents(of: "/boot/current"), pattern(300_000, 1), name)
            XCTAssertThrowsError(try volume.contents(of: "/loop-a")) { error in
                XCTAssertEqual(error as? Ext4Volume.Failure, .tooManyLinks("/loop-a"), name)
            }
            XCTAssertThrowsError(try volume.contents(of: "/dangling-long")) { error in
                XCTAssertEqual(error as? Ext4Volume.Failure, .notFound("/dangling-long"), name)
            }
            XCTAssertFalse(volume.exists("/dangling-long"), name)
            XCTAssertTrue(volume.exists("boot/./grub/../vmlinuz-6.1.0-test"), name)
        }
    }

    /// Un fichier creux : six îlots de 4 Kio à 100 Kio d'écart, et des zéros
    /// entre eux. En ext4, six extents ne tiennent pas dans l'inode, et
    /// l'arbre prend un niveau d'index ; en ext2, les trous sont des adresses
    /// nulles, jusque dans le bloc d'adresses.
    func testASparseFileReadsItsHolesAsZeros() throws {
        // Le premier bloc de l'ext2, que le système de fichiers n'utilise pas,
        // rempli : un trou lu comme « le bloc zéro » ne rendrait plus des zéros.
        let ext2 = try volume(Ext4Fixtures.ext2) { bytes in
            for index in 0..<1024 { bytes[index] = 0xAA }
        }
        for (name, volume) in [("ext4", try volume(Ext4Fixtures.ext4)), ("ext2", ext2)] {
            let bytes = try volume.contents(of: "/boot/sparse")
            XCTAssertEqual(bytes.count, 6 * 100 * 1024, name)
            for island in 0..<6 {
                let start = island * 100 * 1024
                XCTAssertEqual(Array(bytes[start..<(start + 4096)]), pattern(4096, 10 + island), "\(name) \(island)")
                if island < 5 {
                    XCTAssertTrue(bytes[(start + 4096)..<(start + 100 * 1024)].allSatisfy { $0 == 0 },
                                  "\(name) \(island)")
                }
            }
        }
    }

    /// Des blocs réservés par `fallocate` mais jamais écrits se lisent comme
    /// des zéros, quoi qu'il y ait sur le disque à leur place.
    func testUnwrittenExtentsReadAsZeros() throws {
        let bytes = try volume(Ext4Fixtures.ext4).contents(of: "/boot/reserved")
        XCTAssertEqual(bytes.count, 20480)
        XCTAssertEqual(Array(bytes[0..<4096]), pattern(4096, 3))
        XCTAssertTrue(bytes[4096...].allSatisfy { $0 == 0 })
    }

    /// Un répertoire de deux cents entrées sur plusieurs blocs, indexé par
    /// `e2fsck -D` : ses blocs d'index sont sautés, et toutes ses entrées sont
    /// là.
    func testAnIndexedDirectoryListsEveryEntry() throws {
        for (name, volume) in try both {
            let entries = try volume.list("/many")
            XCTAssertEqual(entries.count, 200, name)
            XCTAssertEqual(Set(entries.map(\.name)),
                           Set((0..<200).map { String(format: "entree-numero-%03d-avec-un-nom-assez-long", $0) }),
                           name)
            XCTAssertEqual(try volume.contents(of: "/many/entree-numero-123-avec-un-nom-assez-long"),
                           Array("123\n".utf8), name)
        }
    }

    /// Ce qui n'est pas ce qu'on demande.
    func testWrongKindsAndMissingPathsAreToldApart() throws {
        let volume = try volume(Ext4Fixtures.ext4)
        XCTAssertThrowsError(try volume.contents(of: "/boot")) { error in
            XCTAssertEqual(error as? Ext4Volume.Failure, .notAFile("/boot"))
        }
        XCTAssertThrowsError(try volume.list("/etc/hostname")) { error in
            XCTAssertEqual(error as? Ext4Volume.Failure, .notADirectory("/etc/hostname"))
        }
        XCTAssertThrowsError(try volume.contents(of: "/etc/hostname/x")) { error in
            XCTAssertEqual(error as? Ext4Volume.Failure, .notADirectory("/etc/hostname/x"))
        }
        XCTAssertThrowsError(try volume.contents(of: "/boot/vmlinuz")) { error in
            XCTAssertEqual(error as? Ext4Volume.Failure, .notFound("/boot/vmlinuz"))
        }
        XCTAssertEqual(try volume.contents(of: "/etc/hostname"), Array("wisq\n".utf8))
    }

    /// Un arbre d'extents abîmé : le bloc d'index de `boot/sparse` se dit de
    /// profondeur un, alors que son parent l'attend à zéro. Il est refusé,
    /// plutôt que ses extents soient lus comme des index.
    func testAnExtentTreeWhoseDepthDisagreesIsRefused() throws {
        let depth = Ext4Fixtures.sparseIndexBlock * 4096 + 6
        let volume = try volume(Ext4Fixtures.ext4) { $0[depth] = 1 }
        XCTAssertThrowsError(try volume.contents(of: "/boot/sparse")) { error in
            guard case .corrupt(let why) = error as? Ext4Volume.Failure else { return XCTFail("\(error)") }
            XCTAssertTrue(why.contains("incohérent"), why)
        }
    }

    /// La taille d'un fichier a deux moitiés, et la haute compte : un fichier
    /// de quatre gigaoctets et cinq octets n'est pas un fichier de cinq octets.
    func testTheHighHalfOfTheSizeIsRead() throws {
        let high = Ext4Fixtures.hostnameInodeOffset + 0x6C
        let volume = try volume(Ext4Fixtures.ext4) { $0[high] = 1 }
        XCTAssertThrowsError(try volume.contents(of: "/etc/hostname")) { error in
            XCTAssertEqual(error as? Ext4Volume.Failure, .tooLarge("/etc/hostname", (1 << 32) + 5))
        }
    }

    /// Les refus du superbloc : pas un ext, un journal à rejouer, une
    /// fonction inconnue.
    func testTheSuperblockRefusesWhatCannotBeReadFaithfully() throws {
        XCTAssertThrowsError(try Ext4Volume(size: 1 << 20) { _, count in [UInt8](repeating: 0, count: count) }) {
            XCTAssertEqual($0 as? Ext4Volume.Failure, .notExt)
        }
        let incompat = 1024 + 96
        XCTAssertThrowsError(try volume(Ext4Fixtures.ext4) { $0[incompat] |= 0x04 }) { error in
            guard case .unsupported(let what) = error as? Ext4Volume.Failure else { return XCTFail("\(error)") }
            XCTAssertTrue(what.contains("journal"), what)
        }
        XCTAssertThrowsError(try volume(Ext4Fixtures.ext4) { $0[incompat + 3] |= 0x40 }) { error in
            XCTAssertEqual(error as? Ext4Volume.Failure, .unsupported("une fonction inconnue (0x40000000)"))
        }
    }

    /// **La vraie image.** Hors des fixtures, et seulement si on la donne :
    /// `WISQ_CLOUD_IMAGE` désigne une image de cloud Debian (qcow2 ou brute).
    /// La table, la racine, le `grub.cfg`, et le noyau qu'il nomme, qui doit
    /// être un bzImage.
    func testARealDebianCloudImageGivesUpItsKernel() throws {
        guard let path = ProcessInfo.processInfo.environment["WISQ_CLOUD_IMAGE"] else {
            throw XCTSkip("image de cloud absente : définir WISQ_CLOUD_IMAGE pour ce test")
        }
        let fd = open(path, O_RDONLY)
        XCTAssertGreaterThanOrEqual(fd, 0)
        let image = try XCTUnwrap(try VirtualDiskImages.image(takingOwnershipOf: fd))
        let table = try PartitionTable.read(image)
        let root = try XCTUnwrap(table.linuxCandidates.first)
        let volume = try Ext4Volume(root, in: image)
        let grub = String(decoding: try volume.contents(of: "/boot/grub/grub.cfg"), as: UTF8.self)
        let line = try XCTUnwrap(grub.split(separator: "\n").first { $0.trimmingCharacters(in: .whitespaces)
            .hasPrefix("linux") })
        let kernelPath = String(line.split(whereSeparator: { $0 == " " || $0 == "\t" })[1])
        let kernel = try volume.contents(of: kernelPath)
        XCTAssertEqual(Array(kernel[0x202..<0x206]), Array("HdrS".utf8), kernelPath)
        let initrdLine = try XCTUnwrap(grub.split(separator: "\n").first { $0.trimmingCharacters(in: .whitespaces)
            .hasPrefix("initrd") })
        let initrdPath = String(initrdLine.split(whereSeparator: { $0 == " " || $0 == "\t" })[1])
        let initrd = try volume.contents(of: initrdPath)
        // Les sommes, pour les comparer à ce que rend `debugfs -R "dump …"`.
        print("noyau \(kernelPath) : \(kernel.count) octets, \(SHA256Stream.hex(kernel))")
        print("initramfs \(initrdPath) : \(initrd.count) octets, \(SHA256Stream.hex(initrd))")
        print("racine \(volume.uuid)")
    }
}
