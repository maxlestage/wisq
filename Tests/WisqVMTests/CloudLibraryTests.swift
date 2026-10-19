import XCTest
@testable import WisqVM
import WisqVMTestKit

/// Les images de cloud dans la bibliothèque : reconnues en lisant leur table,
/// nommées comme telles, et offertes à l'installation de machines.
final class CloudLibraryTests: XCTestCase {
    private var folder = URL(fileURLWithPath: "/")

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("wisq-bibliotheque-nuage-\(getpid())-\(UUID().uuidString)")
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

    /// **Seules les images de cloud sont retenues** : la table de l'image de
    /// Debian lue à travers son qcow2, et un disque brut à partition Linux.
    /// Pas un disque brut sans partition Linux, pas un fichier sans table, pas
    /// un noyau, pas un disque de données vierge.
    func testOnlyCloudImagesAreTakenForCloudImages() throws {
        let packed = try XCTUnwrap(Data(base64Encoded: PartitionFixtures.debianQcow2))
        let debian = try file("debian.qcow2", try XCTUnwrap(
            Qcow2Image.inflateRaw([UInt8](packed), expected: PartitionFixtures.debianQcow2Size)))
        let raw = try file("nuage.raw", CloudDisk.raw(around: [UInt8](repeating: 0, count: 4096)))
        let windows = try file("windows.raw", CloudDisk.raw(around: [UInt8](repeating: 0, count: 4096), type: 0x07))
        let noise = try file("bruit.bin", (0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        var header = [UInt8](repeating: 0, count: 4096)
        header.replaceSubrange(0x202..<0x206, with: Array("HdrS".utf8))
        let kernel = try file("vmlinuz", header)
        // Un disque vierge, tout de zéros : un fichier que personne ne
        // reconnaît, et qui n'a pas de table.
        let blank = try file("donnees.img", [UInt8](repeating: 0, count: 1 << 20))

        // Un qcow2 vierge, tel que `qemu-img create -f qcow2 vierge.qcow2 1M`
        // l'écrit (qemu-img 8.2), en deflate brut : un disque qu'on lit, mais
        // qui n'a ni table ni système.
        let emptyQcow2 = try file("vierge.qcow2", try XCTUnwrap(Qcow2Image.inflateRaw(
            [UInt8](try XCTUnwrap(Data(base64Encoded: Self.blankQcow2))), expected: 196_616)))
        XCTAssertEqual(KernelImageKind.identify(fileAt: emptyQcow2), .virtualDisk("qcow2"))

        let files = [debian, raw, windows, noise, kernel, blank, emptyQcow2]
        let kinds = Dictionary(uniqueKeysWithValues: files.map { ($0, KernelImageKind.identify(fileAt: $0)) })
        XCTAssertEqual(InstalledMachines.cloudImages(files, kinds: kinds), [debian, raw])
    }

    static let blankQcow2 = [
        "7dDBSsNAEADQTeMH+An7DX6EIHjx5Dk2Wwy0SdisaD352YIXU1GwlzaefW/ZgYGdYWbvrm8+Qgh1OHb5Kx5UX7E+yqqwzMV8x5/k",
        "sX6/n0vfQmi7XPbxoSvLulTrIeensSytWKWXknLfbGPblCZuum06+b5eD7sxp2nqhj6W/ZjObXXo37epjbdXMfUld2k6NX7YNq/7",
        "mNNmPTz1ZTo7fpj33DXjtPCTV1VunuPRzgEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "AAAAAAAAAAAAAAAAAAAAAAAAAODPVr4AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "AAAAAAAAAAAAAAAAAAAAAAAADg36u+DwAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "AAAAAAAAAAAAAAAAAAAAAMw+AQ==",
    ].joined()

    /// Une image de cloud se dit image de cloud, avec son format, et son
    /// icône est un nuage ; sans ce savoir, c'est le rôle d'avant.
    func testACloudImageIsNamedAsOne() {
        let qcow2 = KernelImageKind.virtualDisk("qcow2")
        XCTAssertEqual(LibraryEntry.role(of: qcow2, cloudImage: true), .cloudImage("qcow2"))
        XCTAssertEqual(LibraryEntry.role(of: .unknown, cloudImage: true), .cloudImage("image brute"))
        XCTAssertEqual(LibraryEntry.role(of: qcow2, cloudImage: false), LibraryEntry.role(of: qcow2))
        XCTAssertEqual(LibraryEntry.word(.cloudImage("qcow2")), "image de cloud (qcow2)")
        XCTAssertEqual(LibraryEntry.symbol(.cloudImage("qcow2")), "cloud")
    }

    /// **Deux machines sur la même image de cloud** ne partagent ni leurs
    /// écritures ni leur mot de passe de `root` : chacune a sa clé.
    func testTwoMachinesOnOneCloudImageKeepTheirOwnThings() throws {
        let first = try InstalledMachines.install(image: "debian.qcow2", name: "Travail", in: folder)
        let second = try InstalledMachines.install(image: "debian.qcow2", name: "Essais", in: folder)
        XCTAssertNotEqual(first.keys.overlay(forDisk: "debian.qcow2"), second.keys.overlay(forDisk: "debian.qcow2"))
        RootPassword.set(UUID().uuidString, forKernel: first.key, in: folder)
        XCTAssertNotNil(RootPassword.hash(forKernel: first.key, in: folder))
        XCTAssertNil(RootPassword.hash(forKernel: second.key, in: folder))
    }
}
