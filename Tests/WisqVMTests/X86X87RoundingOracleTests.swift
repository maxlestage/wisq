import XCTest

@testable import WisqVM

/// **Ce que le vrai processeur rend quand le résultat ne tient pas**, dans les
/// quatre modes d'arrondi.
///
/// Le corpus x87 d'à côté fixe le mot de contrôle à `0x037F` — au plus près — et
/// ne le change jamais. Tout ce que les trois autres modes décident lui
/// échappait donc, et c'est là que les règles cessent d'être évidentes.
///
/// **Un débordement ne donne pas toujours l'infini**, et c'est la chose que ce
/// corpus a été écrit pour tenir. Mesuré sur `max × 2` :
///
/// | arrondi | `max × 2` | `-max × 2` |
/// |---|---|---|
/// | au plus près | +∞ | −∞ |
/// | vers −∞ | **le plus grand fini** | −∞ |
/// | vers +∞ | +∞ | **le plus grand fini négatif** |
/// | vers zéro | **le plus grand fini** | **le plus grand fini négatif** |
///
/// wisq écrivait déjà ces trois refus, dans un `switch` dont le `where` fait
/// encore avertir le compilateur — et **rien ne les couvrait**. Un `grep
/// overflow` dans ce répertoire ne rendait que le corpus RISC-V. La règle avait
/// l'air juste, ce qui est exactement la raison de la mesurer.
final class X86X87RoundingOracleTests: XCTestCase {
    struct Case {
        let instruction: Int
        let rounding: Int
        let pair: Int
        let top: Int
        let status: UInt16
        let tags: UInt16
        let registers: [String]
    }

    struct Fixture {
        var roundings: [Int: (name: String, control: UInt16)] = [:]
        var pairs: [Int: (zero: X86Extended, one: X86Extended, name: String)] = [:]
        var instructions: [Int: (bytes: [UInt8], text: String)] = [:]
        var cases: [Case] = []
    }

    static let dataAddress: UInt64 = 0x3000_1000
    static let stackTop: UInt64 = 0x3000_3000
    static let top = 6

    static func witness() -> [UInt64] {
        (0..<16).map { 0xAAAA_AAAA_AAAA_AAAA &+ UInt64($0) }
    }

    static var path: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/x86-x87-rounding-oracle.tsv")
            .path
    }

    static func bytes(_ hex: Substring) -> [UInt8] {
        var out: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex, let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) {
            out.append(UInt8(hex[index..<next], radix: 16) ?? 0)
            index = next
        }
        return out
    }

    static func extended(_ hex: Substring) -> X86Extended {
        X86Extended(bytes: bytes(hex))
    }

    static func read(_ path: String) throws -> Fixture {
        var fixture = Fixture()
        let text = try String(contentsOfFile: path, encoding: .utf8)
        for line in text.split(whereSeparator: \.isNewline) {
            let field = line.split(separator: "\t")
            guard let kind = field.first else { continue }
            switch kind {
            case "arrondi" where field.count >= 4:
                fixture.roundings[Int(field[1]) ?? -1] =
                    (String(field[2]), UInt16(field[3], radix: 16) ?? 0)
            case "paire" where field.count >= 6:
                fixture.pairs[Int(field[1]) ?? -1] =
                    (extended(field[4]), extended(field[5]), "\(field[2]) / \(field[3])")
            case "instr" where field.count >= 4:
                fixture.instructions[Int(field[1]) ?? -1] = (bytes(field[2]), String(field[3]))
            case "cas" where field.count >= 15:
                fixture.cases.append(Case(
                    instruction: Int(field[1]) ?? -1, rounding: Int(field[2]) ?? -1,
                    pair: Int(field[3]) ?? -1, top: Int(field[4]) ?? 0,
                    status: UInt16(field[5], radix: 16) ?? 0,
                    tags: UInt16(field[6], radix: 16) ?? 0,
                    registers: (7..<15).map { String(field[$0]) }))
            default:
                continue
            }
        }
        return fixture
    }

    /// **Les quatre modes, sur les quatre opérations, aux deux bords de la
    /// plage.** Le verdict est le registre entier, pas seulement son exposant :
    /// un débordement qui rendrait l'infini là où le processeur garde le plus
    /// grand fini se voit dans la mantisse avant de se voir ailleurs.
    func testTheCoreRoundsAtTheEdgesLikeTheProcessor() throws {
        let fixture = try Self.read(Self.path)
        XCTAssertEqual(fixture.roundings.count, 4, "les quatre modes, pas un de moins")
        XCTAssertGreaterThan(fixture.cases.count, 400, "l'oracle doit couvrir, pas illustrer")

        var disagreements: [String] = []
        var agreed = 0
        for item in fixture.cases {
            guard let before = fixture.pairs[item.pair],
                  let rounding = fixture.roundings[item.rounding],
                  let program = fixture.instructions[item.instruction]
            else {
                XCTFail("cas orphelin : \(item.instruction)/\(item.rounding)/\(item.pair)")
                continue
            }
            var registers = Self.witness()
            registers[4] = Self.stackTop
            registers[6] = Self.dataAddress
            let memory = X86Memory(size: 0x4000, base: 0x3000_0000)
            try? memory.load(program.bytes, at: 0x3000_0000)
            var core = X86Core(registers: registers, flags: 0x002 | X86Core.Flag.reserved,
                               rip: 0x3000_0000, memory: memory)
            core.x87Control = rounding.control
            core.x87Status = 0
            core.x87Tags = 0xFFFF
            core.x87TopIndex = Self.top
            core.setStack(0, before.zero)
            core.setStack(1, before.one)

            do {
                let instruction = try X86Decoder.decode(memory.dump(0x3000_0000, 15))
                try core.execute(instruction)
            } catch {
                if disagreements.count < 10 {
                    disagreements.append("  \(program.text) [\(rounding.name)] "
                        + "\(before.name) : refusé — \(error)")
                }
                continue
            }

            let got = (0..<8).map {
                core.stack($0).bytes.map { String(format: "%02x", $0) }.joined()
            }
            if got == item.registers && core.x87Tags == item.tags {
                agreed += 1
                continue
            }
            if disagreements.count < 10 {
                disagreements.append("  \(program.text) [\(rounding.name)] \(before.name)"
                    + "\n      attendu ST(0) \(item.registers[0]), obtenu \(got[0])")
            }
        }

        XCTAssertTrue(disagreements.isEmpty,
                      "\(fixture.cases.count - agreed) désaccords sur \(fixture.cases.count) :\n"
                        + disagreements.joined(separator: "\n"))
    }

    /// **Et le corpus contient bien les deux débordements**, sans quoi le test
    /// ci-dessus pourrait passer en n'ayant mesuré que de l'arithmétique
    /// ordinaire. L'infini et le plus grand fini doivent tous deux apparaître
    /// comme réponse du processeur.
    func testTheCorpusReachesBothEdges() throws {
        let fixture = try Self.read(Self.path)
        let answers = Set(fixture.cases.map { $0.registers[0] })
        XCTAssertTrue(answers.contains("0000000000000080ff7f"), "aucun +∞ dans le corpus")
        XCTAssertTrue(answers.contains("0000000000000080ffff"), "aucun −∞")
        XCTAssertTrue(answers.contains("fffffffffffffffffe7f"),
                      "aucun « plus grand fini » : le refus de l'infini n'est pas mesuré")
        XCTAssertTrue(answers.contains("fffffffffffffffffeff"),
                      "aucun « plus grand fini négatif »")
    }
}
