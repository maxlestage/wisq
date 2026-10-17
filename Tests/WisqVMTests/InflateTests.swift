import XCTest
@testable import WisqVM

/// Le décodeur deflate de `WisqVM`, contre des flux écrits par zlib.
final class InflateTests: XCTestCase {

    /// Le texte que compressent les fixtures : un octet sur trois au hasard,
    /// les autres pris dans huit lettres — de quoi donner à chaque sorte de
    /// bloc des répétitions et des littéraux. Le même générateur, en Python,
    /// a produit les flux.
    static func plain(_ count: Int, seed: Int) -> [UInt8] {
        var state = seed
        let letters = Array("abcdefgh".utf8)
        return (0..<count).map { index in
            state = (state &* 1_103_515_245 &+ 12345) & 0x7FFF_FFFF
            let value = (state >> 16) & 0xFF
            return index % 3 == 0 ? UInt8(value) : letters[value % 8]
        }
    }

    private func stream(_ base64: String) throws -> [UInt8] {
        [UInt8](try XCTUnwrap(Data(base64Encoded: base64)))
    }

    /// Chaque sorte de bloc rend le texte d'origine, octet pour octet.
    func testEveryKindOfBlockDecodesToTheOriginal() throws {
        let cases: [(String, Int, Int, String)] = [
            (InflateFixtures.stored, 700, 1, "stockés"),
            (InflateFixtures.fixed, 1500, 2, "Huffman fixe"),
            (InflateFixtures.dynamic, 4000, 3, "Huffman dynamique"),
            (InflateFixtures.rle, 3000, 4, "répétitions"),
        ]
        for (fixture, count, seed, label) in cases {
            let decoded = Inflate.raw(try stream(fixture), limit: count, exact: true)
            XCTAssertEqual(decoded, Self.plain(count, seed: seed), label)
        }
    }

    /// La sortie s'arrête au plafond — c'est ce que veut un cluster, et ce qui
    /// borne un flux qui promet bien plus que ce qu'on attend. Exiger la
    /// taille exacte d'un flux plus court rend `nil`.
    func testTheLimitStopsTheOutputAndExactnessIsChecked() throws {
        let dynamic = try stream(InflateFixtures.dynamic)
        let original = Self.plain(4000, seed: 3)
        XCTAssertEqual(Inflate.raw(dynamic, limit: 1000, exact: true), Array(original[0..<1000]))
        XCTAssertNil(Inflate.raw(dynamic, limit: 5000, exact: true), "le flux finit à 4000")
        XCTAssertEqual(Inflate.raw(dynamic, limit: 5000, exact: false), original)
    }

    /// Un flux abîmé rend `nil`, jamais des octets devinés : tronqué, type de
    /// bloc réservé, bloc stocké dont la longueur ne correspond pas à son
    /// complément.
    func testABrokenStreamIsRefused() throws {
        let dynamic = try stream(InflateFixtures.dynamic)
        XCTAssertNil(Inflate.raw(Array(dynamic[0..<(dynamic.count / 2)]), limit: 4000, exact: true))
        XCTAssertNil(Inflate.raw([0b111], limit: 10, exact: false), "type de bloc 3, réservé")
        XCTAssertNil(Inflate.raw([0b1, 5, 0, 0, 0, 1, 2, 3, 4, 5], limit: 10, exact: false))
        XCTAssertEqual(Inflate.raw([0b1, 5, 0, 0xFA, 0xFF, 1, 2, 3, 4, 5], limit: 10, exact: false),
                       [1, 2, 3, 4, 5])
        XCTAssertNil(Inflate.raw([], limit: 10, exact: false))
    }
}
