import XCTest

@testable import WisqVM

/// **Les formes VEX.256 qui calculent par moitiés**, contre le vrai processeur.
///
/// `scripts/build-x86-avx256-oracle.py` récrit en ymm les formes du corpus
/// VEX.128 qui en ont une de même largeur, plus celles dont l'immédiat a des
/// bits par moitié, les fait exécuter par le processeur de ce conteneur — le
/// harnais rend maintenant le haut des YMM — et fige sa réponse dans
/// `Tests/Fixtures/x86-avx256-oracle.tsv`. ymm3 à ymm15 entiers et les
/// registres généraux qu'aucune forme ne nomme doivent revenir intacts.
final class X86AVX256OracleTests: XCTestCase {
    struct State: Equatable {
        /// ymm0, ymm1, ymm2, quatre mots chacun, du bas vers le haut.
        var words: [UInt64]
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
            .appendingPathComponent("Fixtures/x86-avx256-oracle.tsv")
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
            case "état" where field.count >= 18:
                fixture.states[Int(field[1]) ?? -1] = State(
                    words: (2..<14).map(number),
                    rax: number(14), rcx: number(15), flags: number(16), rdx: number(17))
            case "instr" where field.count >= 4:
                fixture.instructions[Int(field[1]) ?? -1] = (
                    X86SIMDOracleTests.bytes(field[2]), String(field[3]))
            case "cas" where field.count >= 20:
                fixture.cases.append(Case(
                    instruction: Int(field[1]) ?? -1, state: Int(field[2]) ?? -1,
                    after: State(words: (3..<15).map(number),
                                 rax: number(15), rcx: number(16), flags: number(17), rdx: number(19)),
                    memory: field[18] == "-" ? nil : X86SIMDOracleTests.bytes(field[18])))
            default:
                continue
            }
        }
        return fixture
    }

    func testTheCoreComputesWhatTheProcessorComputes() throws {
        try Self.judge(Self.path, cases: 25000, instructions: 650)
    }

    /// Le juge, pour ce corpus et pour celui de ce qui traverse les moitiés
    /// (`X86AVX2OracleTests`), qui a les mêmes colonnes.
    static func judge(_ path: String, cases: Int, instructions: Int) throws {
        let fixture = try Self.read(path)
        XCTAssertGreaterThan(fixture.cases.count, cases, "l'oracle doit couvrir, pas illustrer")
        XCTAssertGreaterThan(fixture.instructions.count, instructions)

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
            core.upperVectors = witnessUppers
            for register in 0..<3 {
                let word = before.words[4 * register..<4 * register + 4].map { $0 }
                core.setVector(register, word[0], word[1])
                core.upperVectors[2 * register] = word[2]
                core.upperVectors[2 * register + 1] = word[3]
            }
            do {
                let instruction = try X86Decoder.decode(memory.dump(0x3000_0000, 15))
                try core.execute(instruction)
            } catch {
                byInstruction[program.text, default: 0] += 1
                if disagreements.count < 15 { disagreements.append("  \(program.text) : refusé — \(error)") }
                continue
            }
            var words: [UInt64] = []
            for register in 0..<3 {
                words += [core.vectors[2 * register], core.vectors[2 * register + 1]]
                words += [core.upperVectors[2 * register], core.upperVectors[2 * register + 1]]
            }
            let after = State(
                words: words,
                rax: core.registers[0], rcx: core.registers[1],
                flags: core.flags & X86Core.Flag.arithmetic, rdx: core.registers[2])
            let untouchedVectors = (3..<16).allSatisfy {
                X86SIMDOracleTests.same(core.vectors, witnessVectors, $0)
                    && X86SIMDOracleTests.same(core.upperVectors, Self.witnessUppers, $0)
            }
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
                if !untouchedVectors { notes.append("un autre YMM a bougé") }
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

    static func core(_ program: [UInt8], memorySize: Int = 0x4000) throws -> X86Core {
        let memory = X86Memory(size: memorySize, base: 0x3000_0000)
        try memory.load(program, at: 0x3000_0000)
        var core = X86Core(registers: X86SIMDOracleTests.witness(), flags: X86Core.Flag.reserved,
                           rip: 0x3000_0000, memory: memory)
        core.vectors = X86SIMDOracleTests.witnessVectors()
        core.upperVectors = witnessUppers
        return core
    }

    static func setYMM(_ core: inout X86Core, _ index: Int, _ words: [UInt64]) {
        core.setVector(index, words[0], words[1])
        core.upperVectors[2 * index] = words[2]
        core.upperVectors[2 * index + 1] = words[3]
    }

    static func ymm(_ core: X86Core, _ index: Int) -> [UInt64] {
        [core.vectors[2 * index], core.vectors[2 * index + 1],
         core.upperVectors[2 * index], core.upperVectors[2 * index + 1]]
    }

    /// **De ymm8 à ymm15**, que l'oracle ne nomme pas — et le compte qui est
    /// aussi la destination (`vpsrld %xmm12, %ymm9, %ymm12`) : la moitié haute
    /// le fait passer par un registre bas, et le bit B de VEX doit suivre.
    func testTheHighRegistersAreSplitInHalves() throws {
        var core = try Self.core([
            0xC4, 0x41, 0x35, 0xFE, 0xD3,  // vpaddd %ymm11, %ymm9, %ymm10
            0xC4, 0x41, 0x35, 0xD2, 0xE4,  // vpsrld %xmm12, %ymm9, %ymm12
        ])
        Self.setYMM(&core, 9, [1, 2, 0x10_0000_0010, 0x20_0000_0020])
        Self.setYMM(&core, 11, [0x100, 0x200, 0x0000_0001_0000_0001, 3])
        Self.setYMM(&core, 12, [4, 0, 0xDEAD, 0xBEEF])
        try core.execute(X86Decoder.decode(core.memory!.dump(core.rip, 15)))
        XCTAssertEqual(Self.ymm(core, 10), [0x101, 0x202, 0x11_0000_0011, 0x20_0000_0023])
        try core.execute(X86Decoder.decode(core.memory!.dump(core.rip, 15)))
        XCTAssertEqual(Self.ymm(core, 12), [0, 0, 0x1_0000_0001, 0x2_0000_0002],
                       "les deux moitiés décalées de quatre — le compte d'avant")
        for index in 0..<8 {
            XCTAssertTrue(X86SIMDOracleTests.same(core.vectors, X86SIMDOracleTests.witnessVectors(), index),
                          "xmm\(index), registre de passage, rendu")
        }
    }

    /// **Une faute sur la moitié haute laisse tout comme avant** : trente-deux
    /// octets lus à seize octets de la fin de la mémoire — la moitié basse
    /// passe, la haute manque.
    func testAFaultOnTheUpperHalfLeavesEverythingAlone() throws {
        var core = try Self.core([0xC5, 0xFE, 0x6F, 0x06], memorySize: 0x1000)  // vmovdqu (%rsi), %ymm0
        core.registers[6] = 0x3000_0000 + 0x1000 - 16
        let vectors = core.vectors
        let uppers = core.upperVectors
        XCTAssertThrowsError(try core.execute(X86Decoder.decode(core.memory!.dump(core.rip, 15))))
        XCTAssertEqual(core.vectors, vectors, "le bas de ymm0 rendu")
        XCTAssertEqual(core.upperVectors, uppers)
    }

    /// **Ce que ni les moitiés ni `X86AVX2.swift` ne tiennent reste refusé**,
    /// et par son nom : `vaesenc` sur 256 bits, qui est VAES, que ce cœur
    /// n'annonce pas, et un ramassage.
    func testWhatCrossesTheHalvesIsRefused() throws {
        for bytes: [UInt8] in [
            [0xC4, 0xE2, 0x75, 0x90, 0x04, 0x96], [0xC4, 0xE2, 0x6D, 0xDC, 0xC1],
        ] {
            var core = try Self.core(bytes)
            XCTAssertThrowsError(try core.execute(X86Decoder.decode(core.memory!.dump(core.rip, 15))), "\(bytes)")
            XCTAssertEqual(core.vectors, X86SIMDOracleTests.witnessVectors(), "\(bytes) : rien n'a bougé")
        }
    }

    /// Le haut des YMM qu'aucun cas ne doit toucher : le même témoin que le
    /// générateur.
    static let witnessUppers: [UInt64] = {
        var words: [UInt64] = []
        for index in 0..<16 {
            let step = 2 * UInt64(index)
            words.append(0xE000_0000_0000_0000 + step)
            words.append(0xF000_0000_0000_0000 + step)
        }
        return words
    }()
}
