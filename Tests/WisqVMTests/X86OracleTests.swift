import XCTest

@testable import WisqVM

/// Le cœur contre le **vrai processeur**.
///
/// Pour un décodeur, la référence est un désassembleur. Pour un cœur qui
/// calcule, il n'y en a qu'une : la machine. Ce conteneur est un x86-64, donc
/// `scripts/build-x86-oracle.py` fait exécuter chaque instruction par le
/// processeur lui-même, avec des états d'entrée choisis, et fige sa réponse
/// dans `Tests/Fixtures/x86-oracle.tsv`. Ce test rejoue chaque cas dans
/// `X86Core` et exige le même résultat, registre par registre et drapeau par
/// drapeau.
///
/// **Ce que le fichier ne fige pas.** Là où le manuel dit « indéfini » — les
/// drapeaux d'état après un `MUL`, le débordement après un décalage de
/// plusieurs bits, tout sauf le zéro après un `BSF` — le processeur pose bien
/// une valeur, mais un autre processeur aurait le droit d'en poser une autre.
/// Chaque instruction porte donc un masque des drapeaux que l'architecture lui
/// garantit, et seuls ceux-là sont comparés. « Non affecté » reste dedans : un
/// drapeau qu'une instruction laisse tranquille a une valeur prévisible, et
/// c'est ainsi qu'on vérifie que `ROL` ne touche pas au zéro.
///
/// **Ce que l'oracle ne dit pas.** Une division par zéro, ou dont le quotient
/// déborde, lève une exception : la demander au processeur tuerait le harnais.
/// Ces deux cas-là sont tenus par des tests écrits à la main, dans
/// `X86CoreTests`, et c'est le seul endroit du cœur qui ne soit pas prouvé
/// contre la machine.
final class X86OracleTests: XCTestCase {
    struct State: Equatable {
        var rax: UInt64
        var rcx: UInt64
        var rdx: UInt64
        var flags: UInt64
    }

    struct Case {
        let instruction: Int
        let state: Int
        let after: State
    }

    struct Fixture {
        var states: [Int: State] = [:]
        var instructions: [Int: (bytes: [UInt8], mask: UInt64, text: String)] = [:]
        var cases: [Case] = []
    }

    static var path: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/x86-oracle.tsv")
            .path
    }

    static func read(_ path: String) throws -> Fixture {
        var fixture = Fixture()
        let text = try String(contentsOfFile: path, encoding: .utf8)
        for line in text.split(whereSeparator: \.isNewline) {
            let field = line.split(separator: "\t")
            guard let kind = field.first else { continue }
            func number(_ index: Int) -> UInt64 { UInt64(field[index], radix: 16) ?? 0 }
            switch kind {
            case "état" where field.count >= 6:
                fixture.states[Int(field[1]) ?? -1] = State(
                    rax: number(2), rcx: number(3), rdx: number(4), flags: number(5))
            case "instr" where field.count >= 5:
                var bytes: [UInt8] = []
                let hex = field[2]
                var index = hex.startIndex
                while index < hex.endIndex {
                    let next = hex.index(index, offsetBy: 2)
                    bytes.append(UInt8(hex[index..<next], radix: 16) ?? 0)
                    index = next
                }
                fixture.instructions[Int(field[1]) ?? -1] = (
                    bytes, number(3), String(field[4]))
            case "cas" where field.count >= 7:
                fixture.cases.append(Case(
                    instruction: Int(field[1]) ?? -1, state: Int(field[2]) ?? -1,
                    after: State(rax: number(3), rcx: number(4),
                                 rdx: number(5), flags: number(6))))
            default:
                continue
            }
        }
        return fixture
    }

    /// Le témoin des douze registres qu'aucun cas ne doit toucher. Le
    /// générateur vérifie déjà que le processeur ne les change pas ; c'est ici
    /// qu'on exige la même chose du cœur.
    static func witness() -> [UInt64] {
        (0..<16).map { 0xAAAA_AAAA_AAAA_AAAA &+ UInt64($0) }
    }

    func testTheCoreAnswersWhatTheProcessorAnswers() throws {
        let fixture = try Self.read(Self.path)
        XCTAssertGreaterThan(fixture.cases.count, 5000, "l'oracle doit couvrir, pas illustrer")
        XCTAssertGreaterThan(fixture.instructions.count, 200)

        var disagreements: [String] = []
        var byInstruction: [String: Int] = [:]
        var agreed = 0
        for item in fixture.cases {
            guard let before = fixture.states[item.state],
                  let program = fixture.instructions[item.instruction]
            else {
                XCTFail("cas orphelin : instruction \(item.instruction), état \(item.state)")
                continue
            }
            var registers = Self.witness()
            registers[0] = before.rax
            registers[1] = before.rcx
            registers[2] = before.rdx
            var core = X86Core(
                registers: registers, flags: before.flags | X86Core.Flag.reserved)
            do {
                let instruction = try X86Decoder.decode(program.bytes)
                try core.execute(instruction)
            } catch {
                byInstruction[program.text, default: 0] += 1
                if disagreements.count < 15 {
                    disagreements.append("  \(program.text) : refusé — \(error)")
                }
                continue
            }
            let after = State(
                rax: core.registers[0], rcx: core.registers[1], rdx: core.registers[2],
                flags: core.flags & X86Core.Flag.arithmetic)
            let untouched = (3...15).allSatisfy {
                $0 == 4 || core.registers[$0] == Self.witness()[$0]
            }
            // Seuls les drapeaux que l'architecture définit pour cette
            // instruction sont comparés ; le reste, le manuel le dit indéfini,
            // et un autre processeur aurait le droit d'y répondre autrement.
            let mask = program.mask
            let sameFlags = after.flags & mask == item.after.flags & mask
            let sameRegisters = after.rax == item.after.rax && after.rcx == item.after.rcx
                && after.rdx == item.after.rdx
            if sameFlags && sameRegisters && untouched {
                agreed += 1
            } else {
                byInstruction[program.text, default: 0] += 1
                guard disagreements.count < 12 else { continue }
                disagreements.append(
                    "  \(program.text) [état \(item.state)] "
                        + "rax \(hex(before.rax)) rcx \(hex(before.rcx)) "
                        + "drapeaux \(hex(before.flags))\n"
                        + "      processeur : rax \(hex(item.after.rax)) "
                        + "rcx \(hex(item.after.rcx)) rdx \(hex(item.after.rdx)) "
                        + "drapeaux \(hex(item.after.flags))\n"
                        + "      wisq       : rax \(hex(after.rax)) rcx \(hex(after.rcx)) "
                        + "rdx \(hex(after.rdx)) drapeaux \(hex(after.flags))"
                        + (untouched ? "" : "\n      et il a écrit dans un registre témoin"))
            }
        }
        let summary = byInstruction.sorted { $0.value > $1.value }
            .map { "  \($0.key) × \($0.value)" }.joined(separator: "\n")
        XCTAssertEqual(
            agreed, fixture.cases.count,
            "\(fixture.cases.count - agreed) désaccords sur \(fixture.cases.count).\n"
                + "PAR INSTRUCTION :\n\(summary)\nDÉTAIL :\n"
                + disagreements.joined(separator: "\n"))
    }

    func hex(_ value: UInt64) -> String { String(value, radix: 16) }
}
