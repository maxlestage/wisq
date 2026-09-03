import XCTest

@testable import WisqVM

/// Le différentiel : sur un vrai corpus, wisq et un désassembleur de référence
/// tombent-ils sur la même longueur ?
///
/// C'est la seule preuve qui vaille pour un décodeur x86. Écrire une table
/// d'opcodes à la main et la relire, c'est vérifier son propre travail contre
/// lui-même. La confronter à `objdump` sur des centaines de milliers
/// d'instructions produites par de vrais compilateurs, c'est une autre
/// affaire : chaque désaccord est un défaut, chez l'un ou chez l'autre, et il
/// faut aller voir lequel.
///
/// Le corpus complet n'est pas dans le dépôt — dix mégaoctets de table
/// dérivée. `Tests/Fixtures/x86-corpus.tsv` en porte un extrait distillé :
/// un représentant par forme d'instruction rencontrée, ce qui couvre les
/// longueurs sans porter les répétitions. Le corpus entier se repasse avec
/// `WISQ_X86_CORPUS`.
final class X86CorpusTests: XCTestCase {
    struct Case {
        let bytes: [UInt8]
        let length: Int
        let mnemonic: String
    }

    static func read(_ path: String) throws -> [Case] {
        let text = try String(contentsOfFile: path, encoding: .utf8)
        return text.split(whereSeparator: \.isNewline).compactMap { line in
            // Les lignes d'en-tête commencent par « # » et n'ont pas trois
            // champs : elles tombent d'elles-mêmes.
            let field = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard field.count >= 3, let length = Int(field[1]) else { return nil }
            let hex = field[0]
            var bytes: [UInt8] = []
            bytes.reserveCapacity(hex.count / 2)
            var index = hex.startIndex
            while index < hex.endIndex {
                let next = hex.index(index, offsetBy: 2)
                guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
                bytes.append(byte)
                index = next
            }
            return Case(bytes: bytes, length: length, mnemonic: String(field[2]))
        }
    }

    /// Où le fichier d'extrait vit, retrouvé depuis ce fichier de test —
    /// `Bundle.module` n'existe pas ici et le répertoire courant d'un test
    /// n'est pas garanti.
    static var fixturePath: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // WisqVMTests
            .deletingLastPathComponent()  // Tests
            .appendingPathComponent("Fixtures/x86-corpus.tsv")
            .path
    }

    /// Le rapport d'un passage : ce sur quoi les deux sont d'accord, et ce que
    /// wisq n'a pas su lire.
    struct Agreement {
        var agreed = 0
        var disagreed: [(Case, Int)] = []
        var refused: [(Case, Error)] = []
        var total: Int { agreed + disagreed.count + refused.count }
    }

    static func compare(_ cases: [Case]) -> Agreement {
        var report = Agreement()
        for item in cases {
            do {
                let length = try X86Decoder.length(of: item.bytes)
                if length == item.length {
                    report.agreed += 1
                } else {
                    report.disagreed.append((item, length))
                }
            } catch {
                report.refused.append((item, error))
            }
        }
        return report
    }

    static func describe(_ report: Agreement, limit: Int = 12) -> String {
        var lines: [String] = []
        for (item, length) in report.disagreed.prefix(limit) {
            lines.append(
                "  \(item.bytes.map { String(format: "%02x", $0) }.joined()) "
                    + "\(item.mnemonic) : objdump \(item.length), wisq \(length)")
        }
        for (item, error) in report.refused.prefix(limit) {
            lines.append(
                "  \(item.bytes.map { String(format: "%02x", $0) }.joined()) "
                    + "\(item.mnemonic) : refusé — \(error)")
        }
        return lines.joined(separator: "\n")
    }

    /// L'extrait, qui tourne partout et à chaque fois.
    func testTheDecoderAgreesWithTheReferenceOnEveryShape() throws {
        let cases = try Self.read(Self.fixturePath)
        XCTAssertGreaterThan(cases.count, 1000, "l'extrait doit couvrir, pas illustrer")
        let report = Self.compare(cases)
        XCTAssertEqual(
            report.agreed, report.total,
            "\(report.disagreed.count) désaccords, \(report.refused.count) refus :\n"
                + Self.describe(report))
    }

    /// Le corpus entier quand il est là. C'est celui-ci qui a écrit la table :
    /// chaque désaccord a été lu et corrigé avant que ce test ne devienne vert.
    func testTheWholeCorpusAgreesWhenItIsAvailable() throws {
        guard let path = ProcessInfo.processInfo.environment["WISQ_X86_CORPUS"],
              FileManager.default.fileExists(atPath: path)
        else {
            throw XCTSkip("corpus absent : définir WISQ_X86_CORPUS pour ce test")
        }
        let cases = try Self.read(path)
        // Sans cette borne, un fichier vide ou mal lu ferait passer le test
        // pour la pire des raisons : zéro d'accord sur zéro.
        XCTAssertGreaterThan(cases.count, 100_000, "le corpus entier, pas un bout")
        let report = Self.compare(cases)
        XCTAssertEqual(
            report.agreed, report.total,
            "sur \(report.total) instructions : \(report.disagreed.count) désaccords, "
                + "\(report.refused.count) refus :\n" + Self.describe(report))
    }
}
