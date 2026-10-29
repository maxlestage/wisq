import XCTest
@testable import WisqVM

/// **Le FAT, lu comme une partition EFI de Gentoo le porte** : trois FAT
/// réels — 12, 16 et 32 —, faits par `mkfs.fat` et remplis par `mcopy` (voir
/// `FatFixtures`), puis ce qui doit être refusé.
final class FatVolumeTests: XCTestCase {
    /// Une racine en mémoire, pour la partition Linux qui n'a rien à démarrer.
    private final class MemoryVolume: LinuxVolume, Sendable {
        let files: [String: [UInt8]]
        init(_ files: [String: [UInt8]]) { self.files = files }
        func contents(of path: String) throws -> [UInt8] {
            guard let bytes = files[path] else { throw Ext4Volume.Failure.notFound(path) }
            return bytes
        }
        func listing(_ path: String) throws -> [(name: String, kind: Ext4Volume.EntryKind)] {
            let prefix = path.hasSuffix("/") ? path : path + "/"
            let names = Set(files.keys.filter { $0.hasPrefix(prefix) }.map {
                String($0.dropFirst(prefix.count).prefix { $0 != "/" })
            })
            guard !names.isEmpty else { throw Ext4Volume.Failure.notFound(path) }
            return names.sorted().map { ($0, .file) }
        }
        func exists(_ path: String) -> Bool { files[path] != nil || (try? listing(path)) != nil }
    }

    private func image(_ base64: String, size: Int) throws -> [UInt8] {
        let packed = try XCTUnwrap(Data(base64Encoded: base64))
        return try XCTUnwrap(Inflate.raw([UInt8](packed), limit: size, exact: true))
    }

    private func volume(_ bytes: [UInt8]) throws -> FatVolume {
        try FatVolume(size: UInt64(bytes.count)) { offset, count in
            guard offset <= UInt64(bytes.count), UInt64(count) <= UInt64(bytes.count) - offset else { return nil }
            return Array(bytes[Int(offset)..<(Int(offset) + count)])
        }
    }

    private var all: [(FatVolume.Kind, String, Int)] {
        [(.fat12, FatFixtures.fat12, FatFixtures.fat12Size), (.fat16, FatFixtures.fat16, FatFixtures.fat16Size),
         (.fat32, FatFixtures.fat32, FatFixtures.fat32Size)]
    }

    private let kernel: [UInt8] = (0..<70000).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 3) }

    /// **Les trois genres rendent les mêmes fichiers**, le noyau en entier —
    /// cent trente-sept clusters en chaîne —, et chaque genre est reconnu au
    /// nombre de ses clusters.
    func testEveryKindReadsTheSameFiles() throws {
        for (kind, fixture, size) in all {
            let fat = try volume(image(fixture, size: size))
            XCTAssertEqual(fat.kind, kind)
            XCTAssertEqual(try fat.contents(of: "/kernel-6.18.57"), kernel, "\(kind)")
            XCTAssertEqual(try fat.contents(of: "/amd-uc.img"), Array("microcode".utf8), "\(kind)")
            XCTAssertEqual(try fat.contents(of: "/initramfs-6.18.57.img"),
                           Array(String(repeating: "cpio", count: 3000).utf8), "\(kind)")
            XCTAssertEqual(try fat.contents(of: "/vide"), [], "\(kind)")
            XCTAssertEqual(try fat.contents(of: "/EFI/BOOT/BOOTX64.EFI"), [0x4D, 0x5A] + [UInt8](repeating: 0, count: 100))
            let config = String(decoding: try fat.contents(of: "/grub/grub.cfg"), as: UTF8.self)
            XCTAssertTrue(config.contains("linux\t/kernel-6.18.57"), "\(kind)")
        }
    }

    /// **Les noms longs**, non ASCII compris, et la liste de la racine telle
    /// que `mcopy` l'a écrite — l'étiquette du volume n'y est pas.
    func testLongNamesAndTheListing() throws {
        for (kind, fixture, size) in all {
            let fat = try volume(image(fixture, size: size))
            XCTAssertEqual(try fat.contents(of: "/Nom Long Accentué.txt"), Array("bonjour".utf8), "\(kind)")
            let names = try fat.listing("/").map(\.name).sorted()
            XCTAssertEqual(names, ["EFI", "Nom Long Accentué.txt", "amd-uc.img", "grub",
                                   "initramfs-6.18.57.img", "kernel-6.18.57", "vide"].sorted(), "\(kind)")
            XCTAssertEqual(try fat.listing("/EFI").map(\.kind), [.directory])
        }
    }

    /// **La casse ne compte pas**, comme sur le FAT : `/efi/boot/bootx64.efi`
    /// est le même fichier. Ce qui n'existe pas le dit.
    func testNamesAreCaseInsensitiveAndMissingOnesAreNamed() throws {
        let fat = try volume(image(FatFixtures.fat32, size: FatFixtures.fat32Size))
        XCTAssertTrue(fat.exists("/efi/boot/bootx64.efi"))
        XCTAssertTrue(fat.exists("/KERNEL-6.18.57"))
        XCTAssertFalse(fat.exists("/boot/vmlinuz"))
        XCTAssertThrowsError(try fat.contents(of: "/grub")) {
            XCTAssertEqual($0 as? FatVolume.Failure, .notAFile("/grub"))
        }
    }

    /// **Ce qui n'est pas un FAT n'en est pas un**, et une chaîne qui boucle
    /// est refusée au lieu de tourner pour toujours.
    func testWhatIsNotAFatAndALoopingChainAreRefused() throws {
        XCTAssertThrowsError(try volume([UInt8](repeating: 0, count: 4096))) {
            XCTAssertEqual($0 as? FatVolume.Failure, .notFat)
        }
        var bytes = try image(FatFixtures.fat16, size: FatFixtures.fat16Size)
        let fat = try volume(bytes)
        // Le premier cluster du noyau, et son entrée dans la première table :
        // elle pointe sur elle-même.
        let first = try XCTUnwrap(try fat.resolve("/kernel-6.18.57").firstCluster)
        let reserved = Int(bytes[14]) | Int(bytes[15]) << 8
        let at = reserved * 512 + Int(first) * 2
        bytes[at] = UInt8(first & 0xFF)
        bytes[at + 1] = UInt8(first >> 8)
        XCTAssertThrowsError(try volume(bytes).contents(of: "/kernel-6.18.57")) {
            XCTAssertEqual($0 as? FatVolume.Failure, .corrupt("une chaîne qui boucle."))
        }
    }

    /// **Gentoo** : la partition EFI porte le noyau et `grub/grub.cfg`, la
    /// racine n'a rien à démarrer. L'entrée est trouvée sur la partition EFI,
    /// après la partition Linux, et ses deux initramfs mis bout à bout.
    func testAKernelOnTheEFIPartitionIsFoundLikeGentoosImage() throws {
        let esp = try volume(image(FatFixtures.fat32, size: FatFixtures.fat32Size))
        let root = MemoryVolume(["/etc/os-release": Array("ID=gentoo\n".utf8)])
        let table = PartitionTable(scheme: .gpt, partitions: [
            PartitionTable.Partition(number: 1, kind: .efiSystem, start: 1 << 20, length: 1 << 30,
                                     name: "gentooefi", uniqueID: ""),
            PartitionTable.Partition(number: 2, kind: .linuxFilesystem, start: 2 << 30, length: 1 << 30,
                                     name: "gentooroot", uniqueID: ""),
        ])
        let found = try CloudBoot.find(in: table) { $0.kind == .efiSystem ? esp as any LinuxVolume : root }
        XCTAssertEqual(found.kernel, kernel)
        XCTAssertEqual(found.initrd, Array("microcode".utf8) + Array(String(repeating: "cpio", count: 3000).utf8))
        XCTAssertTrue(found.commandLine.hasPrefix("root=UUID=x ro console=ttyS0"))
        XCTAssertEqual(found.origin, "grub.cfg de vda1")
    }

    /// Une partition EFI seule, sans entrée configurée, ne fait pas démarrer
    /// un noyau qui traînerait à sa racine, et ne compte pas pour une
    /// partition Linux : le refus reste celui d'une image sans partition
    /// Linux lisible.
    func testAnEFIPartitionAloneIsNotALinuxPartition() throws {
        let esp = MemoryVolume(["/vmlinuz": [0x4D, 0x5A]])
        let table = PartitionTable(scheme: .gpt, partitions: [
            PartitionTable.Partition(number: 1, kind: .efiSystem, start: 1 << 20, length: 1 << 30,
                                     name: "", uniqueID: ""),
        ])
        XCTAssertThrowsError(try CloudBoot.find(in: table) { _ in esp }) {
            XCTAssertEqual($0 as? CloudBoot.Failure, .noLinuxPartition)
        }
    }
}
