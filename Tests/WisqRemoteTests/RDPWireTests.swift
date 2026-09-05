import XCTest

@testable import WisqNet
@testable import WisqRemote

/// Les deux enveloppes du RDP, et la négociation qui tient dans le premier
/// paquet.
///
/// **Les octets ne sont pas inventés.** Ils viennent d'une capture entre un
/// vrai serveur (xrdp 0.9.24) et le client de référence (FreeRDP 2.11) tournant
/// tous deux dans le conteneur où ces tests s'exécutent — quatre-vingt-quinze
/// paquets, du premier `Cookie:` jusqu'à un `Demand Active`. Chaque vecteur ci-
/// dessous est un morceau de cette conversation, recopié tel quel.
///
/// C'est ce qui rend cette tranche jugeable ici, alors que la feuille de route
/// disait le contraire : la preuve qu'une session RDP fonctionne est bien une
/// session RDP, et il y en a une.
final class RDPWireTests: XCTestCase {
    /// Le premier paquet du client, sécurité historique : trente-cinq octets.
    static let requestStandard: [UInt8] = [
        0x03, 0x00, 0x00, 0x23, 0x1E, 0xE0, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x43, 0x6F, 0x6F, 0x6B, 0x69, 0x65, 0x3A, 0x20, 0x6D, 0x73, 0x74, 0x73,
        0x68, 0x61, 0x73, 0x68, 0x3D, 0x65, 0x73, 0x73, 0x61, 0x69, 0x0D, 0x0A,
    ]
    /// La réponse du serveur quand il n'a rien négocié : onze octets, et pas
    /// un de plus.
    static let confirmStandard: [UInt8] = [
        0x03, 0x00, 0x00, 0x0B, 0x06, 0xD0, 0x00, 0x00, 0x12, 0x34, 0x00,
    ]
    /// La réponse quand il a choisi TLS.
    static let confirmTLS: [UInt8] = [
        0x03, 0x00, 0x00, 0x13, 0x0E, 0xD0, 0x00, 0x00, 0x12, 0x34, 0x00,
        0x02, 0x01, 0x08, 0x00, 0x01, 0x00, 0x00, 0x00,
    ]

    // MARK: - TPKT

    func testTheFrameCountsItsOwnHeader() throws {
        let framed = try RDPWire.frame(Data([0xAA, 0xBB]))
        XCTAssertEqual([UInt8](framed), [0x03, 0x00, 0x00, 0x06, 0xAA, 0xBB])
        XCTAssertEqual(try RDPWire.payloadLength(ofHeader: framed.prefix(4)), 2)
    }

    /// **Ce qui n'est pas du RDP est refusé au premier octet.** Un serveur HTTP
    /// répond « HTTP/1.1 », dont le `H` vaut 0x48 : le lire comme une longueur
    /// donnerait des dizaines de milliers d'octets à attendre, et l'attente ne
    /// finirait pas.
    func testSomethingThatIsNotRDPIsRefusedAtTheFirstByte() {
        XCTAssertThrowsError(
            try RDPWire.payloadLength(ofHeader: Data(Array("HTTP".utf8)))) { error in
            XCTAssertTrue("\(error)".contains("RDP"), "\(error)")
        }
    }

    /// Une longueur plus petite que l'en-tête ne désigne rien : elle donnerait
    /// une lecture négative.
    func testALengthSmallerThanTheHeaderIsRefused() {
        XCTAssertThrowsError(try RDPWire.payloadLength(ofHeader: Data([0x03, 0x00, 0x00, 0x02])))
    }

    func testAPayloadTooBigForSixteenBitsIsRefused() {
        XCTAssertThrowsError(try RDPWire.frame(Data(repeating: 0, count: 0xFFFF)))
    }

    // MARK: - X.224

    /// L'en-tête d'un message de session est constant, et c'est celui que la
    /// capture montre à chaque échange : `02 f0 80`.
    func testTheDataHeaderIsTheOneOnTheWire() throws {
        let framed = try RDPWire.frameData(Data([0x42]))
        XCTAssertEqual([UInt8](framed), [0x03, 0x00, 0x00, 0x08, 0x02, 0xF0, 0x80, 0x42])
        XCTAssertEqual([UInt8](try RDPWire.unwrapData(framed.dropFirst(4))), [0x42])
    }

    /// Une confirmation lue comme un message de données doit se plaindre du
    /// type, pas rendre des octets pris au hasard.
    func testAConfirmReadAsDataIsNamed() {
        XCTAssertThrowsError(
            try RDPWire.unwrapData(Data(Self.confirmStandard.dropFirst(4)))) { error in
            XCTAssertTrue("\(error)".contains("données"), "\(error)")
        }
    }

    /// Une longueur X.224 qui désigne au-delà du message est refusée plutôt que
    /// de faire une tranche hors bornes.
    func testAnX224LengthBeyondTheMessageIsRefused() {
        XCTAssertThrowsError(try RDPWire.unwrapData(Data([0x40, 0xF0, 0x80])))
    }

    // MARK: - Le premier paquet, contre le client de référence

    /// **Octet pour octet celui de FreeRDP.** C'est la seule vérification qui
    /// vaut : un premier paquet qui « a l'air bon » et qu'aucun serveur
    /// n'accepte ne se distingue pas d'un bon, tant qu'on n'a pas essayé.
    func testTheStandardRequestIsByteForByteTheReferenceClientsOne() throws {
        let ours = try RDPWire.connectionRequest(user: "essai", requesting: .standard)
        XCTAssertEqual([UInt8](ours), Self.requestStandard)
    }

    /// Et avec TLS demandé, les huit octets de plus, au même endroit.
    func testTheTLSRequestCarriesTheNegotiationStructure() throws {
        let ours = try RDPWire.connectionRequest(user: "essai", requesting: .tls)
        var expected = Self.requestStandard
        expected[3] = 0x2B          // la longueur TPKT passe de 35 à 43
        expected[4] = 0x26          // et la longueur X.224 de 30 à 38
        expected += [0x01, 0x00, 0x08, 0x00, 0x01, 0x00, 0x00, 0x00]
        XCTAssertEqual([UInt8](ours), expected)
    }

    /// NLA : le même paquet, avec les deux bits.
    func testAskingForCredSSPSetsBothBits() throws {
        let ours = try RDPWire.connectionRequest(
            user: "essai", requesting: [.tls, .credSSP])
        XCTAssertEqual([UInt8](ours).suffix(4), [0x03, 0x00, 0x00, 0x00])
    }

    /// Sans nom, pas de témoin — et le paquet reste valide.
    func testWithoutAUserThereIsNoCookie() throws {
        let ours = try RDPWire.connectionRequest(user: nil, requesting: .tls)
        XCTAssertEqual([UInt8](ours),
                       [0x03, 0x00, 0x00, 0x13, 0x0E, 0xE0, 0x00, 0x00, 0x00, 0x00, 0x00,
                        0x01, 0x00, 0x08, 0x00, 0x01, 0x00, 0x00, 0x00])
    }

    /// **L'injection que le client de référence laisse passer.** Mesurée :
    /// donné `bob\r\nCookie: mstshash=admin`, FreeRDP 2.11 écrit
    /// `Cookie: mstshash=bob\r\nCookie: mstshash=admin\r\n` — deux témoins de
    /// routage pour une connexion.
    ///
    /// **Ce qui fait l'injection est le retour à la ligne, pas le mot.** Sans
    /// lui, « Cookie: » n'est plus un en-tête : c'est du texte au milieu de la
    /// valeur, et aucun serveur n'y lira un second témoin. Le test porte donc
    /// sur le nombre de lignes, qui est la chose vraie, et non sur la présence
    /// du mot — un premier jet vérifiait le mot, et refusait une écriture
    /// pourtant sûre.
    func testANewlineInTheUserCannotForgeASecondCookie() throws {
        let ours = try RDPWire.connectionRequest(
            user: "bob\r\nCookie: mstshash=admin", requesting: .standard)
        let text = String(decoding: ours, as: UTF8.self)
        XCTAssertEqual(text.components(separatedBy: "\r\n").count - 1, 1,
                       "une seule fin de ligne, donc un seul en-tête : \(text)")
        XCTAssertTrue(text.hasSuffix("\r\n"), "et c'est celle qui clôt le témoin")
        XCTAssertTrue(text.contains("mstshash=bobCookie: mstshash=admin"),
                      "le reste du nom survit, à l'intérieur de la valeur : \(text)")
    }

    /// **Et la longueur X.224 tient sur un octet.** Un nom démesuré ne doit pas
    /// faire déborder ce compteur-là, sans quoi le paquet devient un autre
    /// paquet — plus court, et lu de travers.
    func testAnEnormousUserStillFitsTheSingleLengthByte() throws {
        let ours = try RDPWire.connectionRequest(
            user: String(repeating: "a", count: 4000), requesting: [.tls, .credSSP])
        XCTAssertLessThanOrEqual([UInt8](ours)[4], 255)
        XCTAssertEqual(Int([UInt8](ours)[4]) + 5, ours.count, "la longueur décrit le paquet")
        XCTAssertEqual([UInt8](ours).suffix(4), [0x03, 0x00, 0x00, 0x00],
                       "et la demande de sécurité est toujours à la fin")
    }

    // MARK: - Ce que le serveur répond

    /// **Le silence est une réponse.** Onze octets, aucune structure : le
    /// serveur parle la sécurité historique. Le prendre pour un accord tacite
    /// de TLS ferait parler chiffré à un serveur qui ne l'est pas.
    func testElevenBytesMeanStandardSecurity() throws {
        let confirm = try RDPWire.readConnectionConfirm(Data(Self.confirmStandard.dropFirst(4)))
        XCTAssertEqual(confirm, .standardSecurity)
    }

    /// La réponse de xrdp quand on lui demande TLS, telle qu'elle est passée
    /// sur le fil : type 2, drapeau 1, protocole 1.
    func testTheServersChoiceIsReadWithItsFlags() throws {
        let confirm = try RDPWire.readConnectionConfirm(Data(Self.confirmTLS.dropFirst(4)))
        XCTAssertEqual(confirm, .selected(.tls, flags: 0x01))
    }

    /// Un refus est nommé, et sa raison traduite : c'est elle qui dit à
    /// quelqu'un quoi changer.
    func testARefusalCarriesItsReason() throws {
        var bytes = Array(Self.confirmTLS.dropFirst(4))
        bytes[7] = 0x03                      // TYPE_RDP_NEG_FAILURE
        bytes[11] = 0x05                     // HYBRID_REQUIRED_BY_SERVER
        let confirm = try RDPWire.readConnectionConfirm(Data(bytes))
        XCTAssertEqual(confirm, .refused(.hybridRequiredByServer, code: 5))
        XCTAssertEqual(RDPWire.NegotiationFailure.hybridRequiredByServer.explanation,
                       "ce serveur exige l'authentification réseau (NLA)")
    }

    /// Un code de refus qu'on ne connaît pas se rend quand même : il vaut mieux
    /// dire « refusé, code 42 » que de prétendre ne pas comprendre la réponse.
    func testAnUnknownRefusalCodeIsStillReported() throws {
        var bytes = Array(Self.confirmTLS.dropFirst(4))
        bytes[7] = 0x03
        bytes[11] = 42
        XCTAssertEqual(try RDPWire.readConnectionConfirm(Data(bytes)), .refused(nil, code: 42))
    }

    /// Une réponse qui n'est pas une confirmation est nommée par son type.
    func testAnotherTPDUIsRefusedByName() {
        XCTAssertThrowsError(
            try RDPWire.readConnectionConfirm(Data([0x06, 0xE0, 0, 0, 0x12, 0x34, 0])))
    }

    /// **Ce que le serveur annonce borne ce qu'on lit.** Une confirmation qui
    /// se dit longue de six octets et en porte huit de plus n'a pas négocié :
    /// ces huit-là sont derrière la fin déclarée. Les lire comme une structure
    /// de négociation ferait choisir un protocole que le serveur n'a jamais
    /// nommé — et un sabotage a montré que sans cette garde-ci, rien ne
    /// l'empêchait : la garde de taille qui suit ne regarde que ce qui est
    /// arrivé, pas ce qui était annoncé.
    func testABytesBeyondTheDeclaredLengthAreNotANegotiation() throws {
        var bytes: [UInt8] = [0x06, 0xD0, 0x00, 0x00, 0x12, 0x34, 0x00]
        bytes += [0x02, 0x01, 0x08, 0x00, 0x02, 0x00, 0x00, 0x00]  // « CredSSP choisi »
        XCTAssertEqual(try RDPWire.readConnectionConfirm(Data(bytes)), .standardSecurity)
    }

    func testATruncatedConfirmIsRefused() {
        XCTAssertThrowsError(try RDPWire.readConnectionConfirm(Data([0x06, 0xD0, 0x00])))
    }
}
