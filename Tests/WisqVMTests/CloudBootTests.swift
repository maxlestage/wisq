import XCTest
@testable import WisqVM

/// Trouver dans une image de cloud son noyau, son initramfs et sa ligne de
/// commande : ce que le chargeur de la distribution a écrit, et ce qu'on fait
/// quand il n'a rien écrit.
final class CloudBootTests: XCTestCase {
    /// Les délais qu'une machine lente ajoute à toute ligne de commande.
    private let slow = CloudBoot.slowMachineOptions.joined(separator: " ")

    /// **Les délais d'une machine lente**, et une entrée qui en fixe un
    /// elle-même : le sien reste, une seule fois, et les autres s'ajoutent.
    func testTheSlowMachineDelaysAreAddedUnlessTheEntrySetsThem() {
        let line = CloudBoot.commandLine(["root=/dev/vda1", "systemd.firstboot=on", "console=ttyS0"])
        XCTAssertEqual(line, "root=/dev/vda1 systemd.firstboot=on console=ttyS0 "
                           + "systemd.default_device_timeout_sec=600 systemd.default_timeout_start_sec=600 "
                           + "systemd.service_watchdogs=0")
        XCTAssertEqual(CloudBoot.slowMachineOptions.count, 4)
    }

    private func pattern(_ count: Int, _ seed: Int) -> [UInt8] {
        (0..<count).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ ($0 >> 9) &+ seed) }
    }

    /// Le système de fichiers ext4 des fixtures, abîmé si on le demande, posé
    /// comme partition 1 d'une table d'une seule partition.
    private func boot(kind: PartitionTable.Kind = .linuxRoot, uniqueID: String = "",
                      patch: ((inout [UInt8]) -> Void)? = nil) throws -> CloudBoot {
        let packed = try XCTUnwrap(Data(base64Encoded: Ext4Fixtures.ext4))
        var bytes = try XCTUnwrap(Qcow2Image.inflateRaw([UInt8](packed), expected: Ext4Fixtures.size))
        patch?(&bytes)
        let disk = bytes
        let partition = PartitionTable.Partition(number: 1, kind: kind, start: 0, length: UInt64(disk.count),
                                                 name: "", uniqueID: uniqueID)
        let table = PartitionTable(scheme: .gpt, partitions: [partition])
        return try CloudBoot.find(in: table) { partition in
            try Ext4Volume(size: partition.length) { offset, count in
                guard offset + UInt64(count) <= UInt64(disk.count) else { return nil }
                return Array(disk[Int(offset)..<(Int(offset) + count)])
            }
        }
    }

    /// Remplace chaque occurrence de `old` par `new`, de même longueur, dans
    /// l'image : de quoi renommer une entrée de répertoire sans outil.
    private func rename(_ old: String, _ new: String) -> (inout [UInt8]) -> Void {
        { bytes in
            let from = Array(old.utf8)
            let to = Array(new.utf8)
            var index = 0
            while index + from.count <= bytes.count {
                if bytes[index] == from[0] && Array(bytes[index..<(index + from.count)]) == from {
                    bytes.replaceSubrange(index..<(index + from.count), with: to)
                    index += from.count
                } else {
                    index += 1
                }
            }
        }
    }

    /// **Le vrai grub.cfg de Debian.** Sa première entrée, et pas celles du
    /// sous-menu : le noyau, l'initramfs, et les options mot pour mot.
    func testTheFirstEntryOfDebiansGrubConfigIsTaken() throws {
        let entry = try XCTUnwrap(CloudBoot.grubEntry(CloudBootFixtures.debianGrub))
        XCTAssertEqual(entry.kernel, "/boot/vmlinuz-6.12.113+deb13-amd64")
        XCTAssertEqual(entry.initrds, ["/boot/initrd.img-6.12.113+deb13-amd64"])
        XCTAssertEqual(entry.options, ["root=PARTUUID=3f7bd41d-e564-4995-bb29-b2aebe93a04c", "ro", "console=tty0",
                                       "console=ttyS0,115200", "earlyprintk=ttyS0,115200", "consoleblank=0"])
        // La console série y est déjà : seuls s'ajoutent les délais d'une
        // machine lente.
        XCTAssertEqual(CloudBoot.commandLine(entry.options),
                       "root=PARTUUID=3f7bd41d-e564-4995-bb29-b2aebe93a04c ro console=tty0 console=ttyS0,115200 "
                           + "earlyprintk=ttyS0,115200 consoleblank=0 " + slow)
    }

    /// Ce qu'écrivent d'autres distributions : une entrée sans noyau sautée,
    /// un sous-menu ignoré, un disque GRUB en tête de chemin, une variable
    /// qu'on ne peut pas évaluer, et une console série absente qu'on ajoute.
    func testOtherGrubShapesAreReadAndCleaned() throws {
        let text = """
        menuentry 'UEFI Firmware Settings' {
            fwsetup
        }
        submenu 'Advanced' {
            menuentry 'old' {
                linux /boot/vmlinuz-old root=/dev/vda1
            }
        }
        menuentry 'Ubuntu' {
            if [ x$feature_platform_search_hint = xy ]; then
              search --no-floppy --fs-uuid --set=root 1234
            fi
            # linux /boot/vmlinuz-commente root=/dev/sda1
            linux (hd0,gpt1)/boot/vmlinuz-6.8.0-45-generic root=PARTUUID=abc ro console=tty1 $vt_handoff
            if [ "${initrdfail}" = 1 ]; then
              initrd (hd0,gpt1)/boot/initrd.img-6.8.0-45-generic
            else
              initrd (hd0,gpt1)/boot/initrd.img-6.8.0-45-generic.fallback
            fi
        }
        """
        let entry = try XCTUnwrap(CloudBoot.grubEntry(text))
        XCTAssertEqual(entry.kernel, "/boot/vmlinuz-6.8.0-45-generic")
        XCTAssertEqual(entry.initrds, ["/boot/initrd.img-6.8.0-45-generic"])
        XCTAssertEqual(CloudBoot.commandLine(entry.options),
                       "root=PARTUUID=abc ro console=tty1 console=ttyS0 " + slow)
        XCTAssertNil(CloudBoot.grubEntry("set default=0\n# menuentry 'commenté' {\n"))
        // L'accolade d'un commentaire ne compte pas : l'entrée qui suit reste
        // de premier niveau.
        XCTAssertEqual(CloudBoot.grubEntry("# menuentry 'commenté' {\nmenuentry 'vrai' {\n linux /v root=x\n}\n")?
            .kernel, "/v")
        XCTAssertEqual(CloudBoot.newestKernel(["vmlinuz-6.9.12", "config-6.10.4", "vmlinuz-6.10.4", "vmlinuz-6.1.0"]),
                       "vmlinuz-6.10.4")
    }

    /// Une entrée BLS, comme celles de Fedora : des options sur plusieurs
    /// lignes, deux initramfs, et la plus récente des entrées par numéro de
    /// version lu comme un nombre.
    func testBLSEntriesAreReadLikeFedorasLoader() throws {
        let entry = try XCTUnwrap(CloudBoot.blsEntry("""
        title Fedora Linux (6.10.4-200.fc40.x86_64) 40 (Cloud Edition)
        version 6.10.4-200.fc40.x86_64
        linux /vmlinuz-6.10.4-200.fc40.x86_64
        initrd /early-microcode.img /initramfs-6.10.4-200.fc40.x86_64.img
        options root=UUID=5a5f rootflags=subvol=root ro
        options console=ttyS0,115200n8
        grub_users $grub_users
        """))
        XCTAssertEqual(entry.kernel, "/vmlinuz-6.10.4-200.fc40.x86_64")
        XCTAssertEqual(entry.initrds, ["/early-microcode.img", "/initramfs-6.10.4-200.fc40.x86_64.img"])
        XCTAssertEqual(CloudBoot.commandLine(entry.options),
                       "root=UUID=5a5f rootflags=subvol=root ro console=ttyS0,115200n8 " + slow)
        XCTAssertEqual(["a-6.9.12.conf", "a-6.10.4.conf"].sorted { $0.compare($1, options: .numeric) == .orderedDescending },
                       ["a-6.10.4.conf", "a-6.9.12.conf"])
    }

    /// Dans une image : le grub.cfg de la fixture désigne le noyau et
    /// l'initramfs, lus octet pour octet, et sa ligne de commande gagne la
    /// console série.
    func testAnImageWithGrubBootsWhatGrubWouldBoot() throws {
        let found = try boot()
        XCTAssertEqual(found.kernel, pattern(300_000, 1))
        XCTAssertEqual(found.initrd, pattern(70_000, 2))
        XCTAssertEqual(found.commandLine, "root=/dev/vda1 ro console=ttyS0 " + slow)
        XCTAssertEqual(found.origin, "grub.cfg de vda1")
    }

    /// Sans grub.cfg, les liens `/vmlinuz` et `/initrd.img` ; et la racine se
    /// désigne par son PARTUUID quand la table en donne un.
    func testWithoutAConfigurationTheDebianLinksAreFollowed() throws {
        let found = try boot(uniqueID: "3f7bd41d-e564-4995-bb29-b2aebe93a04c", patch: rename("grub.cfg", "grub.old"))
        XCTAssertEqual(found.kernel, pattern(300_000, 1))
        XCTAssertEqual(found.initrd, pattern(70_000, 2))
        XCTAssertEqual(found.commandLine,
                       "root=PARTUUID=3f7bd41d-e564-4995-bb29-b2aebe93a04c ro console=ttyS0 " + slow)
        XCTAssertEqual(found.origin, "/vmlinuz de vda1")
    }

    /// Deux initramfs dans l'entrée se donnent au noyau bout à bout, dans
    /// l'ordre. Le chemin du grub.cfg de la fixture est remplacé, à longueur
    /// égale, par deux chemins.
    func testSeveralInitramfsAreConcatenatedInOrder() throws {
        let found = try boot(patch: rename("initrd\t/boot/initrd.img-6.1.0-test",
                                           "initrd\t/initrd.img /etc/hostname  "))
        XCTAssertEqual(found.initrd, pattern(70_000, 2) + Array("wisq\n".utf8))
    }

    /// Un grub.cfg qui nomme un noyau absent (un paquet retiré sans
    /// `update-grub`) n'est pas cru : on passe au lien `/vmlinuz`.
    func testAGrubEntryForAMissingKernelIsSkipped() throws {
        let found = try boot(patch: rename("linux\t/boot/vmlinuz-6.1.0-test", "linux\t/boot/vmlinuz-6.1.0-gone"))
        XCTAssertEqual(found.origin, "/vmlinuz de vda1")
        XCTAssertEqual(found.kernel, pattern(300_000, 1))
    }

    /// Ni grub.cfg ni lien `/vmlinuz` : le noyau le plus récent de `/boot`,
    /// et l'initramfs de la même version.
    func testWithoutLinksTheNewestKernelInBootIsTaken() throws {
        // L'entrée de répertoire du lien : longueur du nom 7, type 7 (lien).
        let found = try boot(patch: { bytes in
            self.rename("grub.cfg", "grub.old")(&bytes)
            let entry: [UInt8] = [7, 7] + Array("vmlinuz".utf8)
            guard let index = (0...(bytes.count - entry.count)).first(where: {
                Array(bytes[$0..<($0 + entry.count)]) == entry
            }) else { return XCTFail("l'entrée du lien n'est pas dans l'image") }
            bytes[index + entry.count - 1] = UInt8(ascii: "x")
        })
        XCTAssertEqual(found.kernel, pattern(300_000, 1))
        XCTAssertEqual(found.initrd, pattern(70_000, 2))
        XCTAssertEqual(found.origin, "/boot/vmlinuz-6.1.0-test de vda1")
    }

    /// Ni configuration ni noyau : on le dit. Et une table sans partition
    /// Linux se dit autrement qu'une partition Linux vide.
    func testNoKernelAndNoLinuxPartitionAreToldApart() throws {
        XCTAssertThrowsError(try boot(patch: { bytes in
            self.rename("grub.cfg", "grub.old")(&bytes)
            self.rename("vmlinuz", "wmlinuz")(&bytes)
        })) { error in
            XCTAssertEqual(error as? CloudBoot.Failure, .noKernel)
        }
        XCTAssertThrowsError(try boot(kind: .efiSystem)) { error in
            XCTAssertEqual(error as? CloudBoot.Failure, .noLinuxPartition)
        }
    }

    /// **La vraie image**, si on la donne (`WISQ_CLOUD_IMAGE`) : ce que wisq
    /// démarrera, et d'où il le tient.
    func testARealCloudImageIsFoundBootable() throws {
        guard let path = ProcessInfo.processInfo.environment["WISQ_CLOUD_IMAGE"] else {
            throw XCTSkip("image de cloud absente : définir WISQ_CLOUD_IMAGE pour ce test")
        }
        let fd = open(path, O_RDONLY)
        XCTAssertGreaterThanOrEqual(fd, 0)
        let image = try XCTUnwrap(try VirtualDiskImages.image(takingOwnershipOf: fd))
        let found = try CloudBoot.find(in: image)
        XCTAssertEqual(Array(found.kernel[0x202..<0x206]), Array("HdrS".utf8))
        print("\(found.origin) : noyau \(found.kernel.count) octets, initramfs \(found.initrd?.count ?? 0) octets")
        print("ligne de commande : \(found.commandLine)")
    }
}
