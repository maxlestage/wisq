import XCTest

@testable import WisqVM

/// **BMI1, BMI2, LZCNT, TZCNT et MOVBE**, contre le vrai processeur.
///
/// La part de x86-64-v3 que le noyau de RHEL 10 emploie. Même méthode que les
/// corpus précédents : `scripts/build-x86-v3-gpr-oracle.py` fait exécuter
/// chaque forme par le processeur de ce conteneur, et fige sa réponse dans
/// `Tests/Fixtures/x86-v3-gpr-oracle.tsv`. Les drapeaux sont comparés sous
/// le masque de chaque forme : ceux que le manuel définit, et tous pour les
/// formes qui n'en touchent aucun.
final class X86V3GPROracleTests: XCTestCase {
    struct State: Equatable {
        var rax: UInt64, rcx: UInt64, rdx: UInt64, flags: UInt64
    }

    struct Fixture {
        var states: [Int: State] = [:]
        var instructions: [Int: (bytes: [UInt8], mask: UInt64, text: String)] = [:]
        var cases: [(instruction: Int, state: Int, after: State, memory: [UInt8]?)] = []
    }

    static var path: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/x86-v3-gpr-oracle.tsv")
            .path
    }

    static func read() throws -> Fixture {
        var fixture = Fixture()
        for line in try String(contentsOfFile: path, encoding: .utf8).split(whereSeparator: \.isNewline) {
            let field = line.split(separator: "\t")
            func number(_ index: Int) -> UInt64 { UInt64(field[index], radix: 16) ?? 0 }
            switch field.first {
            case "état" where field.count >= 6:
                fixture.states[Int(field[1]) ?? -1] = State(
                    rax: number(2), rcx: number(3), rdx: number(4), flags: number(5))
            case "instr" where field.count >= 5:
                fixture.instructions[Int(field[1]) ?? -1] = (
                    X86SIMDOracleTests.bytes(field[2]), number(3), String(field[4]))
            case "cas" where field.count >= 8:
                fixture.cases.append((
                    Int(field[1]) ?? -1, Int(field[2]) ?? -1,
                    State(rax: number(3), rcx: number(4), rdx: number(5), flags: number(6)),
                    field[7] == "-" ? nil : X86SIMDOracleTests.bytes(field[7])))
            default:
                continue
            }
        }
        return fixture
    }

    func testTheCoreComputesWhatTheProcessorComputes() throws {
        let fixture = try Self.read()
        XCTAssertGreaterThan(fixture.cases.count, 6000, "l'oracle doit couvrir, pas illustrer")
        XCTAssertGreaterThan(fixture.instructions.count, 100)

        var disagreements: [String] = []
        var byInstruction: [String: Int] = [:]
        var agreed = 0
        let witness = X86SIMDOracleTests.witness()
        for item in fixture.cases {
            guard let before = fixture.states[item.state], let program = fixture.instructions[item.instruction] else {
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
            var core = X86Core(registers: registers, flags: before.flags | X86Core.Flag.reserved,
                               rip: 0x3000_0000, memory: memory)
            do {
                try core.execute(try X86Decoder.decode(memory.dump(0x3000_0000, 15)))
            } catch {
                byInstruction[program.text, default: 0] += 1
                if disagreements.count < 15 { disagreements.append("  \(program.text) : refusé — \(error)") }
                continue
            }
            let after = State(rax: core.registers[0], rcx: core.registers[1], rdx: core.registers[2],
                              flags: core.flags & program.mask)
            let untouched = [3, 5, 7, 8, 9, 10, 11, 12, 13, 14, 15].allSatisfy { core.registers[$0] == witness[$0] }
            let window = memory.dump(X86SIMDOracleTests.dataAddress, X86SIMDOracleTests.windowSize)
            let expected = item.memory ?? X86SIMDOracleTests.pristine
            if after == item.after, untouched, window == expected, core.rip == 0x3000_0000 + UInt64(program.bytes.count) {
                agreed += 1
                continue
            }
            byInstruction[program.text, default: 0] += 1
            if disagreements.count < 15 {
                disagreements.append("  \(program.text), état \(item.state)\n    attendu \(item.after)\n    obtenu  \(after)"
                                     + (untouched ? "" : " — un autre registre a bougé")
                                     + (window == expected ? "" : " — la mémoire diffère"))
            }
        }
        if !disagreements.isEmpty {
            let summary = byInstruction.sorted { $0.value > $1.value }.map { "\($0.key) × \($0.value)" }
                .joined(separator: ", ")
            XCTFail("""
                \(fixture.cases.count - agreed) désaccords sur \(fixture.cases.count) avec le vrai processeur.
                Par instruction : \(summary)
                \(disagreements.joined(separator: "\n"))
                """)
        }
        XCTAssertEqual(agreed, fixture.cases.count)
    }

    /// **Les formes VEX que ce cœur n'exécute pas restent refusées** : AVX
    /// sur 256 bits (`vaddps %ymm2, %ymm1, %ymm0`), et une forme BMI sous
    /// VEX.L, qui n'existe pas.
    func testOtherVEXFormsAreStillRefused() throws {
        for bytes: [UInt8] in [[0xC5, 0xF4, 0x58, 0xC2], [0xC4, 0xE2, 0xEC, 0xF2, 0xC1]] {
            let memory = X86Memory(size: 0x1000, base: 0x3000_0000)
            try memory.load(bytes, at: 0x3000_0000)
            var core = X86Core(registers: X86SIMDOracleTests.witness(), flags: X86Core.Flag.reserved,
                               rip: 0x3000_0000, memory: memory)
            XCTAssertThrowsError(try core.execute(try X86Decoder.decode(memory.dump(0x3000_0000, 15))), "\(bytes)")
        }
    }

    /// **Les registres de r8 à r15**, que l'oracle ne nomme pas : VEX porte
    /// R, X et B inversés, et `vvvv` sur quatre bits. Quatre instructions
    /// de l'assembleur — un registre, une adresse indexée, deux destinations
    /// —, calculées à la main.
    func testTheHighRegistersAreReachedThroughVEX() throws {
        let program: [UInt8] = [
            0xC4, 0x42, 0xA8, 0xF2, 0xD9,              // andn %r9, %r10, %r11
            0xC4, 0x02, 0x99, 0xF7, 0x7C, 0xF5, 0x00,  // shlx %r12, 0(%r13,%r14,8), %r15
            0xC4, 0x42, 0xB3, 0xF6, 0xD0,              // mulx %r8, %r9, %r10
            0xC4, 0xC2, 0x88, 0xF3, 0xCC,              // blsr %r12, %r14
        ]
        let base: UInt64 = 0x3000_0000
        let memory = X86Memory(size: 0x4000, base: base)
        try memory.load(program, at: base)
        try memory.write(base + 0x2000 + 3 * 8, 8, 0x0000_0000_0000_00F1)
        var registers = X86SIMDOracleTests.witness()
        registers[2] = 0x1_0000_0000                   // RDX, le multiplicande de MULX
        registers[8] = 0x3_0000_0000                   // r8
        registers[9] = 0xFF00_FF00_FF00_FF00           // r9
        registers[10] = 0x0F0F_0F0F_0F0F_0F0F          // r10
        registers[12] = 4                              // r12 : le décalage, puis la source de BLSR
        registers[13] = base + 0x2000                  // r13
        registers[14] = 3                              // r14
        var core = X86Core(registers: registers, flags: X86Core.Flag.reserved, rip: base, memory: memory)
        for _ in 0..<4 {
            try core.execute(try X86Decoder.decode(memory.dump(core.rip, 15)))
        }
        XCTAssertEqual(core.registers[11], ~0x0F0F_0F0F_0F0F_0F0F & 0xFF00_FF00_FF00_FF00, "andn → r11")
        XCTAssertEqual(core.registers[15], 0xF10, "shlx → r15, depuis 0(%r13,%r14,8)")
        XCTAssertEqual(core.registers[10], 3, "mulx : le haut → r10")
        XCTAssertEqual(core.registers[9], 0, "mulx : le bas → r9")
        XCTAssertEqual(core.registers[14], 0, "blsr 4 → r14")
    }
}
