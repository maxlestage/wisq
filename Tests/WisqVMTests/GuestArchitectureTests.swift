import XCTest

@testable import WisqVM

/// Toutes les architectures pour lesquelles Linux existe, et la sélection
/// automatique du cœur.
///
/// Maxime : « sur wisq il me faut toutes les architectures Linux qui peuvent
/// exister et la bonne par rapport à l'image sera automatiquement
/// sélectionnée ». Ces tests tiennent les deux moitiés séparément, parce que
/// ce sont deux choses : **reconnaître** vingt et une familles, et en
/// **exécuter** deux. Les confondre serait annoncer ce qui n'est pas tenu.
final class GuestArchitectureTests: XCTestCase {
    // MARK: - Ce que les fichiers disent

    /// Un ELF par architecture, avec le numéro que `elf.h` lui donne.
    ///
    /// Ces numéros ne sont pas décoratifs : se tromper d'un chiffre nomme la
    /// mauvaise machine à quelqu'un, avec l'aplomb d'une phrase exacte.
    func testEveryELFMachineNumberNamesTheRightArchitecture() {
        let expected: [(UInt16, Bool, String)] = [
            (3, false, "x86 32 bits"), (62, true, "x86-64"),
            (40, false, "ARM"), (183, true, "ARM64"),
            (243, false, "RISC-V 32 bits"), (243, true, "RISC-V 64 bits"),
            (8, false, "MIPS 32 bits"), (8, true, "MIPS 64 bits"),
            (20, false, "PowerPC 32 bits"), (21, true, "PowerPC 64 bits"),
            (22, true, "IBM Z (s390x)"), (258, true, "LoongArch 64 bits"),
            (2, false, "SPARC 32 bits"), (43, true, "SPARC 64 bits"),
            (41, true, "Alpha 64 bits"), (93, false, "ARC 32 bits"),
            (252, false, "C-SKY 32 bits"), (164, false, "Hexagon 32 bits"),
            (50, true, "Itanium 64 bits"), (4, false, "68000 32 bits"),
            (189, false, "MicroBlaze 32 bits"), (113, false, "Nios II 32 bits"),
            (92, false, "OpenRISC 32 bits"), (15, false, "PA-RISC 32 bits"),
            (42, false, "SuperH 32 bits"), (94, false, "Xtensa 32 bits"),
        ]
        for (machine, sixtyFour, name) in expected {
            let architecture = GuestArchitecture.fromELF(
                machine: machine, sixtyFour: sixtyFour, big: false)
            XCTAssertEqual(architecture?.name, name, "machine \(machine)")
        }
    }

    /// Un numéro qu'aucune architecture ne porte ne reçoit **pas** de nom
    /// inventé. Nommer au hasard serait pire que de se taire : « une autre
    /// architecture » a l'air d'une réponse et n'en est pas une.
    func testAnUnknownELFMachineIsNotGivenAName() {
        XCTAssertNil(GuestArchitecture.fromELF(
            machine: 0x1234, sixtyFour: true, big: false))
    }

    /// U-Boot est le **seul** format qui nomme son architecture au lieu de la
    /// laisser deviner : un octet, à l'offset 29 de l'en-tête.
    func testTheUBootHeaderNamesItsOwnArchitecture() {
        let expected: [(UInt8, String)] = [
            (2, "ARM"), (3, "x86 32 bits"), (5, "MIPS 32 bits"), (6, "MIPS 64 bits"),
            (7, "PowerPC 32 bits"), (8, "IBM Z (s390x)"), (22, "ARM64"),
            (24, "x86-64"), (26, "RISC-V"),
        ]
        for (code, name) in expected {
            XCTAssertEqual(GuestArchitecture.fromUBoot(code)?.name, name, "code \(code)")
        }
        XCTAssertNil(GuestArchitecture.fromUBoot(200))
    }

    /// **RISC-V sans largeur, et c'est exact.** L'en-tête d'image de Linux
    /// pour RISC-V n'a aucun champ qui dise 32 ou 64 bits — un noyau rv32 et
    /// un rv64 y sont indiscernables. Alors on ne dit rien, plutôt que de
    /// mettre « 32 bits » qui aurait l'air d'une lecture.
    func testRiscVWithoutAWidthSaysSoRatherThanGuessing() {
        XCTAssertEqual(GuestArchitecture(.riscv).name, "RISC-V")
        XCTAssertNil(GuestArchitecture(.riscv).bits)
    }

    // MARK: - La sélection du cœur

    /// **La bonne machine, choisie par le fichier et personne d'autre.**
    func testTheCoreIsChosenByTheArchitectureAlone() {
        XCTAssertEqual(GuestArchitecture(.x86, bits: 64).core, .x86_64)
        XCTAssertEqual(GuestArchitecture(.riscv, bits: 32).core, .riscv32)
        // Largeur inconnue : un seul cœur existe pour la famille, donc c'est
        // celui-là. Le laisser essayer en dit plus long qu'un refus fondé sur
        // ce qu'on n'a pas lu.
        XCTAssertEqual(GuestArchitecture(.riscv).core, .riscv32)
        XCTAssertEqual(GuestArchitecture(.x86).core, .x86_64)
    }

    /// Et les architectures sans cœur n'en reçoivent pas un « approchant ».
    /// Un rv64 sur un cœur rv32 ne démarre pas ; le lancer quand même ferait
    /// chercher la panne au mauvais endroit.
    func testAnArchitectureWithNoCoreGetsNone() {
        for architecture in [
            GuestArchitecture(.riscv, bits: 64), GuestArchitecture(.x86, bits: 32),
            GuestArchitecture(.arm, bits: 64), GuestArchitecture(.powerpc, bits: 64),
            GuestArchitecture(.s390), GuestArchitecture(.loongarch, bits: 64),
        ] {
            XCTAssertNil(architecture.core, architecture.name)
        }
    }

    /// **Les deux cœurs sont branchés**, et c'est ce qui rend la liste unique.
    ///
    /// Il y avait deux listes — celles qui ont un cœur, et celles que
    /// l'application savait lancer — parce que le cœur x86-64 démarrait un
    /// vrai noyau d'Alpine pendant que `LocalVMModel` ne construisait que la
    /// machine RISC-V. `GuestMachineFactory` construit maintenant l'une ou
    /// l'autre, donc il n'y a plus qu'une liste, et ce test tient le fait que
    /// chacune de ses entrées mène vraiment à une machine.
    func testEveryRunnableArchitectureReachesAMachine() {
        XCTAssertEqual(GuestArchitecture.runnable.map(\.name),
                       ["RISC-V 32 bits", "x86-64"])
        for architecture in GuestArchitecture.runnable {
            guard let core = architecture.core else {
                XCTFail("\(architecture.name) est dans `runnable` sans cœur")
                continue
            }
            let machine = GuestMachineFactory.make(
                for: core, ramSizeBytes: 128 << 20, onOutput: { _ in })
            XCTAssertEqual(machine.ramSizeBytes, 128 << 20, architecture.name)
            XCTAssertEqual(machine.retiredInstructions, 0, architecture.name)
        }
    }

    // MARK: - Les formats, sur des octets

    /// L'image brute d'ARM64 : le nombre magique au cinquante-sixième octet.
    /// Le manuel l'écrit `"ARM\u{5C}x64"`, ce qui se lit « ARMd » — et se
    /// recopie de travers si on le lit trop vite.
    func testAnARM64ImageIsRecognisedAndNamed() {
        var bytes = [UInt8](repeating: 0, count: 0x40)
        bytes.replaceSubrange(0x38..<0x3C, with: [0x41, 0x52, 0x4D, 0x64])
        let kind = KernelImageKind.identify(prefix: Data(bytes))
        XCTAssertEqual(kind, .linuxKernel(KernelImage(
            GuestArchitecture(.arm, bits: 64), format: "Image ARM64")))
        XCTAssertNil(kind.core, "wisq n'a pas de cœur ARM64")
        XCTAssertFalse(kind.couldBootHere)
    }

    /// Le `zImage` d'ARM 32 bits : son nombre magique à 0x24, après les huit
    /// instructions de saut.
    func testAnARMZImageIsRecognised() {
        var bytes = [UInt8](repeating: 0, count: 0x40)
        bytes.replaceSubrange(0x24..<0x28, with: [0x18, 0x28, 0x6F, 0x01])
        XCTAssertEqual(KernelImageKind.identify(prefix: Data(bytes)).architecture?.name, "ARM")
    }

    /// Un `uImage` d'U-Boot, reconnu par son magique **et** son octet
    /// d'architecture.
    func testAUBootImageIsNamedByItsOwnArchitectureByte() {
        var bytes = [UInt8](repeating: 0, count: 0x100)
        bytes.replaceSubrange(0..<4, with: [0x27, 0x05, 0x19, 0x56])
        bytes[29] = 22  // ARM64, dans la table d'U-Boot
        let kind = KernelImageKind.identify(prefix: Data(bytes))
        XCTAssertEqual(kind.architecture?.name, "ARM64")
        guard case .linuxKernel(let image) = kind else { return XCTFail("attendu un noyau") }
        XCTAssertEqual(image.format, "uImage (U-Boot)")
    }

    /// Et un `uImage` dont l'octet d'architecture ne veut rien dire n'est pas
    /// nommé au hasard : c'est un emballage reconnu dont le contenu ne l'est
    /// pas, et le dire est plus utile que d'inventer.
    func testAUBootImageWithAnUnknownArchitectureSaysSo() {
        var bytes = [UInt8](repeating: 0, count: 0x100)
        bytes.replaceSubrange(0..<4, with: [0x27, 0x05, 0x19, 0x56])
        bytes[29] = 200
        XCTAssertEqual(KernelImageKind.identify(prefix: Data(bytes)),
                       .compressedKernel("uImage (U-Boot)"))
    }

    /// Un noyau **compressé** : l'enveloppe est nommée, et le message dit que
    /// l'architecture est dedans. C'est le cas le plus courant du monde réel —
    /// un `vmlinuz` de Debian pour ARM64 est un `Image` gzippé — et se taire
    /// laisserait croire que le fichier n'est rien.
    func testACompressedKernelNamesItsEnvelopeAndAdmitsWhatItCannotSee() throws {
        for (magic, format) in [
            ([0x1F, 0x8B, 0x08] as [UInt8], "gzip"),
            ([0xFD, 0x37, 0x7A, 0x58, 0x5A], "xz"),
            ([0x28, 0xB5, 0x2F, 0xFD], "zstd"),
            ([0x42, 0x5A, 0x68], "bzip2"),
            ([0x04, 0x22, 0x4D, 0x18], "lz4"),
            ([0x89, 0x4C, 0x5A, 0x4F], "lzop"),
        ] {
            var bytes = magic
            bytes += [UInt8](repeating: 0, count: 512)
            XCTAssertEqual(KernelImageKind.identify(prefix: Data(bytes)),
                           .compressedKernel(format), format)
        }
        let message = try XCTUnwrap(KernelImageKind.cannotRunHereExplanation(
            .compressedKernel("gzip"), name: "vmlinuz-6.6-arm64"))
        XCTAssertTrue(message.contains("vmlinuz-6.6-arm64"), message)
        XCTAssertTrue(message.contains("gzip"), message)
        XCTAssertTrue(message.contains("son architecture est à l'intérieur"), message)
        XCTAssertFalse(message.contains("Mo de mémoire"), message)
    }

    // MARK: - Ce que les refus disent

    /// Le refus **nomme l'architecture**. « Ce fichier est un noyau ARM64 »
    /// apprend quelque chose ; « format non pris en charge » n'apprend rien,
    /// et c'est la même faute que d'invoquer la mémoire.
    func testARefusalNamesTheArchitectureItFound() throws {
        var bytes = [UInt8](repeating: 0, count: 0x40)
        bytes.replaceSubrange(0x38..<0x3C, with: [0x41, 0x52, 0x4D, 0x64])
        let message = try XCTUnwrap(KernelImageKind.cannotRunHereExplanation(
            KernelImageKind.identify(prefix: Data(bytes)), name: "Image"))
        XCTAssertTrue(message.contains("ARM64"), message)
        XCTAssertTrue(message.contains("Image ARM64"), message)
        XCTAssertTrue(message.contains("C'est le bon genre de fichier"), message)
        XCTAssertTrue(message.contains("pas de cœur pour cette architecture"), message)
        XCTAssertFalse(message.contains("Mo de mémoire"), message)
    }

    /// Les textes des refus n'énumèrent pas les architectures à la main : ils
    /// les prennent dans la table. Sans ça, brancher un cœur laisserait des
    /// phrases périmées derrière.
    func testTheRefusalsReadTheTableRatherThanRepeatingIt() throws {
        let message = try XCTUnwrap(KernelImageKind.cannotRunHereExplanation(
            .discImage("ISO 9660"), name: "arch.iso"))
        for architecture in GuestArchitecture.runnable {
            XCTAssertTrue(message.contains(architecture.name), message)
        }
    }
}
