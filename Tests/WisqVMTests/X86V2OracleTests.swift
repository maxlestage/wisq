import XCTest

@testable import WisqVM

/// **Ce que x86-64-v2 ajoute**, contre le vrai processeur.
///
/// Même méthode que les corpus précédents : `scripts/build-x86-v2-oracle.py`
/// fait exécuter chaque forme par le processeur de ce conteneur sur des états
/// choisis, et fige sa réponse dans `Tests/Fixtures/x86-v2-oracle.tsv`. Ce
/// corpus rapporte en plus RCX, les drapeaux et la fenêtre de mémoire : les
/// tranches suivantes — `PTEST`, `PCMPISTRI`, `PEXTR*` vers la mémoire — en
/// écrivent. Ce qu'une forme ne touche pas, le générateur l'a vérifié sur la
/// machine ; c'est exigé ici du cœur.
final class X86V2OracleTests: XCTestCase {
    struct State: Equatable {
        var low0: UInt64, high0: UInt64, low1: UInt64, high1: UInt64
        var rax: UInt64, rcx: UInt64, flags: UInt64
    }

    struct Case {
        let instruction: Int
        let state: Int
        let after: State
        /// La fenêtre de mémoire après coup, ou nil quand elle n'a pas bougé.
        let memory: [UInt8]?
    }

    struct Fixture {
        var states: [Int: State] = [:]
        var instructions: [Int: (bytes: [UInt8], text: String)] = [:]
        var cases: [Case] = []
    }

    static var path: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/x86-v2-oracle.tsv")
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
            case "état" where field.count >= 9:
                fixture.states[Int(field[1]) ?? -1] = State(
                    low0: number(2), high0: number(3), low1: number(4), high1: number(5),
                    rax: number(6), rcx: number(7), flags: number(8))
            case "instr" where field.count >= 4:
                fixture.instructions[Int(field[1]) ?? -1] = (
                    X86SIMDOracleTests.bytes(field[2]), String(field[3]))
            case "cas" where field.count >= 11:
                fixture.cases.append(Case(
                    instruction: Int(field[1]) ?? -1, state: Int(field[2]) ?? -1,
                    after: State(low0: number(3), high0: number(4), low1: number(5),
                                 high1: number(6), rax: number(7), rcx: number(8),
                                 flags: number(9)),
                    memory: field[10] == "-" ? nil : X86SIMDOracleTests.bytes(field[10])))
            default:
                continue
            }
        }
        return fixture
    }

    func testTheCoreComputesWhatTheProcessorComputes() throws {
        let fixture = try Self.read(Self.path)
        XCTAssertGreaterThan(fixture.cases.count, 1500, "l'oracle doit couvrir, pas illustrer")
        XCTAssertGreaterThan(fixture.instructions.count, 30)

        var disagreements: [String] = []
        var byInstruction: [String: Int] = [:]
        var agreed = 0
        let witness = X86SIMDOracleTests.witness()
        let witnessVectors = X86SIMDOracleTests.witnessVectors()
        for item in fixture.cases {
            guard let before = fixture.states[item.state],
                  let program = fixture.instructions[item.instruction]
            else {
                XCTFail("cas orphelin : instruction \(item.instruction), état \(item.state)")
                continue
            }
            var registers = witness
            registers[0] = before.rax
            registers[1] = before.rcx
            registers[4] = X86SIMDOracleTests.stackTop
            registers[6] = X86SIMDOracleTests.dataAddress
            let memory = X86Memory(size: 0x4000, base: 0x3000_0000)
            try? memory.load(program.bytes, at: 0x3000_0000)
            try? memory.load(X86SIMDOracleTests.pristine, at: X86SIMDOracleTests.dataAddress)
            var core = X86Core(
                registers: registers, flags: before.flags | X86Core.Flag.reserved,
                rip: 0x3000_0000, memory: memory)
            core.vectors = witnessVectors
            core.setVector(0, before.low0, before.high0)
            core.setVector(1, before.low1, before.high1)
            do {
                let instruction = try X86Decoder.decode(memory.dump(0x3000_0000, 15))
                try core.execute(instruction)
            } catch {
                byInstruction[program.text, default: 0] += 1
                if disagreements.count < 15 { disagreements.append("  \(program.text) : refusé — \(error)") }
                continue
            }
            let after = State(
                low0: core.vectors[0], high0: core.vectors[1],
                low1: core.vectors[2], high1: core.vectors[3],
                rax: core.registers[0], rcx: core.registers[1],
                flags: core.flags & X86Core.Flag.arithmetic)
            let untouchedVectors = (2..<16).allSatisfy { X86SIMDOracleTests.same(core.vectors, witnessVectors, $0) }
            let untouched = [2, 3, 8, 9, 10, 11, 12, 13, 14, 15].allSatisfy { core.registers[$0] == witness[$0] }
            let window = memory.dump(X86SIMDOracleTests.dataAddress, X86SIMDOracleTests.windowSize)
            let expected = item.memory ?? X86SIMDOracleTests.pristine
            if after == item.after && untouched && untouchedVectors && window == expected {
                agreed += 1
                continue
            }
            byInstruction[program.text, default: 0] += 1
            if disagreements.count < 15 {
                var notes: [String] = []
                if !untouchedVectors { notes.append("un autre XMM a bougé") }
                if !untouched { notes.append("un registre général a bougé") }
                if window != expected { notes.append("la mémoire diffère") }
                disagreements.append("  \(program.text), état \(item.state)\n    attendu \(item.after)"
                                     + "\n    obtenu  \(after)" + (notes.isEmpty ? "" : " — " + notes.joined(separator: ", ")))
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

    /// **Un élargissement ne lit que ce qu'il élargit.** `PMOVZXBQ` prend
    /// deux octets ; posés aux deux derniers de la mémoire, ils se lisent, et
    /// une lecture de seize déborderait — sur une vraie machine, sur une page
    /// qui peut ne pas exister. Le corpus ne le voit pas : sa fenêtre est
    /// suivie d'autre mémoire.
    func testAWideningReadsOnlyWhatItWidens() throws {
        let base: UInt64 = 0x3000_0000
        let memory = X86Memory(size: 0x1000, base: base)
        try memory.load([0x66, 0x0F, 0x38, 0x32, 0x06], at: base)  // pmovzxbq (%rsi), %xmm0
        try memory.load([0x81, 0x7F], at: base + 0xFFE)
        var registers = X86SIMDOracleTests.witness()
        registers[6] = base + 0xFFE
        var core = X86Core(registers: registers, flags: X86Core.Flag.reserved, rip: base, memory: memory)
        try core.execute(X86Decoder.decode(memory.dump(base, 15)))
        XCTAssertEqual(core.vectors[0], 0x81)
        XCTAssertEqual(core.vectors[1], 0x7F)
    }

    /// **Sans `66`, c'est MMX**, et le cœur le refuse au lieu de l'exécuter
    /// sur un registre XMM.
    func testTheMMXFormsAreRefused() throws {
        for bytes: [UInt8] in [[0x0F, 0x38, 0x00, 0xC1], [0x0F, 0x3A, 0x0F, 0xC1, 0x04]] {
            let memory = X86Memory(size: 0x1000, base: 0x3000_0000)
            try memory.load(bytes, at: 0x3000_0000)
            var core = X86Core(registers: X86SIMDOracleTests.witness(), flags: X86Core.Flag.reserved,
                               rip: 0x3000_0000, memory: memory)
            let instruction = try X86Decoder.decode(memory.dump(0x3000_0000, 15))
            XCTAssertThrowsError(try core.execute(instruction), "\(bytes)")
        }
    }
}
