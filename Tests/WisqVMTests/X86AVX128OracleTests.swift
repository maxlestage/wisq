import XCTest

@testable import WisqVM

/// **Les formes VEX.128 de SSE**, contre le vrai processeur.
///
/// `scripts/build-x86-avx128-oracle.py` récrit en VEX chaque instruction
/// vectorielle des quatre corpus SSE — xmm2 en première source, et les cas où
/// une source est la destination —, la fait exécuter par le processeur de ce
/// conteneur et fige sa réponse dans `Tests/Fixtures/x86-avx128-oracle.tsv`.
/// xmm3 à xmm15 et les registres généraux qu'aucune forme ne nomme doivent
/// revenir intacts : c'est là que se verrait un registre de passage mal rendu.
final class X86AVX128OracleTests: XCTestCase {
    struct State: Equatable {
        var low0: UInt64, high0: UInt64, low1: UInt64, high1: UInt64, low2: UInt64, high2: UInt64
        var rax: UInt64, rcx: UInt64, flags: UInt64, rdx: UInt64
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
            .appendingPathComponent("Fixtures/x86-avx128-oracle.tsv")
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
            case "état" where field.count >= 12:
                fixture.states[Int(field[1]) ?? -1] = State(
                    low0: number(2), high0: number(3), low1: number(4), high1: number(5),
                    low2: number(6), high2: number(7),
                    rax: number(8), rcx: number(9), flags: number(10), rdx: number(11))
            case "instr" where field.count >= 4:
                fixture.instructions[Int(field[1]) ?? -1] = (
                    X86SIMDOracleTests.bytes(field[2]), String(field[3]))
            case "cas" where field.count >= 14:
                fixture.cases.append(Case(
                    instruction: Int(field[1]) ?? -1, state: Int(field[2]) ?? -1,
                    after: State(low0: number(3), high0: number(4), low1: number(5),
                                 high1: number(6), low2: number(7), high2: number(8),
                                 rax: number(9), rcx: number(10), flags: number(11), rdx: number(13)),
                    memory: field[12] == "-" ? nil : X86SIMDOracleTests.bytes(field[12])))
            default:
                continue
            }
        }
        return fixture
    }

    func testTheCoreComputesWhatTheProcessorComputes() throws {
        let fixture = try Self.read(Self.path)
        XCTAssertGreaterThan(fixture.cases.count, 40000, "l'oracle doit couvrir, pas illustrer")
        XCTAssertGreaterThan(fixture.instructions.count, 1100)

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
            registers[2] = before.rdx
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
            core.setVector(2, before.low2, before.high2)
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
                low2: core.vectors[4], high2: core.vectors[5],
                rax: core.registers[0], rcx: core.registers[1],
                flags: core.flags & X86Core.Flag.arithmetic, rdx: core.registers[2])
            let untouchedVectors = (3..<16).allSatisfy { X86SIMDOracleTests.same(core.vectors, witnessVectors, $0) }
            let untouched = [3, 8, 9, 10, 11, 12, 13, 14, 15].allSatisfy { core.registers[$0] == witness[$0] }
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

    /// **Les registres de xmm8 à xmm15**, que l'oracle ne nomme pas : VEX
    /// porte R et B inversés, et `vvvv` sur quatre bits. Calculés à la main.
    func testTheHighVectorRegistersAreReachedThroughVEX() throws {
        let program: [UInt8] = [
            0xC4, 0x41, 0x31, 0xFE, 0xD3,  // vpaddd %xmm11, %xmm9, %xmm10
            0xC4, 0xC1, 0x09, 0x72, 0xF4, 0x04,  // vpslld $4, %xmm12, %xmm14
            0xC4, 0x41, 0x29, 0xEF, 0xD2,  // vpxor %xmm10, %xmm10, %xmm10
            0xC4, 0x41, 0x29, 0xFE, 0xC9,  // vpaddd %xmm9, %xmm10, %xmm9 : r/m est la destination
            0xC4, 0xC1, 0x61, 0x72, 0xF4, 0x04,  // vpslld $4, %xmm12, %xmm3 : vvvv sous xmm8
        ]
        let base: UInt64 = 0x3000_0000
        let memory = X86Memory(size: 0x1000, base: base)
        try memory.load(program, at: base)
        var core = X86Core(registers: X86SIMDOracleTests.witness(), flags: X86Core.Flag.reserved, rip: base, memory: memory)
        core.vectors = X86SIMDOracleTests.witnessVectors()
        core.setVector(9, 0x0000_0001_0000_0002, 3)
        core.setVector(11, 0x0000_0010_0000_0020, 0x30)
        core.setVector(12, 0x0000_0001_0000_0001, 0xF000_0000_0000_0001)
        try core.execute(X86Decoder.decode(memory.dump(core.rip, 15)))
        XCTAssertEqual(core.vector(10).low, 0x0000_0011_0000_0022)
        XCTAssertEqual(core.vector(10).high, 0x33)
        XCTAssertEqual(core.vector(9).low, 0x0000_0001_0000_0002, "vvvv n'est qu'une source")
        try core.execute(X86Decoder.decode(memory.dump(core.rip, 15)))
        XCTAssertEqual(core.vector(14).low, 0x0000_0010_0000_0010)
        XCTAssertEqual(core.vector(14).high, 0x0000_0000_0000_0010)
        XCTAssertEqual(core.vector(12).low, 0x0000_0001_0000_0001, "la source d'un décalage reste")
        try core.execute(X86Decoder.decode(memory.dump(core.rip, 15)))
        XCTAssertEqual(core.vector(10).low, 0)
        XCTAssertEqual(core.vector(10).high, 0)
        // Le registre de passage est xmm0 : le bit B doit être récrit avec lui.
        try core.execute(X86Decoder.decode(memory.dump(core.rip, 15)))
        XCTAssertEqual(core.vector(9).low, 0x0000_0001_0000_0002)
        XCTAssertEqual(core.vector(9).high, 3)
        XCTAssertEqual(core.vectors[0], X86SIMDOracleTests.witnessVectors()[0], "xmm0 rendu")
        try core.execute(X86Decoder.decode(memory.dump(core.rip, 15)))
        XCTAssertEqual(core.vector(3).low, 0x0000_0010_0000_0010)
        XCTAssertEqual(core.vector(11).low, 0x0000_0010_0000_0020, "xmm11 n'est pas nommé")
        XCTAssertEqual(core.rip, base + UInt64(program.count))
    }

    /// **Une faute laisse tout comme avant** : la destination, recopiée de
    /// `vvvv` avant l'opération, est rendue quand la mémoire manque.
    func testAFaultLeavesTheDestinationAlone() throws {
        let base: UInt64 = 0x3000_0000
        let memory = X86Memory(size: 0x1000, base: base)
        try memory.load([0xC5, 0xE9, 0xFE, 0x06], at: base)  // vpaddd (%rsi), %xmm2, %xmm0
        var registers = X86SIMDOracleTests.witness()
        registers[6] = 0x7000_0000
        var core = X86Core(registers: registers, flags: X86Core.Flag.reserved, rip: base, memory: memory)
        core.vectors = X86SIMDOracleTests.witnessVectors()
        XCTAssertThrowsError(try core.execute(X86Decoder.decode(memory.dump(base, 15))))
        XCTAssertEqual(core.vectors, X86SIMDOracleTests.witnessVectors())
    }

    /// **Ce qui n'est pas SSE reste refusé** : une forme à deux opérandes
    /// dont `vvvv` n'est pas 1111, une opération entière sans 66 — ce
    /// serait MMX —, et un ramassage sur 256 bits, que ce cœur n'a pas.
    func testWhatIsNotSSEIsRefused() throws {
        for bytes: [UInt8] in [
            [0xC5, 0xF1, 0x6F, 0xC1],        // vmovdqa avec vvvv = xmm1
            [0xC5, 0xE8, 0xFE, 0xC1],        // vpaddd sans 66
            [0xC4, 0xE2, 0x75, 0x90, 0x04, 0x96],  // vpgatherdd : un ramassage
        ] {
            let memory = X86Memory(size: 0x1000, base: 0x3000_0000)
            try memory.load(bytes, at: 0x3000_0000)
            var core = X86Core(registers: X86SIMDOracleTests.witness(), flags: X86Core.Flag.reserved,
                               rip: 0x3000_0000, memory: memory)
            XCTAssertThrowsError(try core.execute(try X86Decoder.decode(memory.dump(0x3000_0000, 15))), "\(bytes)")
        }
    }

    /// **`VZEROALL` efface les seize registres**, `VZEROUPPER` n'en touche
    /// aucun tant que le haut des YMM n'existe pas.
    func testZeroingTheVectorRegisters() throws {
        let base: UInt64 = 0x3000_0000
        let memory = X86Memory(size: 0x1000, base: base)
        try memory.load([0xC5, 0xF8, 0x77, 0xC5, 0xFC, 0x77], at: base)
        var core = X86Core(registers: X86SIMDOracleTests.witness(), flags: X86Core.Flag.reserved, rip: base, memory: memory)
        core.vectors = X86SIMDOracleTests.witnessVectors()
        try core.execute(X86Decoder.decode(memory.dump(core.rip, 15)))
        XCTAssertEqual(core.vectors, X86SIMDOracleTests.witnessVectors())
        try core.execute(X86Decoder.decode(memory.dump(core.rip, 15)))
        XCTAssertEqual(core.vectors, [UInt64](repeating: 0, count: 32))
    }
}
