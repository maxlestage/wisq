import XCTest
@testable import WisqVM

/// La décompression zstd, contre ce qu'écrit l'outil de référence.
final class ZstdTests: XCTestCase {
    /// Le texte des fixtures : des mots tirés par le même générateur
    /// congruentiel que le script qui les a écrites, séparés d'une espace ou,
    /// une fois sur seize, d'un retour à la ligne.
    static func words(_ count: Int, vocabulary: Int) -> [UInt8] {
        let all = ["noyau", "disque", "racine", "wisq", "machine", "page", "mémoire", "trame", "bloc",
                   "séquence", "littéral", "table"]
        let chosen = Array(all.prefix(vocabulary))
        var x: UInt64 = 1
        var text = ""
        for _ in 0..<count {
            x = (x &* 1_103_515_245 &+ 12345) & 0x7FFF_FFFF
            text += chosen[Int((x >> 16) % UInt64(chosen.count))]
            text += (x >> 8) & 15 == 0 ? "\n" : " "
        }
        return Array(text.utf8)
    }

    /// Une trame entière : la somme de contrôle de fin est sautée, et une
    /// trame sans elle se lit pareil.
    func testASmallFrameWithAndWithoutChecksum() throws {
        XCTAssertEqual(try Zstd.decompress(ZstdFixtures.small), Array("wisq lit zstd".utf8))
        XCTAssertEqual(try Zstd.decompress(ZstdFixtures.smallNocheck), Array("wisq lit zstd".utf8))
        XCTAssertTrue(Zstd.looksLikeZstd(ZstdFixtures.small))
        XCTAssertFalse(Zstd.looksLikeZstd(Array("wisq".utf8)))
    }

    /// Un bloc répété : deux cent mille zéros en trente octets.
    func testARepeatedBlock() throws {
        XCTAssertLessThan(ZstdFixtures.zeros.count, 40)
        XCTAssertEqual(try Zstd.decompress(ZstdFixtures.zeros), [UInt8](repeating: 0, count: 200_000))
    }

    /// Un bloc brut, construit ici : l'en-tête de trame, puis un bloc de
    /// type 0 qui porte ses octets tels quels.
    func testARawBlock() throws {
        let payload = (0..<300).map { UInt8(truncatingIfNeeded: $0 &* 37 &+ 11) }
        // Le magic, puis le descripteur 0x60 : un seul segment, et la taille
        // du contenu sur deux octets, écrite moins 256.
        let header: [UInt8] = [0x28, 0xB5, 0x2F, 0xFD, 0x60, UInt8(300 - 256), 0]
        let block = UInt32(300) << 3 | 1  // dernier bloc, brut
        let frame = header + [UInt8(block & 0xFF), UInt8((block >> 8) & 0xFF), UInt8(block >> 16)] + payload
        XCTAssertEqual(try Zstd.decompress(frame), payload)
    }

    /// **Les littéraux en Huffman et les séquences en FSE**, tables décrites
    /// dans le bloc : trois mille mots écrits en `zstd -19`.
    func testHuffmanLiteralsAndDescribedSequenceTables() throws {
        XCTAssertEqual(try Zstd.decompress(ZstdFixtures.short19), Self.words(3000, vocabulary: 12))
    }

    /// **Les tables prédéfinies** : un bloc trop court pour qu'une table
    /// décrite vaille la peine. Aucune des autres fixtures ne les emploie, et
    /// une distribution prédéfinie fausse passait sans elle.
    func testThePredefinedSequenceTables() throws {
        let sentence = "Le noyau lit le disque, le disque lit la racine ; wisq lit le noyau, "
            + "puis le disque, puis la racine. "
        XCTAssertEqual(try Zstd.decompress(ZstdFixtures.predefined),
                       Array(String(repeating: sentence, count: 3).utf8))
    }

    /// **Plusieurs blocs**, dont les suivants reprennent les tables et l'arbre
    /// du précédent, et des copies qui chevauchent ce qu'elles écrivent.
    func testSeveralBlocksThatReuseTheirTables() throws {
        let expected = Self.words(30000, vocabulary: 4)
        XCTAssertGreaterThan(expected.count, 128 * 1024, "plus d'un bloc")
        XCTAssertEqual(try Zstd.decompress(ZstdFixtures.words19), expected)
    }

    /// Deux trames bout à bout, puis une trame à sauter devant : tout se lit,
    /// et seules les vraies trames donnent des octets.
    func testFramesFollowOneAnotherAndSkippableFramesAreSkipped() throws {
        let expected = Array("wisq lit zstd".utf8) + Self.words(3000, vocabulary: 12)
        XCTAssertEqual(try Zstd.decompress(ZstdFixtures.multi), expected)
        let skippable: [UInt8] = [0x50, 0x2A, 0x4D, 0x18, 3, 0, 0, 0, 9, 9, 9]
        XCTAssertEqual(try Zstd.decompress(skippable + ZstdFixtures.small), Array("wisq lit zstd".utf8))
    }

    /// **Ce qui n'est pas lisible le dit** : pas une trame, une trame coupée,
    /// une trame qui demande un dictionnaire, un octet changé au milieu des
    /// séquences.
    func testWhatCannotBeReadSaysSo() throws {
        XCTAssertThrowsError(try Zstd.decompress(Array("pas du zstd".utf8))) {
            XCTAssertEqual($0 as? Zstd.Failure, .notZstd)
        }
        XCTAssertThrowsError(try Zstd.decompress(Array(ZstdFixtures.short19.prefix(200))))
        // Le descripteur avec un identifiant de dictionnaire sur un octet.
        let withDictionary: [UInt8] = [0x28, 0xB5, 0x2F, 0xFD, 0x21, 7, 0, 1, 0, 0]
        XCTAssertThrowsError(try Zstd.decompress(withDictionary)) {
            XCTAssertEqual($0 as? Zstd.Failure, .dictionary)
        }
        var damaged = ZstdFixtures.short19
        damaged[damaged.count / 2] ^= 0x5A
        XCTAssertNotEqual(try? Zstd.decompress(damaged), Self.words(3000, vocabulary: 12),
                          "un octet changé ne rend pas le texte, et rien ne plante")
    }

    /// **Chaque fichier `.zst` d'un dossier**, rendu à son original : le
    /// banc local, avec des sorties de `zstd` à tous les niveaux. Armé par
    /// `WISQ_ZSTD_DIR`, qui contient `nom.bin` et ses `nom*.zst`.
    func testEveryReferenceFileInAFolderComesBack() throws {
        guard let folder = ProcessInfo.processInfo.environment["WISQ_ZSTD_DIR"] else {
            throw XCTSkip("définir WISQ_ZSTD_DIR pour ce test")
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: folder).filter { $0.hasSuffix(".zst") }
        XCTAssertFalse(names.isEmpty)
        for name in names.sorted() where name != "multi.zst" {
            let compressed = try [UInt8](Data(contentsOf: URL(fileURLWithPath: folder + "/" + name)))
            let base = String(name.dropLast(4).prefix { $0.isLetter })
            let expected = try [UInt8](Data(contentsOf: URL(fileURLWithPath: folder + "/" + base + ".bin")))
            XCTAssertEqual(try Zstd.decompress(compressed), expected, name)
        }
    }
}
