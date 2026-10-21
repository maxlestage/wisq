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

    /// Le défaut qui a fait écrire ce cas : un qcow2 était offert comme disque
    /// **brut**, et l'invité lisait des tables de clusters au lieu d'un système
    /// de fichiers. Un format que wisq ne lit pas n'est plus offert du tout ;
    /// le qcow2, le VMDK, l'OVA, le VDI et le VHD dynamique, que
    /// `Qcow2Image`, `VmdkImage`, `OvaArchive`, `VdiImage` et `VhdImage`
    /// lisent sur place, le sont — et aucun ne démarre.
    ///
    /// **La liste est énumérée, pas recopiée.** Ce cas n'en nommait que deux
    /// quand la machine en lisait cinq : il gardait le qcow2 et le VMDK, et
    /// laissait les trois formats arrivés depuis hors de tout contrôle. Le
    /// sixième qui viendra sera exercé sans qu'on repasse ici.
    func testOnlyWhatIsReadIsOfferedAsADiskAndNothingBoots() throws {
        let vhdx = KernelImageKind.virtualDisk("VHDX")
        XCTAssertFalse(LocalDisk.couldBeDisk(vhdx))
        XCTAssertFalse(LocalDisk.isDiskImage(vhdx))
        XCTAssertFalse(KernelImageKind.readableVirtualDisks.isEmpty)
        for format in KernelImageKind.readableVirtualDisks {
            XCTAssertTrue(LocalDisk.isDiskImage(.virtualDisk(format)),
                          "\(format) est lu sur place et doit être offert comme disque")
            XCTAssertTrue(LocalDisk.couldBeDisk(.virtualDisk(format)), format)
        }
        let qcow2 = KernelImageKind.virtualDisk("qcow2")
        let vmdk = KernelImageKind.virtualDisk("VMDK")
        XCTAssertFalse(LocalDisk.isDiskImage(.virtualDisk("qcow")), "l'ancien qcow, v1, n'est pas lu")
        XCTAssertFalse(LocalDisk.isDiskImage(.virtualDisk("VMDK (descripteur)")),
                       "un descripteur nomme les fichiers du disque, il n'en contient aucun")
        for kind in [vhdx, vmdk, qcow2] {
            XCTAssertFalse(kind.couldBootHere)
            XCTAssertFalse(InstalledMachines.canInstall(kind))
            XCTAssertNil(kind.architecture)
        }

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("wisq-disques-virtuels-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let cloud = folder.appendingPathComponent("debian-12-genericcloud-amd64.qcow2")
        let appliance = folder.appendingPathComponent("appliance.vmdk")
        let hyperV = folder.appendingPathComponent("serveur.vhdx")
        let raw = folder.appendingPathComponent("disque.img")
        try file([0x51, 0x46, 0x49, 0xFB, 0, 0, 0, 3]).write(to: cloud)
        try file(Array("KDMV".utf8)).write(to: appliance)
        try file(Array("vhdxfile".utf8)).write(to: hyperV)
        try file([]).write(to: raw)
        XCTAssertEqual(
            LocalDisk.candidates(among: [cloud, appliance, hyperV, raw], kernel: "bzImage"),
            [cloud, appliance, raw])
    }

    /// La bibliothèque le dit à sa ligne, et le refus donne la commande qui en
    /// fait un disque d'ici — avec le nom du fichier dedans, prête à copier.
    func testTheWordsSayWhatItIsAndHowToConvertIt() throws {
        XCTAssertEqual(LibraryEntry.role(of: .virtualDisk("VHDX")),
                       .foreign("disque VHDX, à convertir"))
        XCTAssertEqual(LibraryEntry.role(of: .virtualDisk("qcow2")), .disk("qcow2"))
        XCTAssertEqual(LibraryEntry.role(of: .virtualDisk("VMDK")), .disk("VMDK"))
        let refusal = try XCTUnwrap(KernelImageKind.cannotRunHereExplanation(
            .virtualDisk("VHDX"), name: "serveur.vhdx"))
        XCTAssertTrue(refusal.contains("VHDX"))
        XCTAssertTrue(refusal.contains("`qemu-img convert -O raw serveur.vhdx disque.img`"))
        XCTAssertFalse(refusal.contains("installez-la sur un hôte"),
                       "le conseil des noyaux étrangers n'a pas de sens pour un disque")
        // Un qcow2 pris comme noyau : la réponse est où le mettre, pas comment
        // le convertir.
        let qcow2 = try XCTUnwrap(KernelImageKind.cannotRunHereExplanation(
            .virtualDisk("qcow2"), name: "debian.qcow2"))
        XCTAssertTrue(qcow2.contains("**disque**"))
        XCTAssertFalse(qcow2.contains("qemu-img"))
        XCTAssertNotNil(KernelImageKind.whatItIs(.virtualDisk("VHDX"), name: "x.vhdx"))
        let notInitramfs = try XCTUnwrap(BootMedia.refusal(
            for: file(Array("vhdxfile".utf8)), name: "d.vhdx"))
        XCTAssertTrue(notInitramfs.contains("qemu-img convert -O raw"))
        let vmdkInitramfs = try XCTUnwrap(BootMedia.refusal(
            for: file(Array("KDMV".utf8)), name: "d.vmdk"))
        XCTAssertFalse(vmdkInitramfs.contains("qemu-img"))
        let qcow2Initramfs = try XCTUnwrap(BootMedia.refusal(
            for: file([0x51, 0x46, 0x49, 0xFB, 0, 0, 0, 3]), name: "d.qcow2"))
        XCTAssertFalse(qcow2Initramfs.contains("qemu-img"))
    }
}
