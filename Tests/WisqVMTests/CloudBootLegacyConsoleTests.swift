import XCTest
@testable import WisqVM

/// **La console d'un systemd plus ancien que 256**, choisie d'après ce que
/// porte le disque : AlmaLinux 9 et les siens ont systemd 252.
final class CloudBootLegacyConsoleTests: XCTestCase {
    /// Un système de fichiers en mémoire : des chemins et leur contenu, les
    /// répertoires déduits des chemins.
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

        func exists(_ path: String) -> Bool {
            files[path] != nil || (try? listing(path)) != nil
        }
    }

    /// Le `/boot` d'AlmaLinux, à part : une entrée BLS et son noyau.
    private static let boot = MemoryVolume([
        "/loader/entries/a.conf": Array("title AlmaLinux\nlinux /vmlinuz\ninitrd /initramfs.img\noptions root=UUID=x ro console=tty0 console=ttyS0,115200n8\n".utf8),
        "/vmlinuz": [0x4D, 0x5A],
        "/initramfs.img": [0x30],
    ])

    private func find(_ volumes: [MemoryVolume]) throws -> CloudBoot {
        let partitions = volumes.indices.map {
            PartitionTable.Partition(number: $0 + 1, kind: .linuxFilesystem, start: UInt64($0) << 30,
                                     length: 1 << 30, name: "", uniqueID: "")
        }
        let table = PartitionTable(scheme: .gpt, partitions: partitions)
        return try CloudBoot.find(in: table) { volumes[$0.number - 1] }
    }

    /// **AlmaLinux 9** : le noyau sur un `/boot` à part, systemd 252 sur la
    /// racine. Le mode de secours ouvre la console, et `sulogin` passe outre
    /// le `root` verrouillé.
    func testSystemd252GetsTheRescueShellOnTheConsole() throws {
        let root = MemoryVolume(["/usr/lib64/systemd/libsystemd-shared-252.so": [1],
                                 "/usr/lib64/systemd/libsystemd-core-252.so": [1]])
        let line = try find([Self.boot, root]).commandLine
        // Écrites en toutes lettres : relire `legacyConsoleOptions` ne
        // jugerait que la liste contre elle-même.
        for option in ["systemd.unit=rescue.target", "systemd.setenv=SYSTEMD_SULOGIN_FORCE=1",
                       "systemd.mask=systemd-hwdb-update.service"] {
            XCTAssertTrue(line.contains(option), option)
        }
        XCTAssertFalse(line.contains("agetty.autologin"), "que systemd 252 ignorerait")
        XCTAssertFalse(line.contains("serial-getty@ttyS0.service:"), "le drop-in non plus")
        XCTAssertTrue(line.hasPrefix("root=UUID=x ro console=tty0 console=ttyS0,115200n8 "),
                      "ttyS0, la dernière console nommée, reste /dev/console")
    }

    /// Un systemd récent garde la console d'aujourd'hui, et un disque où
    /// rien ne dit la version aussi : seule une version **lue** et ancienne
    /// change quelque chose.
    func testARecentOrUnknownSystemdKeepsTheSerialShell() throws {
        for root in [MemoryVolume(["/usr/lib/x86_64-linux-gnu/systemd/libsystemd-shared-257.so": [1]]),
                     MemoryVolume(["/usr/lib/systemd/libsystemd-shared-256.5-1.so": [1]]),
                     MemoryVolume(["/etc/os-release": [1]])] {
            let line = try find([Self.boot, root]).commandLine
            for option in CloudBoot.consoleOptions { XCTAssertTrue(line.contains(option), option) }
            XCTAssertFalse(line.contains("rescue"))
        }
    }

    /// La version se lit dans le nom, la plus grande s'il y en a plusieurs,
    /// et sur la première partition qui en porte une.
    func testTheVersionIsReadFromTheLibraryName() throws {
        let partitions = (1...2).map {
            PartitionTable.Partition(number: $0, kind: .linuxFilesystem, start: UInt64($0) << 30,
                                     length: 1 << 30, name: "", uniqueID: "")
        }
        let table = PartitionTable(scheme: .gpt, partitions: partitions)
        let volumes = [MemoryVolume(["/usr/lib/systemd/libsystemd-shared-249.so": [1],
                                     "/usr/lib/systemd/libsystemd-shared-252.so": [1],
                                     "/usr/lib/systemd/libsystemd-sharedx.so": [1]]),
                       MemoryVolume(["/usr/lib64/systemd/libsystemd-shared-258.so": [1]])]
        XCTAssertEqual(CloudBoot.systemdVersion(in: table) { volumes[$0.number - 1] }, 252)
    }
}
