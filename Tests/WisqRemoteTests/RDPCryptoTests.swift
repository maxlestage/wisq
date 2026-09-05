import XCTest

@testable import WisqRemote

/// Les quatre primitives de la sécurité historique de RDP, contre leurs
/// vecteurs de référence.
///
/// **Aucun de ces vecteurs n'est de moi.** MD5 vient de la RFC 1321, SHA-1 de
/// la FIPS 180-1, RC4 de la RFC 6229, et l'exponentiation d'un exemple qu'on
/// peut refaire à la main. Une primitive vérifiée contre elle-même ne prouve
/// rien : elle prouve qu'on est constant, pas qu'on est juste.
final class RDPCryptoTests: XCTestCase {
    static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - MD5, RFC 1321

    func testMD5MatchesTheRFCVectors() {
        let cases: [(String, String)] = [
            ("", "d41d8cd98f00b204e9800998ecf8427e"),
            ("a", "0cc175b9c0f1b6a831c399e269772661"),
            ("abc", "900150983cd24fb0d6963f7d28e17f72"),
            ("message digest", "f96b697d7cb7938d525a2f31aaf161d0"),
            ("abcdefghijklmnopqrstuvwxyz", "c3fcd3d76192e4007dfb496cca67e13b"),
            ("12345678901234567890123456789012345678901234567890123456789012345678901234567890",
             "57edf4a22be3c955ac49da2e2107b67a"),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(Self.hex(RDPCrypto.md5(Array(input.utf8))), expected, input)
        }
    }

    /// **Les longueurs où le remplissage bascule.** Cinquante-six octets est la
    /// première qui ne laisse plus la place au compteur de bits et force un
    /// second bloc ; soixante-quatre est un bloc entier, qui en force un de
    /// remplissage complet. C'est là que vit l'erreur d'un cran de ces
    /// fonctions, et nulle part ailleurs.
    ///
    /// Les six valeurs viennent d'`openssl dgst -md5`, pas de moi. Un premier
    /// jet en avait inventé une — dans le test qui dit précisément qu'aucun
    /// vecteur n'est de moi.
    func testMD5HandlesTheBlockBoundaries() {
        let expected: [Int: String] = [
            55: "ef1772b6dff9a122358552954ad0df65",
            56: "3b0c8ac703f828b04c6c197006d17218",
            57: "652b906d60af96844ebd21b674f35e93",
            63: "b06521f39153d618550606be297466d5",
            64: "014842d480b571495a4a0363793f7367",
            65: "c743a45e0d2e6a95cb859adae0248435",
        ]
        for (length, digest) in expected.sorted(by: { $0.key < $1.key }) {
            XCTAssertEqual(Self.hex(RDPCrypto.md5([UInt8](repeating: 0x61, count: length))),
                           digest, "\(length) octets")
        }
    }

    // MARK: - SHA-1, FIPS 180-1

    func testSHA1MatchesTheFIPSVectors() {
        XCTAssertEqual(Self.hex(RDPCrypto.sha1(Array("abc".utf8))),
                       "a9993e364706816aba3e25717850c26c9cd0d89d")
        XCTAssertEqual(Self.hex(RDPCrypto.sha1(Array(
            "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8))),
                       "84983e441c3bd26ebaae4aa1f95129e5e54670f1")
        XCTAssertEqual(Self.hex(RDPCrypto.sha1([])),
                       "da39a3ee5e6b4b0d3255bfef95601890afd80709")
        XCTAssertEqual(Self.hex(RDPCrypto.sha1([UInt8](repeating: 0x61, count: 1_000_000))),
                       "34aa973cd4c4daa4f61eeb2bdbad27316534016f")
    }

    // MARK: - RC4, RFC 6229

    func testRC4MatchesTheRFCVectors() {
        var stream = RDPCrypto.RC4(key: [0x01, 0x02, 0x03, 0x04, 0x05])
        let first = stream.process([UInt8](repeating: 0, count: 16))
        XCTAssertEqual(Self.hex(first), "b2396305f03dc027ccc3524a0a1118a8")

        var wide = RDPCrypto.RC4(key: Array("Key".utf8))
        XCTAssertEqual(Self.hex(wide.process(Array("Plaintext".utf8))), "bbf316e8d940af0ad3")
    }

    /// **Le flux continue, il ne recommence pas.** Chiffrer deux messages avec
    /// un RC4 réinitialisé donnerait deux textes avec le même flux, ce qui les
    /// révèle tous les deux. Le type porte donc son état.
    func testTheStreamContinuesAcrossMessages() {
        var whole = RDPCrypto.RC4(key: [0x01, 0x02, 0x03, 0x04, 0x05])
        let reference = whole.process([UInt8](repeating: 0, count: 16))

        var piecewise = RDPCrypto.RC4(key: [0x01, 0x02, 0x03, 0x04, 0x05])
        let head = piecewise.process([UInt8](repeating: 0, count: 5))
        let tail = piecewise.process([UInt8](repeating: 0, count: 11))
        XCTAssertEqual(head + tail, reference)
    }

    func testRC4IsItsOwnInverse() {
        let message = Array("le message qui va et revient".utf8)
        var out = RDPCrypto.RC4(key: [0xAA, 0xBB, 0xCC])
        var back = RDPCrypto.RC4(key: [0xAA, 0xBB, 0xCC])
        XCTAssertEqual(back.process(out.process(message)), message)
    }

    // MARK: - L'exponentiation modulaire

    /// Un cas qu'on peut refaire de tête : 7¹¹ mod 13 vaut 2.
    func testASmallPowerIsRight() {
        let result = RDPCrypto.modularPower(base: [7], exponent: [11], modulus: [13])
        XCTAssertEqual(result.first, 2)
    }

    /// **Les nombres de RDP sont en petit-boutiste**, module compris. Un
    /// module de deux octets le montre : `0x0100` lu à l'envers vaut 1, et
    /// tout reste modulo 1 serait zéro.
    func testTheBytesAreReadLittleEndian() {
        // module 256, base 300, exposant 1 → 300 mod 256 = 44
        let result = RDPCrypto.modularPower(base: [0x2C, 0x01], exponent: [1], modulus: [0x00, 0x01])
        XCTAssertEqual(Array(result.prefix(2)), [44, 0])
    }

    /// Le vrai cas : un module de soixante-quatre octets, l'exposant 65537, et
    /// le résultat vérifié par l'opération inverse — impossible sans la clé
    /// privée, donc vérifié autrement : `(m^e)^1 mod n` reste dans le module,
    /// et `m^1 mod n` rend `m`.
    func testAFullSizedModulusStaysInsideItself() {
        let modulus = [UInt8](repeating: 0xFF, count: 63) + [0x7F]
        let message = (0..<64).map { UInt8($0) }
        let encrypted = RDPCrypto.modularPower(base: message, exponent: [0x01, 0x00, 0x01, 0x00],
                                               modulus: modulus)
        XCTAssertEqual(encrypted.count, 64, "le résultat a la taille du module")
        let identity = RDPCrypto.modularPower(base: message, exponent: [1], modulus: modulus)
        XCTAssertEqual(identity, message, "élever à la puissance un ne change rien")
    }

    /// Le module public du serveur xrdp de ce conteneur, en petit-boutiste,
    /// tel que son certificat le donne.
    static let xrdpModulus: [UInt8] = [
        0x1D, 0xA4, 0x3A, 0xCD, 0x7E, 0xB2, 0xC7, 0x4D, 0x45, 0x9E, 0x30, 0x30,
        0xFD, 0x70, 0x13, 0x52, 0x3B, 0xBF, 0xFC, 0xF3, 0xCA, 0x33, 0x20, 0xAB,
        0x59, 0x16, 0xA4, 0xE3, 0x3A, 0x44, 0xDF, 0xFF, 0xDC, 0xD8, 0xF6, 0xDB,
        0xFC, 0x19, 0x76, 0xDE, 0x92, 0x2B, 0xCF, 0xB7, 0xDB, 0x2A, 0xD7, 0xBA,
        0x33, 0x4F, 0x3D, 0xB3, 0x90, 0x76, 0x30, 0xF2, 0x3A, 0xE3, 0x6A, 0x72,
        0xFB, 0x96, 0x77, 0xA1, 0x52, 0x14, 0xE8, 0xBD, 0x83, 0xE2, 0x5D, 0xCC,
        0xD0, 0x07, 0xEB, 0x6A, 0x74, 0x32, 0x27, 0x37, 0x30, 0x8D, 0x19, 0x36,
        0xE4, 0x0D, 0xD1, 0x43, 0x2E, 0xBE, 0x83, 0xBE, 0x2B, 0xA2, 0xB6, 0xF9,
        0xDD, 0x98, 0x5B, 0x01, 0x35, 0x5F, 0xE4, 0x5D, 0x81, 0x5E, 0xFE, 0x90,
        0x76, 0x14, 0x72, 0xD8, 0x0C, 0x08, 0x42, 0x72, 0x52, 0xFF, 0x84, 0x7C,
        0x1C, 0x5F, 0x67, 0x12, 0xA9, 0x75, 0x77, 0xFE, 0x1D, 0x7B, 0x6A, 0x8A,
        0xD8, 0xCA, 0x53, 0xFC, 0x79, 0x95, 0x43, 0x57, 0xCD, 0x49, 0xDE, 0xE1,
        0xFF, 0x3E, 0x41, 0x19, 0x68, 0x93, 0x8F, 0x1C, 0x3C, 0x6F, 0xEC, 0xB1,
        0xE3, 0xEF, 0x32, 0x70, 0x00, 0x71, 0x93, 0xF3, 0x4D, 0x40, 0x99, 0x35,
        0xF5, 0xE7, 0x98, 0xD3, 0xD1, 0x05, 0x79, 0x30, 0x0E, 0x9D, 0x17, 0xF2,
        0x69, 0x28, 0x0D, 0x83, 0x9D, 0xE5, 0x61, 0x44, 0xDD, 0x86, 0x09, 0xAB,
        0x56, 0x31, 0xEC, 0x7B, 0x59, 0x94, 0x6E, 0xFC, 0x3E, 0xAC, 0x58, 0xE2,
        0xDD, 0xC6, 0x50, 0x70, 0xA2, 0xDD, 0xCF, 0xBE, 0x3F, 0xD0, 0x38, 0x00,
        0xBF, 0x96, 0xE1, 0x1D, 0xFC, 0xD2, 0x5F, 0x9E, 0xE7, 0x7E, 0x0B, 0x95,
        0x54, 0xD9, 0x7D, 0xA0, 0xA9, 0x1F, 0xBB, 0xE8, 0x38, 0xAE, 0x8F, 0x06,
        0x57, 0x06, 0x1A, 0x07, 0xC1, 0x1C, 0x41, 0x6A, 0xFA, 0x75, 0x4B, 0x64,
        0x3D, 0x41, 0x2A, 0xB1,
    ]

    /// Ce que `python` calcule pour (0…31)^65537 mod n — et qu'il a vérifié en
    /// le déchiffrant avec la moitié privée, qui est dans
    /// `/etc/xrdp/rsakeys.ini`.
    static let xrdpCipher: [UInt8] = [
        0x39, 0x3E, 0x81, 0x0A, 0x0D, 0xCD, 0xF8, 0xCB, 0x2D, 0x43, 0xAE, 0x55,
        0xAB, 0x1E, 0xED, 0x83, 0x95, 0x21, 0x0A, 0xC1, 0x16, 0x45, 0x1B, 0x98,
        0xF5, 0xBD, 0xD1, 0x53, 0x61, 0xC4, 0x2A, 0x0F, 0x32, 0x04, 0x45, 0x7D,
        0xB6, 0x7E, 0xB0, 0x9D, 0xCA, 0x50, 0xA5, 0xFF, 0xA7, 0x23, 0x0F, 0xE0,
        0xA0, 0x21, 0x86, 0x74, 0x56, 0x6F, 0x74, 0xAD, 0x2B, 0x21, 0x16, 0x3B,
        0xB1, 0x2D, 0xE0, 0xE9, 0x37, 0x65, 0xD9, 0x0E, 0xDD, 0x30, 0xD9, 0x0A,
        0xCC, 0x0A, 0x8A, 0x41, 0xC1, 0x50, 0x07, 0xE2, 0x04, 0xBD, 0xE6, 0xA4,
        0x5B, 0x3F, 0xAA, 0xC3, 0x03, 0x33, 0x74, 0x6C, 0x6F, 0x9D, 0x4A, 0x0A,
        0x0B, 0x63, 0x52, 0x89, 0x67, 0xC4, 0xDC, 0x78, 0x46, 0x48, 0x16, 0xAF,
        0xAA, 0x53, 0x3F, 0xBC, 0x39, 0xF8, 0x3D, 0x64, 0xF1, 0xCC, 0xF5, 0x21,
        0xCF, 0x8F, 0xC7, 0x8E, 0x5D, 0xA6, 0x56, 0xB7, 0x3D, 0x9C, 0xED, 0x47,
        0x5F, 0xC5, 0xF8, 0xDA, 0xFC, 0x56, 0xD5, 0xB5, 0x13, 0x5B, 0xB6, 0x51,
        0x99, 0x7F, 0x9C, 0xE4, 0x4D, 0xEC, 0x50, 0x76, 0x22, 0x86, 0x06, 0xC9,
        0x84, 0xDF, 0x60, 0x25, 0xDB, 0xED, 0x19, 0x49, 0x6F, 0x7B, 0xD7, 0xCA,
        0x68, 0x5B, 0x9E, 0xA8, 0x92, 0xEB, 0xFE, 0x06, 0x0A, 0xCD, 0x1B, 0x9E,
        0x41, 0xA6, 0x3B, 0x87, 0xE4, 0x84, 0x33, 0xF4, 0x8F, 0x8B, 0x6B, 0xA4,
        0xC9, 0x68, 0x7E, 0xD9, 0x61, 0x39, 0x16, 0xE6, 0xCF, 0x67, 0x0A, 0x94,
        0xB7, 0x3F, 0x18, 0xFA, 0x49, 0x4D, 0x1F, 0xE9, 0x33, 0xEC, 0x84, 0xC4,
        0x9A, 0x4A, 0x1A, 0x04, 0x10, 0x29, 0x34, 0x2E, 0x93, 0x09, 0xD2, 0x14,
        0xCE, 0x71, 0xFA, 0x67, 0x84, 0x2F, 0xEA, 0xB3, 0x33, 0x83, 0x1B, 0xBE,
        0x78, 0x6F, 0x3F, 0x38, 0x96, 0x88, 0x52, 0xA7, 0x35, 0xA6, 0xE4, 0xD8,
        0x3E, 0x53, 0x60, 0xA3,
    ]

    /// **RSA contre une vraie clé, jugé par une autre implémentation.**
    ///
    /// Comparer wisq à lui-même ne prouverait rien. Ici le chiffré vient de
    /// `python`, sur la clé qu'un vrai serveur emploie, et l'aller-retour a
    /// été vérifié avec la clé privée du même serveur.
    ///
    /// C'est aussi ce qui attrape le sens des octets : RDP écrit ses nombres
    /// en **petit-boutiste**, à rebours de toute autre utilisation de RSA. Les
    /// lire à l'endroit donne un chiffré que le serveur déchiffre en bruit, et
    /// il ne le dit pas — il ferme.
    func testRSAAgainstARealServersKey() {
        let random = (0..<32).map { UInt8($0) }
        let encrypted = RDPCrypto.modularPower(base: random,
                                               exponent: [0x01, 0x00, 0x01, 0x00],
                                               modulus: Self.xrdpModulus)
        XCTAssertEqual(encrypted, Self.xrdpCipher)
    }

    /// Un module nul ne fait pas diviser par zéro : il rend vide.
    func testAZeroModulusIsRefusedRatherThanDividedBy() {
        XCTAssertTrue(RDPCrypto.modularPower(base: [5], exponent: [3], modulus: [0]).isEmpty)
    }
}
