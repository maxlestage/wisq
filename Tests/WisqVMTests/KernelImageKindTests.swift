import XCTest

@testable import WisqVM

/// Ce qu'un fichier est, dit avant ce qu'il pèse.
///
/// Maxime a importé `omarchy-4.0.2.iso` — une image d'installation d'Arch
/// Linux pour PC — et l'application a répondu « fait 5939.2 Mo. La machine
/// émulée n'a que 64.0 Mo de mémoire en tout ». Chaque mot est vrai et le
/// message entier est trompeur : il désigne un **nombre**, donc il envoie vers
/// le réglage de mémoire. Aucune mémoire ne fera jamais démarrer un ISO x86
/// sur un RISC-V 32 bits sans disque.
final class KernelImageKindTests: XCTestCase {
    /// Le vrai noyau que ce dépôt démarre dans ses tests, reconnu.
    ///
    /// Lu sur ses octets plutôt que sur un document : « RISCV » à 0x30 et
    /// « RSC\u{05} » à 0x38, l'en-tête d'image de démarrage RISC-V.
    func testTheRealKernelIsRecognisedAsOne() throws {
        let candidates = [
            ProcessInfo.processInfo.environment["WISQ_LINUX_IMAGE"],
            "/tmp/wisq-test-linux-image/Image",
        ]
        guard let path = candidates.compactMap({ $0 })
            .first(where: { FileManager.default.fileExists(atPath: $0) })
        else {
            throw XCTSkip("image Linux absente : définir WISQ_LINUX_IMAGE pour ce test")
        }
        let kind = KernelImageKind.identify(fileAt: URL(fileURLWithPath: path))
        XCTAssertEqual(kind, .riscvLinuxImage)
        XCTAssertTrue(kind.couldBootHere)
        XCTAssertNil(
            KernelImageKind.cannotRunHereExplanation(kind, name: "Image"),
            "le noyau qui démarre vraiment ne doit être refusé pour rien")
    }

    /// Un ISO 9660 : la signature « CD001 » au secteur 16.
    func testADiscImageIsRecognisedByItsVolumeDescriptor() {
        var iso = Data(repeating: 0, count: 40 * 1024)
        iso.replaceSubrange(0x8000..<0x8006, with: Data([0x01]) + Data("CD001".utf8))
        let kind = KernelImageKind.identify(prefix: iso)
        XCTAssertEqual(kind, .discImage("ISO 9660"))
        XCTAssertFalse(kind.couldBootHere)
    }

    /// Le descripteur peut commencer un ou deux secteurs plus loin.
    func testAVolumeDescriptorFurtherInIsStillFound() {
        for sector in [0x8800, 0x9000] {
            var iso = Data(repeating: 0, count: 40 * 1024)
            iso.replaceSubrange(sector..<(sector + 6), with: Data([0x01]) + Data("CD001".utf8))
            XCTAssertEqual(
                KernelImageKind.identify(prefix: iso), .discImage("ISO 9660"),
                "secteur 0x\(String(sector, radix: 16))")
        }
    }

    /// Un exécutable pour une autre architecture est nommé, pas seulement
    /// refusé : « x86-64 » apprend quelque chose, « incompatible » non.
    func testAnExecutableForAnotherArchitectureIsNamed() {
        func elf(machine: UInt16) -> Data {
            var bytes = [UInt8](repeating: 0, count: 0x40)
            bytes[0...3] = [0x7F, 0x45, 0x4C, 0x46][0...3]
            bytes[0x12] = UInt8(machine & 0xFF)
            bytes[0x13] = UInt8(machine >> 8)
            return Data(bytes)
        }
        XCTAssertEqual(KernelImageKind.identify(prefix: elf(machine: 0x3E)), .executable("x86-64"))
        XCTAssertEqual(KernelImageKind.identify(prefix: elf(machine: 0xB7)), .executable("ARM64"))
        XCTAssertEqual(
            KernelImageKind.identify(prefix: elf(machine: 0x1234)),
            .executable("une autre architecture"))
    }

    /// **Un ELF RISC-V n'est pas refusé.** Ce n'est pas l'image brute que
    /// cette machine attend, mais le dire serait deviner ce que quelqu'un a
    /// voulu ; `unknown` le laisse essayer.
    func testARiscVExecutableIsLetThrough() {
        var bytes = [UInt8](repeating: 0, count: 0x40)
        bytes[0...3] = [0x7F, 0x45, 0x4C, 0x46][0...3]
        bytes[0x12] = 0xF3
        XCTAssertEqual(KernelImageKind.identify(prefix: Data(bytes)), .unknown)
    }

    /// Ce qu'on ne reconnaît pas est une **permission**, pas un doute.
    ///
    /// Quelqu'un peut arriver avec une image brute sans en-tête ; la refuser
    /// parce que ce code ne la connaît pas serait pire que de la laisser
    /// échouer à l'usage.
    func testWhatIsNotRecognisedIsAllowedThrough() {
        for data in [Data(), Data([0x13, 0x00, 0x00, 0x00]), Data(repeating: 0xAB, count: 4096)] {
            let kind = KernelImageKind.identify(prefix: data)
            XCTAssertEqual(kind, .unknown)
            XCTAssertTrue(kind.couldBootHere)
            XCTAssertNil(KernelImageKind.cannotRunHereExplanation(kind, name: "brut"))
        }
    }

    /// Le refus nomme le fichier, ce qu'il est, ce qu'est la machine, et où
    /// aller. Et il ne parle **pas** de mémoire : c'est toute la correction.
    func testTheRefusalSaysWhatItIsAndNeverBlamesMemory() throws {
        let message = try XCTUnwrap(
            KernelImageKind.cannotRunHereExplanation(
                .discImage("ISO 9660"), name: "omarchy-4.0.2.iso"))
        XCTAssertTrue(message.contains("omarchy-4.0.2.iso"), message)
        XCTAssertTrue(message.contains("ISO 9660"), message)
        XCTAssertTrue(message.contains("RISC-V 32 bits"), message)
        XCTAssertTrue(
            message.contains("connectez-vous dessus"),
            "il faut dire où faire tourner la chose voulue : \(message)")
        XCTAssertTrue(
            message.contains("Ce n'est pas une question de mémoire"),
            "le message doit couper court au réglage de mémoire : \(message)")
        XCTAssertFalse(
            message.contains("Mo de mémoire"),
            "il ne doit pas ressembler à un refus de taille : \(message)")
    }

    /// Quarante kibioctets suffisent à décider. Lire six gigaoctets pour
    /// savoir ce qu'est un fichier serait la faute qui a fait disparaître
    /// l'application la première fois.
    func testDecidingCostsFortyKibibytesAtMost() {
        XCTAssertEqual(KernelImageKind.bytesNeeded, 40 * 1024)
        XCTAssertGreaterThan(
            KernelImageKind.bytesNeeded, 0x9006,
            "il faut atteindre le troisième descripteur possible")
    }
}
