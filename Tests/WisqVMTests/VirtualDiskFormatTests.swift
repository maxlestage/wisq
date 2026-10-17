import XCTest
@testable import WisqVM

/// Les disques des autres hyperviseurs : reconnus, nommés, et jamais offerts
/// comme disque brut.
///
/// Les en-têtes ci-dessous sont **relevés**, pas recopiés d'une spécification :
/// ce sont les premiers octets des fichiers que `qemu-img create` (8.2.2) écrit
/// pour chaque format, lus avec `od`. Une marque qu'on croit connaître et qui
/// est fausse d'un octet ne se voit qu'avec un vrai fichier.
final class VirtualDiskFormatTests: XCTestCase {

    /// Un fichier de 40 Kio dont le début est `head`, posé à `offset`.
    private func file(_ head: [UInt8], at offset: Int = 0) -> Data {
        var bytes = [UInt8](repeating: 0, count: 40 * 1024)
        bytes.replaceSubrange(offset..<(offset + head.count), with: head)
        return Data(bytes)
    }

    func testEachFormatIsNamedByWhatQemuImgWrites() {
        let cases: [([UInt8], Int, String)] = [
            ([0x51, 0x46, 0x49, 0xFB, 0x00, 0x00, 0x00, 0x03], 0, "qcow2"),
            ([0x51, 0x46, 0x49, 0xFB, 0x00, 0x00, 0x00, 0x02], 0, "qcow2"),
            ([0x51, 0x46, 0x49, 0xFB, 0x00, 0x00, 0x00, 0x01], 0, "qcow"),
            ([0x4B, 0x44, 0x4D, 0x56, 0x01, 0x00, 0x00, 0x00], 0, "VMDK"),
            (Array("vhdxfile".utf8), 0, "VHDX"),
            (Array("conectix".utf8), 0, "VHD dynamique"),
            ([0x7F, 0x10, 0xDA, 0xBE], 0x40, "VDI"),
            (Array("# Disk DescriptorFile\n".utf8), 0, "VMDK (descripteur)"),
        ]
        for (head, offset, name) in cases {
            XCTAssertEqual(KernelImageKind.identify(prefix: file(head, at: offset)),
                           .virtualDisk(name), name)
        }
    }

    /// Le VHD *fixe* est un disque brut suivi d'un pied : il commence par les
    /// octets du disque lui-même, et doit rester branchable. Le prendre pour un
    /// format à convertir refuserait un fichier qui marche.
    func testAFixedVHDIsNotTakenForOne() {
        var raw = file([])
        raw.append(contentsOf: Array("conectix".utf8) + [UInt8](repeating: 0, count: 504))
        XCTAssertEqual(KernelImageKind.identify(prefix: raw), .unknown)
        XCTAssertTrue(LocalDisk.couldBeDisk(KernelImageKind.identify(prefix: raw)))
    }

    /// Le défaut qui a fait écrire ce cas : un qcow2 était offert comme disque,
    /// et l'invité lisait des tables de clusters au lieu d'un système de
    /// fichiers. Il ne l'est plus, et il ne démarre pas non plus.
    func testItIsNeverOfferedAsADiskNorBooted() throws {
        let qcow2 = KernelImageKind.virtualDisk("qcow2")
        XCTAssertFalse(LocalDisk.couldBeDisk(qcow2))
        XCTAssertFalse(LocalDisk.isDiskImage(qcow2))
        XCTAssertFalse(qcow2.couldBootHere)
        XCTAssertFalse(InstalledMachines.canInstall(qcow2))
        XCTAssertNil(qcow2.architecture)

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("wisq-disques-virtuels-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let cloud = folder.appendingPathComponent("debian-12-genericcloud-amd64.qcow2")
        let raw = folder.appendingPathComponent("disque.img")
        try file([0x51, 0x46, 0x49, 0xFB, 0, 0, 0, 3]).write(to: cloud)
        try file([]).write(to: raw)
        XCTAssertEqual(LocalDisk.candidates(among: [cloud, raw], kernel: "bzImage"), [raw])
    }

    /// La bibliothèque le dit à sa ligne, et le refus donne la commande qui en
    /// fait un disque d'ici — avec le nom du fichier dedans, prête à copier.
    func testTheWordsSayWhatItIsAndHowToConvertIt() throws {
        XCTAssertEqual(LibraryEntry.role(of: .virtualDisk("qcow2")),
                       .foreign("disque qcow2, à convertir"))
        let refusal = try XCTUnwrap(KernelImageKind.cannotRunHereExplanation(
            .virtualDisk("qcow2"), name: "debian.qcow2"))
        XCTAssertTrue(refusal.contains("qcow2"))
        XCTAssertTrue(refusal.contains("`qemu-img convert -O raw debian.qcow2 disque.img`"))
        XCTAssertFalse(refusal.contains("installez-la sur un hôte"),
                       "le conseil des noyaux étrangers n'a pas de sens pour un disque")
        XCTAssertNotNil(KernelImageKind.whatItIs(.virtualDisk("VMDK"), name: "x.vmdk"))
        let notInitramfs = try XCTUnwrap(BootMedia.refusal(
            for: file([0x51, 0x46, 0x49, 0xFB, 0, 0, 0, 3]), name: "d.qcow2"))
        XCTAssertTrue(notInitramfs.contains("qemu-img convert -O raw"))
    }
}
