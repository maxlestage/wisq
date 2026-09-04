import XCTest

@testable import WisqVM

/// Les instructions de chaîne, contre le **vrai processeur**.
///
/// **Pourquoi ce fichier existe.** Un comptage : sur les 389 formes du corpus
/// arithmétique, *aucune* n'était un `MOVS`, un `STOS`, un `SCAS`, un `CMPS`
/// ni un `LODS`. Les dix-sept correspondances de « movs » qu'on y trouvait
/// étaient des `MOVSX` et des `CMOVS` — des extensions de signe et des
/// transferts conditionnels.
///
/// Or ce sont exactement les instructions dont un noyau se sert pour recopier
/// entre son espace et celui d'un programme : `copy_to_user` et
/// `copy_from_user` sont des `rep movsq` et des `rep movsb`. La pile initiale
/// d'un processus — arguments, environnement, vecteur auxiliaire, tous des
/// pointeurs — arrive par là.
///
/// **Le drapeau de direction est essayé dans les deux sens**, et il a coûté un
/// défaut au harnais avant d'en révéler dans le cœur : l'ABI exige qu'il soit
/// effacé à la sortie de toute fonction, et le harnais rendait la main au C
/// sans le faire. Tant que rien n'essayait une chaîne en arrière, l'oubli ne
/// pouvait pas se voir.
final class X86StringOracleTests: XCTestCase {
    struct State: Equatable {
        var rax: UInt64
        var rcx: UInt64
        var rsi: UInt64
        var rdi: UInt64
        var flags: UInt64
    }

    struct Case {
        let instruction: Int
        let state: Int
        let after: State
        let memory: [UInt8]?
    }

    struct Fixture {
        var states: [Int: State] = [:]
        var instructions: [Int: (bytes: [UInt8], count: UInt64, text: String)] = [:]
        var cases: [Case] = []
    }

    static let dataAddress: UInt64 = 0x3000_1000
    static let stackTop: UInt64 = 0x3000_3000
    static let windowSize = 64
    static var pristine: [UInt8] { (0..<windowSize).map { UInt8(0x10 + $0) } }

    static func witness() -> [UInt64] {
        (0..<16).map { 0xAAAA_AAAA_AAAA_AAAA &+ UInt64($0) }
    }

    /// Les registres qu'aucune forme ne doit toucher : RBX et R8 à R15. RAX,
    /// RCX, RSI et RDI sont justement ceux qu'une chaîne travaille.
    static let watchedRegisters: [Int] = [3, 8, 9, 10, 11, 12, 13, 14, 15]

    static var path: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/x86-string-oracle.tsv")
            .path
    }

    static func bytes(_ hex: Substring) -> [UInt8] {
        var out: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            out.append(UInt8(hex[index..<next], radix: 16) ?? 0)
            index = next
        }
        return out
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
                    rax: number(2), rcx: 0, rsi: number(3), rdi: number(4), flags: number(5))
            case "instr" where field.count >= 5:
                fixture.instructions[Int(field[1]) ?? -1] = (
                    bytes(field[2]), UInt64(field[3]) ?? 0, String(field[4]))
            case "cas" where field.count >= 9:
                fixture.cases.append(Case(
                    instruction: Int(field[1]) ?? -1, state: Int(field[2]) ?? -1,
                    after: State(rax: number(3), rcx: number(4), rsi: number(5),
                                 rdi: number(6), flags: number(7)),
                    memory: field[8] == "-" ? nil : bytes(field[8])))
            default:
                continue
            }
        }
        return fixture
    }

    func testTheCoreCopiesWhatTheProcessorCopies() throws {
        let fixture = try Self.read(Self.path)
        XCTAssertGreaterThan(fixture.cases.count, 300, "l'oracle doit couvrir, pas illustrer")
        XCTAssertGreaterThan(fixture.instructions.count, 40)

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
            registers[1] = program.count
            registers[4] = Self.stackTop
            registers[6] = before.rsi
            registers[7] = before.rdi
            let memory = X86Memory(size: 0x4000, base: 0x3000_0000)
            try? memory.load(program.bytes, at: 0x3000_0000)
            try? memory.load(Self.pristine, at: Self.dataAddress)
            var core = X86Core(
                registers: registers, flags: before.flags | X86Core.Flag.reserved,
                rip: 0x3000_0000, memory: memory)
            do {
                let instruction = try X86Decoder.decode(memory.dump(0x3000_0000, 15))
                try core.execute(instruction)
            } catch {
                byInstruction[program.text, default: 0] += 1
                if disagreements.count < 15 {
                    disagreements.append("  \(program.text) : refusé — \(error)")
                }
                continue
            }
            let after = State(
                rax: core.registers[0], rcx: core.registers[1],
                rsi: core.registers[6], rdi: core.registers[7],
                flags: core.flags & X86Core.Flag.arithmetic)
            var untouched = true
            for index in Self.watchedRegisters where core.registers[index] != Self.witness()[index] {
                untouched = false
            }
            let window = memory.dump(Self.dataAddress, Self.windowSize)
            let expected = item.memory ?? Self.pristine
            if after == item.after && untouched && window == expected {
                agreed += 1
                continue
            }
            byInstruction[program.text, default: 0] += 1
            if disagreements.count < 15 {
                var notes: [String] = []
                if !untouched { notes.append("un registre témoin a bougé") }
                if window != expected { notes.append("la mémoire diffère") }
                let suffix = notes.isEmpty ? "" : " — " + notes.joined(separator: ", ")
                disagreements.append(
                    "  " + program.text + ", état " + String(item.state)
                        + "\n    attendu " + describe(item.after)
                        + "\n    obtenu  " + describe(after) + suffix)
            }
        }

        let total = fixture.cases.count
        if !disagreements.isEmpty {
            let summary = byInstruction.sorted { $0.value > $1.value }
                .map { "\($0.key) × \($0.value)" }.joined(separator: ", ")
            XCTFail("""
                \(total - agreed) désaccords sur \(total) avec le vrai processeur.
                Par instruction : \(summary)
                \(disagreements.joined(separator: "\n"))
                """)
        }
        XCTAssertEqual(agreed, total)
    }

    private func describe(_ state: State) -> String {
        "rax=" + hex(state.rax) + " rcx=" + hex(state.rcx)
            + " rsi=" + hex(state.rsi) + " rdi=" + hex(state.rdi)
            + " drapeaux=" + hex(state.flags)
    }

    private func hex(_ value: UInt64) -> String { String(format: "%llx", value) }
}
