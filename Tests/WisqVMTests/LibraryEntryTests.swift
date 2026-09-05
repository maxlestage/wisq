import XCTest

@testable import WisqVM

/// Ce que la bibliothèque dit de chaque fichier.
///
/// **Ce qui manquait avant ce type.** Trois sortes de fichiers vivaient dans
/// la même liste sous la même icône : un noyau, son initramfs, et son disque.
/// Une seule des trois démarre.
final class LibraryEntryTests: XCTestCase {
    private let x86 = KernelImage(GuestArchitecture(.x86, bits: 64), format: "bzImage")
    private let sparc = KernelImage(GuestArchitecture(.sparc, bits: 64), format: "ELF")

    /// Chaque genre reconnu tombe sur le rôle qui lui correspond.
    func testEveryKindLandsOnItsRole() {
        XCTAssertEqual(LibraryEntry.role(of: .linuxKernel(x86)), .kernel(x86.architecture.name))
        XCTAssertEqual(
            LibraryEntry.role(of: .linuxKernel(sparc)),
            .foreign("noyau pour \(sparc.architecture.name)"),
            "un noyau qu'on ne peut pas démarrer est nommé, pas confondu avec le nôtre")
        XCTAssertEqual(LibraryEntry.role(of: .compressedKernel("gzip")), .bootMedia("gzip"))
        XCTAssertEqual(LibraryEntry.role(of: .filesystemImage("ext2/3/4")), .disk("ext2/3/4"))
        XCTAssertEqual(LibraryEntry.role(of: .discImage("ISO 9660")), .disk("ISO 9660"))
        XCTAssertEqual(LibraryEntry.role(of: .unknown), .unrecognised)
    }

    /// **Deux rôles ne portent jamais la même icône.** C'est tout l'objet du
    /// type : une liste où l'initramfs et le noyau se ressemblent est la liste
    /// qu'on avait, et elle envoyait toucher le mauvais fichier.
    func testNoTwoRolesLookAlike() {
        let roles: [LibraryEntry.Role] = [
            .kernel("x86-64"), .bootMedia("gzip"), .disk("ext2/3/4"),
            .foreign("exécutable ARM64"), .unrecognised,
        ]
        let symbols = Set(roles.map(LibraryEntry.symbol))
        XCTAssertEqual(symbols.count, roles.count, "\(symbols)")
        let words = Set(roles.map(LibraryEntry.word))
        XCTAssertEqual(words.count, roles.count, "\(words)")
    }

    /// Le mot dit le format quand il y en a un : « disque » tout court ne dit
    /// pas si l'invité saura le lire.
    func testTheWordCarriesTheFormat() {
        XCTAssertEqual(LibraryEntry.word(.disk("ext2/3/4")), "disque (ext2/3/4)")
        XCTAssertEqual(LibraryEntry.word(.bootMedia("zstd")), "initramfs (zstd)")
        XCTAssertEqual(LibraryEntry.word(.kernel("x86-64")), "noyau x86-64")
    }

    /// Et le rôle se lit sur un vrai fichier, pas seulement sur un genre.
    func testTheRoleIsReadFromTheFileItself() throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wisq-roles-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        var image = [UInt8](repeating: 0, count: 0x1000)
        image[0x438] = 0x53
        image[0x439] = 0xEF
        let disk = folder.appendingPathComponent("racine.img")
        try Data(image).write(to: disk)
        XCTAssertEqual(LibraryEntry.role(of: disk), .disk("ext2/3/4"))
    }
}
