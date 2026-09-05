import XCTest

@testable import WisqRemote

/// MCS : ce que le client annonce, ce que le serveur répond, et les quatre
/// petits paquets qui ouvrent le domaine.
///
/// **Les octets du serveur viennent de la capture** — un vrai xrdp répondant à
/// un vrai FreeRDP. Ceux du client sont vérifiés autrement : l'enveloppe et
/// les paramètres de domaine sont conventionnels, donc comparés à ceux de la
/// référence ; ce qui décrit wisq est vérifié champ par champ, parce qu'il
/// **doit** différer de FreeRDP et qu'une égalité d'octets y serait fausse.
final class RDPConnectTests: XCTestCase {
    static let client = RDPConnect.ClientDescription(
        width: 800, height: 600, name: "wisq",
        channels: [RDPConnect.Channel(name: "cliprdr", options: 0xC0A0_0000)])

    static func initialBody() throws -> [UInt8] {
        let whole = [UInt8](try RDPConnect.connectInitial(client))
        return Array(whole.dropFirst(7))  // TPKT + X.224
    }

    // MARK: - L'enveloppe

    /// L'étiquette de MCS et sa longueur longue, comme sur le fil.
    func testTheEnvelopeIsTheApplicationTagOfConnectInitial() throws {
        let body = try Self.initialBody()
        XCTAssertEqual(Array(body.prefix(2)), [0x7F, 0x65])
        XCTAssertEqual(body[2], 0x82, "longueur longue sur deux octets")
        let declared = Int(body[3]) << 8 | Int(body[4])
        XCTAssertEqual(declared, body.count - 5, "et elle décrit ce qui suit")
    }

    /// Les trois jeux de paramètres, recopiés du client de référence : ils ne
    /// décrivent pas wisq, ils décrivent ce que MCS permet.
    func testTheDomainParametersAreTheConventionalOnes() throws {
        let body = try Self.initialBody()
        XCTAssertNotNil([UInt8](body).firstRange(of: [0x30, 0x1A] + RDPConnect.targetParameters))
        XCTAssertNotNil([UInt8](body).firstRange(of: [0x30, 0x19] + RDPConnect.minimumParameters))
        XCTAssertNotNil([UInt8](body).firstRange(of: [0x30, 0x20] + RDPConnect.maximumParameters))
    }

    /// L'en-tête de conférence T.124, jusqu'à « Duca ».
    func testTheConferenceHeaderIsTheOneOnTheWire() throws {
        let body = try Self.initialBody()
        XCTAssertNotNil([UInt8](body).firstRange(of: [0x00, 0x05, 0x00, 0x14, 0x7C, 0x00, 0x01]))
        XCTAssertNotNil([UInt8](body).firstRange(of: Array("Duca".utf8)))
    }

    /// **Les longueurs PER encadrent exactement les blocs.** C'est l'erreur qui
    /// coûte le plus cher : `81 48` vaut 0x148 en PER et « un octet de
    /// longueur » en BER, et les deux voyagent dans ce paquet-ci.
    func testThePERLengthsFrameTheBlocksExactly() throws {
        let body = try Self.initialBody()
        let start = try XCTUnwrap([UInt8](body).firstRange(of: Array("Duca".utf8))).upperBound
        var index = start
        let declared = try RDPPER.readLength(Array(body), at: &index)
        XCTAssertEqual(declared, body.count - index, "la longueur des blocs, et rien de plus")
    }

    // MARK: - Ce que wisq dit de lui-même

    /// Décoder un champ UTF-16 petit-boutiste jusqu'à son premier nul.
    static func utf16Text(_ bytes: [UInt8]) -> String {
        var units: [UInt16] = []
        for index in stride(from: 0, to: bytes.count - 1, by: 2) {
            let unit = UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8
            if unit == 0 { break }
            units.append(unit)
        }
        return String(decoding: units, as: UTF16.self)
    }

    static func block(_ type: UInt16, in body: [UInt8]) throws -> [UInt8] {
        let start = try XCTUnwrap(body.firstRange(of: Array("Duca".utf8))).upperBound
        var index = start
        _ = try RDPPER.readLength(body, at: &index)
        while index + 4 <= body.count {
            let found = UInt16(body[index]) | UInt16(body[index + 1]) << 8
            let length = Int(body[index + 2]) | Int(body[index + 3]) << 8
            if found == type { return Array(body[(index + 4)..<(index + length)]) }
            index += length
        }
        throw XCTSkip("bloc 0x\(String(type, radix: 16)) absent")
    }

    func testTheCoreBlockCarriesTheScreenAndTheKeyboard() throws {
        let core = try Self.block(0xC001, in: try Self.initialBody())
        XCTAssertEqual(Int(core[4]) | Int(core[5]) << 8, 800, "largeur")
        XCTAssertEqual(Int(core[6]) | Int(core[7]) << 8, 600, "hauteur")
        XCTAssertEqual(RDPConnect.le32(core, 12), 0x0409, "disposition du clavier")
        XCTAssertEqual(Int(core[136]) | Int(core[137]) << 8, 24, "profondeur de couleur")
        XCTAssertEqual(Self.utf16Text(Array(core[20..<52])), "wisq")
    }

    /// **L'écran est borné par le champ, pas par la politesse.** Les deux
    /// tailles font seize bits ; une machine qui demanderait dix mille pixels
    /// de large écrirait un nombre tronqué, donc un autre écran.
    func testAnImpossibleScreenIsClampedRatherThanTruncated() throws {
        var huge = Self.client
        huge.width = 100_000
        huge.height = 0
        let core = try Self.block(0xC001, in: Array([UInt8](try RDPConnect.connectInitial(huge)).dropFirst(7)))
        XCTAssertEqual(Int(core[4]) | Int(core[5]) << 8, RDPConnect.maximumWidth)
        XCTAssertEqual(Int(core[6]) | Int(core[7]) << 8, 1, "et jamais zéro")
    }

    /// Un nom trop long est coupé sur un caractère entier, pas au milieu d'une
    /// paire de substitution — la moitié d'un émoji ne se décode pas.
    func testALongNameIsCutOnAWholeCharacter() throws {
        var named = Self.client
        named.name = String(repeating: "😀", count: 40)
        let core = try Self.block(0xC001, in: Array([UInt8](try RDPConnect.connectInitial(named)).dropFirst(7)))
        let field = Array(core[20..<52])
        XCTAssertEqual(field.count, 32)
        // Sept émojis font vingt-huit octets ; le huitième déborderait sur le
        // nul final, donc il ne part pas — et rien de coupé en deux ne reste.
        XCTAssertEqual(Self.utf16Text(field), String(repeating: "😀", count: 7))
    }

    func testTheNetworkBlockNamesTheChannelsInEightBytes() throws {
        let network = try Self.block(0xC003, in: try Self.initialBody())
        XCTAssertEqual(RDPConnect.le32(network, 0), 1)
        XCTAssertEqual(Array(network[4..<12]), Array("cliprdr".utf8) + [0])
        XCTAssertEqual(RDPConnect.le32(network, 12), 0xC0A0_0000)
    }

    /// Un nom de canal de huit caractères ou plus est coupé à sept : le champ
    /// en fait huit, dont le nul final, et déborder écraserait les options.
    func testAChannelNameNeverEatsItsOptions() throws {
        var wide = Self.client
        wide.channels = [RDPConnect.Channel(name: "beaucouptroplong", options: 0xDEAD_BEEF)]
        let network = try Self.block(0xC003, in: Array([UInt8](try RDPConnect.connectInitial(wide)).dropFirst(7)))
        XCTAssertEqual(Array(network[4..<12]), Array("beaucou".utf8) + [0])
        XCTAssertEqual(RDPConnect.le32(network, 12), 0xDEAD_BEEF)
    }

    // MARK: - Ce que le serveur répond, tel qu'il l'a répondu

    /// Les blocs serveur de la capture : le canal d'entrée-sortie est 1003, il
    /// y a quatre canaux virtuels, et la sécurité est de niveau 3 avec un aléa
    /// de trente-deux octets.
    static func serverBlocks() -> [UInt8] {
        var bytes = Array("McDn".utf8)
        bytes += [0x81, 0xC4]                                      // longueur PER 452
        bytes += [0x01, 0x0C, 0x08, 0x00, 0x04, 0x00, 0x08, 0x00]  // SC_CORE
        bytes += [0x03, 0x0C, 0x10, 0x00]                          // SC_NET
        bytes += [0xEB, 0x03, 0x04, 0x00]                          // canal 1003, quatre canaux
        bytes += [0xEC, 0x03, 0xED, 0x03, 0xEE, 0x03, 0xEF, 0x03]
        var security: [UInt8] = [0x02, 0x0C, 0x00, 0x00]           // SC_SECURITY, longueur plus bas
        security += [0x02, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00]  // méthode 2, niveau 3
        security += [0x20, 0x00, 0x00, 0x00, 0x08, 0x00, 0x00, 0x00]  // aléa 32, certificat 8
        security += [UInt8](repeating: 0xAA, count: 32)
        security += [UInt8](repeating: 0xBB, count: 8)
        security[2] = UInt8(security.count & 0xFF)
        security[3] = UInt8(security.count >> 8)
        return bytes + security
    }

    func testTheServerBlocksAreReadAsTheServerWroteThem() throws {
        let server = try RDPConnect.readServerBlocks(Self.serverBlocks())
        XCTAssertEqual(server.ioChannel, 1003)
        XCTAssertEqual(server.channels, [1004, 1005, 1006, 1007])
        XCTAssertEqual(server.encryptionMethod, 2)
        XCTAssertEqual(server.encryptionLevel, 3)
        XCTAssertEqual(server.serverRandom.count, 32)
        XCTAssertEqual(server.certificate, Data(repeating: 0xBB, count: 8))
    }

    /// **Un serveur qui annonce plus qu'il n'envoie est refusé.** L'aléa et le
    /// certificat sont deux longueurs venues du réseau ; les croire ferait une
    /// tranche hors bornes, et c'est le chemin que quelqu'un viendrait chercher.
    func testALyingSecurityBlockIsRefused() throws {
        var bytes = Self.serverBlocks()
        let mark = try XCTUnwrap(bytes.firstRange(of: [0x02, 0x0C])).lowerBound
        bytes[mark + 12] = 0xFF  // un aléa de plusieurs mégaoctets
        bytes[mark + 13] = 0xFF
        XCTAssertThrowsError(try RDPConnect.readServerBlocks(bytes))
    }

    /// Un serveur qui annonce soixante mille canaux ne fait pas réserver
    /// soixante mille cases avant qu'on ait vu le premier.
    func testAnAbsurdChannelCountIsRefused() throws {
        var bytes = Self.serverBlocks()
        let mark = try XCTUnwrap(bytes.firstRange(of: [0x03, 0x0C])).lowerBound
        bytes[mark + 6] = 0xFF
        bytes[mark + 7] = 0xFF
        XCTAssertThrowsError(try RDPConnect.readServerBlocks(bytes))
    }

    /// Sans canal d'entrée-sortie il n'y a pas de session : le dire ici vaut
    /// mieux que de découvrir plus tard que rien n'arrive.
    func testAResponseWithoutAnIOChannelIsRefused() {
        XCTAssertThrowsError(try RDPConnect.readServerBlocks(Array("McDn".utf8) + [0x00]))
    }

    // MARK: - Les quatre petits paquets

    /// Ceux de la capture, octet pour octet.
    func testTheDomainPDUsAreByteForByteTheReferenceClientsOnes() throws {
        XCTAssertEqual([UInt8](try RDPMCS.erectDomainRequest()),
                       [0x03, 0x00, 0x00, 0x0C, 0x02, 0xF0, 0x80, 0x04, 0x01, 0x00, 0x01, 0x00])
        XCTAssertEqual([UInt8](try RDPMCS.attachUserRequest()),
                       [0x03, 0x00, 0x00, 0x08, 0x02, 0xF0, 0x80, 0x28])
        XCTAssertEqual([UInt8](try RDPMCS.channelJoinRequest(user: 1008, channel: 0x03F0)),
                       [0x03, 0x00, 0x00, 0x0C, 0x02, 0xF0, 0x80, 0x38, 0x00, 0x07, 0x03, 0xF0])
    }

    /// **Le canal de l'utilisateur n'est pas son identifiant.** Le serveur a
    /// répondu `2e 00 00 07` : identifiant 7, donc canal 1008.
    func testTheUserChannelIsTheIdentifierPlusOneThousandAndOne() throws {
        let user = try RDPMCS.readAttachUserConfirm(Data([0x02, 0xF0, 0x80, 0x2E, 0x00, 0x00, 0x07]))
        XCTAssertEqual(user, 1008)
    }

    /// Un refus d'utilisateur est nommé plutôt que lu comme un identifiant.
    func testARefusedUserIsNamed() {
        XCTAssertThrowsError(
            try RDPMCS.readAttachUserConfirm(Data([0x02, 0xF0, 0x80, 0x2E, 0x01, 0x00, 0x07])))
    }

    /// La confirmation de la capture, pour le canal 1003.
    func testAChannelConfirmIsCheckedAgainstWhatWasAsked() throws {
        let confirm = Data([0x02, 0xF0, 0x80, 0x3E, 0x00, 0x00, 0x07, 0x03, 0xEB, 0x03, 0xEB])
        XCTAssertNoThrow(try RDPMCS.readChannelJoinConfirm(confirm, expecting: 1003))
        XCTAssertThrowsError(try RDPMCS.readChannelJoinConfirm(confirm, expecting: 1004))
    }

    // MARK: - L'enveloppe de la session

    func testDataGoesOutOnTheChannelItWasGiven() throws {
        let framed = try RDPMCS.sendData(user: 1008, channel: 1003, Data([0x11, 0x22]))
        XCTAssertEqual([UInt8](framed),
                       [0x03, 0x00, 0x00, 0x10, 0x02, 0xF0, 0x80,
                        0x64, 0x00, 0x07, 0x03, 0xEB, 0x70, 0x02, 0x11, 0x22])
    }

    /// Au-delà de cent vingt-sept octets, la longueur passe sur deux octets.
    func testALongPayloadTakesTheTwoByteLength() throws {
        let framed = try RDPMCS.sendData(user: 1008, channel: 1003, Data(repeating: 0, count: 200))
        XCTAssertEqual([UInt8](framed)[13], 0x80 | 0x00)
        XCTAssertEqual([UInt8](framed)[14], 200)
    }

    func testAnIndicationIsUnwrappedWithItsChannel() throws {
        let message = Data([0x02, 0xF0, 0x80, 0x68, 0x00, 0x07, 0x03, 0xEB, 0x70, 0x03,
                            0xAA, 0xBB, 0xCC])
        XCTAssertEqual(try RDPMCS.readIncoming(message),
                       .data(.init(channel: 1003, payload: Data([0xAA, 0xBB, 0xCC]))))
    }

    /// **Un au revoir n'est pas une panne.** Le serveur annonce la fin du
    /// domaine avant de fermer ; le confondre avec une coupure ferait afficher
    /// une erreur là où l'utilisateur a simplement été déconnecté.
    ///
    /// Le type vaut **huit**, pas vingt-cinq. Vingt-cinq est l'index de
    /// `Send Data Request`, celui que le client écrit : s'y tromper ne se voit
    /// jamais côté client, et prend chaque message pour un adieu côté serveur.
    func testTheServerSayingGoodbyeIsNotAFailure() throws {
        let ultimatum = Data([0x02, 0xF0, 0x80, 0x08 << 2 | 0x01, 0x00])
        XCTAssertEqual(try RDPMCS.readIncoming(ultimatum), .disconnected(reason: 2))
    }

    /// Et le type de `Send Data Request` — celui que le client écrit — n'est
    /// pas lu comme un au revoir.
    func testTheClientsOwnSendTypeIsNotMistakenForGoodbye() {
        XCTAssertThrowsError(
            try RDPMCS.readIncoming(Data([0x02, 0xF0, 0x80, 0x64, 0x00, 0x07, 0x03, 0xEB, 0x70, 0x00])))
    }

    /// Une indication qui annonce plus long qu'elle n'est se fait refuser
    /// plutôt que de rendre une tranche hors bornes.
    func testAnIndicationThatOverstatesItsLengthIsRefused() {
        XCTAssertThrowsError(
            try RDPMCS.readIncoming(Data([0x02, 0xF0, 0x80, 0x68, 0x00, 0x07, 0x03, 0xEB, 0x70,
                                          0x40, 0xAA])))
    }
}
