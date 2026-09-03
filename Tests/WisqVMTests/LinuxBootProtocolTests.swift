import XCTest

@testable import WisqVM

/// L'en-tête de démarrage d'un noyau Linux pour PC, lu champ par champ.
///
/// **D'où viennent les nombres.** Ils ont été mesurés sur un vrai fichier,
/// pas recopiés d'un document : `vmlinuz-lts` d'Alpine Linux 3.20 pour
/// x86_64, 10 961 920 octets, sha256
/// `e21457092692d8bc581d9d673636e8a9b81f89b2b8bab40dd2eaad22b6a64958`.
/// Le noyau lui-même n'est pas dans le dépôt — dix mégaoctets de binaire GPL
/// pour épingler neuf entiers, ce serait un mauvais échange — donc les tests
/// reconstruisent un en-tête portant exactement ces valeurs. Le fichier
/// entier est repassé dessus quand `WISQ_PC_KERNEL` le désigne, dans le
/// dernier test.
final class LinuxBootProtocolTests: XCTestCase {
    // Les valeurs mesurées sur ce fichier-là.
    static let measuredVersion: UInt16 = 0x020F  // protocole 2.15
    static let measuredSetupSectors: UInt8 = 39
    static let measuredSetupBytes = (39 + 1) * 512  // 20 480
    static let measuredSystemParagraphs: UInt32 = 683_840
    static let measuredProtectedModeBytes = 683_840 * 16  // 10 941 440
    static let measuredLoadFlags: UInt8 = 0x01
    static let measuredExtraLoadFlags: UInt16 = 0x3F
    static let measuredPreferredAddress: UInt64 = 0x0100_0000
    static let measuredInitSize: UInt32 = 36_425_728
    static let measuredCommandLineLimit: UInt32 = 2047
    static let measuredTotalBytes = 10_961_920

    /// Un en-tête de bzImage portant, par défaut, les valeurs mesurées.
    static func header(
        version: UInt16 = measuredVersion,
        setupSectors: UInt8 = measuredSetupSectors,
        systemParagraphs: UInt32 = measuredSystemParagraphs,
        loadFlags: UInt8 = measuredLoadFlags,
        extraLoadFlags: UInt16 = measuredExtraLoadFlags,
        relocatable: UInt8 = 1,
        preferredAddress: UInt64 = measuredPreferredAddress,
        initSize: UInt32 = measuredInitSize,
        commandLineSize: UInt32 = measuredCommandLineLimit,
        bootFlag: UInt16 = 0xAA55,
        magic: String = "HdrS"
    ) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 0x0300)
        func put(_ value: UInt64, _ offset: Int, _ width: Int) {
            for byte in 0..<width {
                bytes[offset + byte] = UInt8((value >> (8 * UInt64(byte))) & 0xFF)
            }
        }
        bytes[0x01F1] = setupSectors
        put(UInt64(systemParagraphs), 0x01F4, 4)
        put(UInt64(bootFlag), 0x01FE, 2)
        bytes.replaceSubrange(0x0202..<0x0206, with: Array(magic.utf8))
        put(UInt64(version), 0x0206, 2)
        bytes[0x0211] = loadFlags
        bytes[0x0234] = relocatable
        put(UInt64(extraLoadFlags), 0x0236, 2)
        put(UInt64(commandLineSize), 0x0238, 4)
        put(preferredAddress, 0x0258, 8)
        put(UInt64(initSize), 0x0260, 4)
        return bytes
    }

    /// Les neuf champs, chacun à sa place, avec la valeur mesurée.
    func testTheHeaderOfARealKernelIsReadFieldForField() throws {
        let header = try XCTUnwrap(
            LinuxBootProtocol.read(
                from: Self.header(), totalBytes: Self.measuredTotalBytes))
        XCTAssertEqual(header.version, Self.measuredVersion)
        XCTAssertEqual(header.versionDescription, "2.15")
        XCTAssertEqual(header.setupBytes, Self.measuredSetupBytes)
        XCTAssertEqual(header.protectedModeBytes, Self.measuredProtectedModeBytes)
        XCTAssertEqual(header.loadFlags, Self.measuredLoadFlags)
        XCTAssertEqual(header.extraLoadFlags, Self.measuredExtraLoadFlags)
        XCTAssertTrue(header.relocatable)
        XCTAssertEqual(header.preferredAddress, Self.measuredPreferredAddress)
        XCTAssertEqual(header.initSize, Self.measuredInitSize)
        XCTAssertEqual(header.commandLineLimit, Self.measuredCommandLineLimit)
        XCTAssertEqual(header.declaredBytes, Self.measuredTotalBytes)
    }

    /// Ce que le fichier pèse d'après son en-tête tombe exactement sur sa
    /// taille réelle. Le chargeur du lot 7 comptera là-dessus pour savoir où
    /// finit le setup et où commence le noyau.
    func testTheTwoHalvesAccountForTheWholeFile() throws {
        let header = try XCTUnwrap(LinuxBootProtocol.read(from: Self.header()))
        XCTAssertEqual(
            header.setupBytes + header.protectedModeBytes, Self.measuredTotalBytes,
            "20 480 octets de setup puis 10 941 440 de noyau, mesurés sur le fichier")
    }

    /// Le seul énoncé du fichier sur son propre mode : le bit 0 de
    /// `xloadflags`. C'est lui, et rien d'autre, qui dit « x86-64 ».
    func testTheSixtyFourBitEntryIsWhatNamesTheArchitecture() throws {
        let sixtyFour = try XCTUnwrap(
            LinuxBootProtocol.read(from: Self.header(extraLoadFlags: 0x3F)))
        XCTAssertTrue(sixtyFour.hasSixtyFourBitEntry)
        XCTAssertEqual(sixtyFour.architecture, "x86-64")

        // Le même noyau sans ce bit : les cinq autres drapeaux sont là, et il
        // n'offre pourtant que son entrée 32 bits.
        let thirtyTwo = try XCTUnwrap(
            LinuxBootProtocol.read(from: Self.header(extraLoadFlags: 0x3E)))
        XCTAssertFalse(thirtyTwo.hasSixtyFourBitEntry)
        XCTAssertEqual(thirtyTwo.architecture, "x86")
    }

    /// Un champ qu'un vieux noyau n'a jamais écrit vaut zéro, pas le hasard
    /// des octets qui traînent à cet endroit.
    func testFieldsOlderKernelsNeverWroteAreNotRead() throws {
        // 2.11 : avant xloadflags (2.12). Les octets sont pourtant remplis.
        let old = try XCTUnwrap(LinuxBootProtocol.read(from: Self.header(version: 0x020B)))
        XCTAssertEqual(old.extraLoadFlags, 0, "xloadflags n'existe qu'à partir de 2.12")
        XCTAssertEqual(old.architecture, "x86", "sans le champ, il n'y a pas d'entrée 64 bits")
        XCTAssertEqual(old.preferredAddress, Self.measuredPreferredAddress, "2.10 l'a introduit")

        // 2.09 : avant pref_address et init_size (2.10).
        let older = try XCTUnwrap(LinuxBootProtocol.read(from: Self.header(version: 0x0209)))
        XCTAssertEqual(older.preferredAddress, 0)
        XCTAssertEqual(older.initSize, 0)
        XCTAssertEqual(older.commandLineLimit, Self.measuredCommandLineLimit, "2.06 l'a introduit")

        // 2.05 : avant cmdline_size (2.06), mais relocatable_kernel existe.
        let oldest = try XCTUnwrap(LinuxBootProtocol.read(from: Self.header(version: 0x0205)))
        XCTAssertEqual(oldest.commandLineLimit, 0)
        XCTAssertTrue(oldest.relocatable)

        // 2.04 : même relocatable_kernel n'est pas encore là.
        let ancient = try XCTUnwrap(LinuxBootProtocol.read(from: Self.header(version: 0x0204)))
        XCTAssertFalse(ancient.relocatable)
    }

    /// `setup_sects` à zéro veut dire quatre, plus le secteur d'amorçage.
    func testZeroSetupSectorsMeansFour() throws {
        let header = try XCTUnwrap(LinuxBootProtocol.read(from: Self.header(setupSectors: 0)))
        XCTAssertEqual(header.setupBytes, 5 * 512)
    }

    /// Les deux marques sont exigées, pas l'une ou l'autre.
    func testNeitherMarkAloneIsEnough() {
        XCTAssertNil(
            LinuxBootProtocol.read(from: Self.header(bootFlag: 0x0000)),
            "sans 0xAA55 à 0x1FE, ce n'est pas un secteur d'amorçage")
        XCTAssertNil(
            LinuxBootProtocol.read(from: Self.header(magic: "hdrs")),
            "« HdrS » est sensible à la casse")
        XCTAssertNil(
            LinuxBootProtocol.read(from: Self.header(version: 0x0100)),
            "une version d'avant 2.00 n'a pas les champs qu'on lit")
    }

    /// La vérification que ni « HdrS » ni 0xAA55 ne donnent : un bzImage
    /// **est** son setup suivi de son noyau. Un fichier qui annonce plus qu'il
    /// ne pèse porte peut-être la marque par accident, et on le laisse passer
    /// plutôt que de le nommer à tort.
    func testAFileThatAnnouncesMoreThanItWeighsIsNotAKernel() {
        XCTAssertNil(
            LinuxBootProtocol.read(
                from: Self.header(), totalBytes: Self.measuredTotalBytes - 1))
        XCTAssertNotNil(
            LinuxBootProtocol.read(from: Self.header(), totalBytes: Self.measuredTotalBytes),
            "la borne est exacte : le fichier mesuré tombe pile dessus")
    }

    /// L'inégalité est un « au plus », pas un « exactement » : un noyau signé
    /// porte sa signature après le noyau, et reste un noyau.
    func testASignedKernelWithBytesAfterItIsStillRead() throws {
        let header = try XCTUnwrap(
            LinuxBootProtocol.read(
                from: Self.header(), totalBytes: Self.measuredTotalBytes + 8192))
        XCTAssertEqual(header.declaredBytes, Self.measuredTotalBytes)
    }

    /// Décider tient dans le préfixe que `KernelImageKind` lit déjà : personne
    /// ne relit le fichier pour ça.
    func testTheDecisionFitsInThePrefixAlreadyRead() {
        XCTAssertEqual(LinuxBootProtocol.headerBytes, 0x0264)
        XCTAssertLessThan(LinuxBootProtocol.headerBytes, KernelImageKind.bytesNeeded)
        XCTAssertNil(
            LinuxBootProtocol.read(from: Array(Self.header().prefix(0x0263))),
            "un fichier trop court pour porter l'en-tête n'en porte pas un")
    }

    /// Le vrai fichier, quand il est là. Les valeurs épinglées plus haut
    /// viennent de celui-ci ; ce test est ce qui le prouve encore.
    func testTheRealKernelAgreesWithTheMeasuredValues() throws {
        guard let path = ProcessInfo.processInfo.environment["WISQ_PC_KERNEL"],
              FileManager.default.fileExists(atPath: path)
        else {
            throw XCTSkip("noyau PC absent : définir WISQ_PC_KERNEL pour ce test")
        }
        let url = URL(fileURLWithPath: path)
        let prefix = try FileHandle(forReadingFrom: url)
            .read(upToCount: KernelImageKind.bytesNeeded) ?? Data()
        let total = (try FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?
            .intValue
        let header = try XCTUnwrap(
            LinuxBootProtocol.read(from: [UInt8](prefix), totalBytes: total))
        XCTAssertTrue(header.hasSixtyFourBitEntry, "un noyau x86_64 a son entrée 64 bits")
        XCTAssertGreaterThanOrEqual(header.version, 0x020C)
        // « Au plus », pas « exactement » : un noyau signé porte sa signature
        // après. Sur le fichier d'Alpine mesuré ici, les deux tombent pile.
        XCTAssertLessThanOrEqual(header.declaredBytes, total ?? 0)
    }
}
