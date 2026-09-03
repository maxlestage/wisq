import XCTest

@testable import WisqVM

/// Mettre un vrai noyau là où il s'attend à être.
///
/// Ces tests tournent sur un **vrai** `bzImage` quand `WISQ_PC_KERNEL` en
/// désigne un, et sur un noyau reconstruit sinon : les valeurs de l'en-tête
/// sont celles mesurées dans `LinuxBootProtocolTests`, et le corps est du
/// remplissage reconnaissable. Ce que le chargeur fait ne dépend pas du
/// contenu du noyau — seulement de son en-tête —, donc la reconstruction
/// prouve la même chose, et le vrai fichier prouve qu'on ne s'est pas raconté
/// d'histoire sur l'en-tête.
final class X86BootLoaderTests: XCTestCase {
    /// Un `bzImage` reconstruit : l'en-tête mesuré, puis assez d'octets pour
    /// que setup et noyau soient là.
    static func syntheticKernel() -> [UInt8] {
        var bytes = LinuxBootProtocolTests.header()
        let setup = LinuxBootProtocolTests.measuredSetupBytes
        // Un noyau plus petit que le vrai : ce qui compte est que les tailles
        // annoncées et le fichier soient d'accord.
        let paragraphs: UInt32 = 1024
        let body = Int(paragraphs) * 16
        bytes[0x01F4] = UInt8(paragraphs & 0xFF)
        bytes[0x01F5] = UInt8((paragraphs >> 8) & 0xFF)
        bytes[0x01F6] = 0
        bytes[0x01F7] = 0
        bytes += [UInt8](repeating: 0, count: setup - bytes.count)
        // Le corps, reconnaissable : le chargeur doit le poser tel quel.
        bytes += (0..<body).map { UInt8(($0 &* 7) & 0xFF) }
        return bytes
    }

    static func realKernel() -> [UInt8]? {
        guard let path = ProcessInfo.processInfo.environment["WISQ_PC_KERNEL"],
              let data = FileManager.default.contents(atPath: path)
        else { return nil }
        return [UInt8](data)
    }

    func memory() -> X86Memory { X86Memory(size: 64 << 20, base: 0) }

    /// Le noyau atterrit à son adresse préférée, et ce qui y est écrit est bien
    /// le noyau en mode protégé — pas le fichier depuis son début.
    func testTheProtectedModeKernelLandsAtItsPreferredAddress() throws {
        let kernel = Self.syntheticKernel()
        let ram = memory()
        let placement = try X86BootLoader.load(kernel: kernel, into: ram)
        XCTAssertEqual(placement.kernelAddress, LinuxBootProtocolTests.measuredPreferredAddress)
        let setup = LinuxBootProtocolTests.measuredSetupBytes
        XCTAssertEqual(
            ram.dump(placement.kernelAddress, 32), Array(kernel[setup..<(setup + 32)]),
            "ce qui est chargé commence après le setup, pas au début du fichier")
    }

    /// Le point d'entrée 64 bits est à 0x200 du début du noyau, et pas au
    /// début : y sauter directement tomberait dans l'en-tête ELF interne.
    func testTheEntryPointIsTwoHundredPastTheStart() throws {
        let placement = try X86BootLoader.load(kernel: Self.syntheticKernel(), into: memory())
        XCTAssertEqual(placement.entryPoint, placement.kernelAddress + 0x200)
    }

    /// La page zéro porte l'en-tête de setup **à ses propres décalages** : le
    /// noyau relit ses champs là où il les a écrits.
    func testTheZeroPageCarriesTheSetupHeaderAtItsOwnOffsets() throws {
        let kernel = Self.syntheticKernel()
        let ram = memory()
        let placement = try X86BootLoader.load(kernel: kernel, into: ram)
        let page = ram.dump(placement.bootParametersAddress, X86BootLoader.bootParametersSize)
        XCTAssertEqual(page.count, 4096, "la page zéro fait exactement quatre kibioctets")
        // La magie « HdrS » se retrouve à 0x202, comme dans le fichier.
        XCTAssertEqual(Array(page[0x202..<0x206]), Array("HdrS".utf8))
        // Et la version aussi.
        XCTAssertEqual(
            UInt16(page[0x206]) | (UInt16(page[0x207]) << 8),
            LinuxBootProtocolTests.measuredVersion)
    }

    /// Ce que le **chargeur** doit écrire, et que le noyau ne peut pas savoir
    /// tout seul.
    func testTheLoaderWritesWhatOnlyItKnows() throws {
        let ram = memory()
        let placement = try X86BootLoader.load(
            kernel: Self.syntheticKernel(), into: ram, commandLine: "console=ttyS0 quiet")
        let page = ram.dump(placement.bootParametersAddress, X86BootLoader.bootParametersSize)

        // 0xFF : « un chargeur non enregistré ». Zéro voudrait dire LILO.
        XCTAssertEqual(page[0x210], 0xFF, "le noyau doit savoir qui l'a chargé")
        XCTAssertNotEqual(page[0x211] & 0x01, 0, "LOADED_HIGH : le noyau est au-dessus du mégaoctet")
        XCTAssertNotEqual(page[0x211] & 0x80, 0, "CAN_USE_HEAP")
        let commandLinePointer = (0..<4).reduce(UInt32(0)) {
            $0 | UInt32(page[0x228 + $1]) << (8 * UInt32($1))
        }
        XCTAssertEqual(UInt64(commandLinePointer), placement.commandLineAddress)
        // Pas d'initrd : les deux champs doivent être **écrits** à zéro, pas
        // laissés à ce que le noyau y avait.
        XCTAssertEqual(Array(page[0x218..<0x220]), [UInt8](repeating: 0, count: 8))
    }

    /// La ligne de commande est là, terminée par un zéro.
    func testTheCommandLineIsWrittenAndTerminated() throws {
        let ram = memory()
        let placement = try X86BootLoader.load(
            kernel: Self.syntheticKernel(), into: ram, commandLine: "console=ttyS0")
        let line = ram.dump(placement.commandLineAddress, 14)
        XCTAssertEqual(line, Array("console=ttyS0".utf8) + [0])
    }

    /// Une ligne de commande plus longue que ce que le noyau accepte est
    /// **coupée** ici plutôt que tronquée en silence par lui.
    func testACommandLineLongerThanAllowedIsCutHere() throws {
        let ram = memory()
        let long = String(repeating: "a", count: 5000)
        let placement = try X86BootLoader.load(
            kernel: Self.syntheticKernel(), into: ram, commandLine: long)
        let limit = Int(LinuxBootProtocolTests.measuredCommandLineLimit)
        let line = ram.dump(placement.commandLineAddress, limit + 1)
        XCTAssertEqual(line.last, 0, "elle reste terminée")
        XCTAssertEqual(line.dropLast().count, limit)
    }

    /// Ce qui n'est pas un noyau, ce qui n'a pas d'entrée 64 bits, ce qui est
    /// tronqué, et ce qui ne tient pas : quatre refus **nommés**.
    func testTheFourRefusalsAreNamed() {
        XCTAssertThrowsError(
            try X86BootLoader.load(kernel: [UInt8](repeating: 0, count: 1024), into: memory())
        ) { XCTAssertEqual($0 as? X86BootLoader.LoadError, .notAKernel) }

        var noEntry = Self.syntheticKernel()
        noEntry[0x236] = 0x3E  // xloadflags sans le bit 0
        XCTAssertThrowsError(try X86BootLoader.load(kernel: noEntry, into: memory())) {
            XCTAssertEqual($0 as? X86BootLoader.LoadError, .noSixtyFourBitEntry)
        }

        let truncated = Array(Self.syntheticKernel().prefix(
            LinuxBootProtocolTests.measuredSetupBytes + 16))
        XCTAssertThrowsError(try X86BootLoader.load(kernel: truncated, into: memory())) {
            // Un fichier plus court que ce qu'il annonce n'est même pas reconnu
            // comme un noyau : la garde de taille de la tranche 1 le refuse
            // d'abord, et c'est le bon ordre.
            XCTAssertEqual($0 as? X86BootLoader.LoadError, .notAKernel)
        }

        let small = X86Memory(size: 1 << 20, base: 0)
        XCTAssertThrowsError(try X86BootLoader.load(kernel: Self.syntheticKernel(), into: small)) {
            guard case .notEnoughMemory = $0 as? X86BootLoader.LoadError else {
                return XCTFail("attendu un refus de place, obtenu \($0)")
            }
        }
    }

    /// Le vrai noyau, quand il est là. C'est lui qui dit si l'en-tête qu'on
    /// croit lire est bien celui qu'un noyau écrit.
    func testARealKernelIsPlacedWhereItAsks() throws {
        guard let kernel = Self.realKernel() else {
            throw XCTSkip("noyau PC absent : définir WISQ_PC_KERNEL pour ce test")
        }
        let ram = X86Memory(size: 128 << 20, base: 0)
        let placement = try X86BootLoader.load(kernel: kernel, into: ram)
        let header = try XCTUnwrap(
            LinuxBootProtocol.read(from: kernel, totalBytes: kernel.count))
        XCTAssertEqual(placement.kernelAddress, header.preferredAddress)
        XCTAssertEqual(placement.reservedBytes, Int(header.initSize))
        XCTAssertGreaterThan(placement.reservedBytes, header.protectedModeBytes,
                             "il faut réserver plus que le poids : le noyau se décompresse chez lui")
        // Les premiers octets du noyau en mode protégé sont bien ceux du
        // fichier après le setup.
        XCTAssertEqual(
            ram.dump(placement.kernelAddress, 64),
            Array(kernel[header.setupBytes..<(header.setupBytes + 64)]))
    }
}
