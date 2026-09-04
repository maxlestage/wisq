import XCTest

@testable import WisqVM

/// Les seize registres XMM, contre le **vrai processeur**.
///
/// Même méthode que `X86OracleTests`, et pour la même raison : la référence
/// d'un cœur x86-64 n'est ni un document ni un autre émulateur, c'est la
/// machine. `scripts/build-x86-xmm-oracle.py` fait exécuter chaque forme par
/// le processeur de ce conteneur, avec des états d'entrée choisis, et fige sa
/// réponse dans `Tests/Fixtures/x86-xmm-oracle.tsv`.
///
/// **Le harnais a dû grandir pour ça.** Il ne portait que les seize registres
/// généraux et RFLAGS ; il porte maintenant les seize XMM en plus. La preuve
/// que ça n'a rien changé au reste est que les 10 020 cas arithmétiques
/// existants se régénèrent **à l'octet près**.
///
/// **Ce que ce fichier ne couvre pas**, et ce n'est pas un oubli : aucune
/// arithmétique en virgule flottante. Déplacer des bits et calculer sont deux
/// décisions différentes, et la seconde n'a pas encore été demandée par la
/// machine — le noyau s'arrête sur `MOVD`, pas sur `MULSD`.
final class X86VectorOracleTests: XCTestCase {
    struct State: Equatable {
        var low0: UInt64
        var high0: UInt64
        var low1: UInt64
        var high1: UInt64
        var rax: UInt64
    }

    struct Case {
        let instruction: Int
        let state: Int
        let after: State
        /// La fenêtre de mémoire après coup, ou nil quand elle n'a pas bougé.
        let memory: [UInt8]?
    }

    struct Fixture {
        var states: [Int: (state: State, flags: UInt64)] = [:]
        var instructions: [Int: (bytes: [UInt8], text: String)] = [:]
        var cases: [Case] = []
    }

    static let dataAddress: UInt64 = 0x3000_1000
    static let stackTop: UInt64 = 0x3000_3000
    static let windowSize = 64
    static var pristine: [UInt8] { (0..<windowSize).map { UInt8(0x10 + $0) } }

    /// Le témoin des registres qu'aucun cas ne doit toucher : xmm2 à xmm15
    /// portent une valeur reconnaissable. Le générateur a déjà vérifié que le
    /// processeur ne les change pas ; c'est ici qu'on l'exige du cœur.
    static func witnessVectors() -> [UInt64] {
        var values = [UInt64](repeating: 0, count: 32)
        for index in 0..<16 {
            values[2 * index] = 0xC000_0000_0000_0000 &+ UInt64(index)
            values[2 * index + 1] = 0xD000_0000_0000_0000 &+ UInt64(index)
        }
        return values
    }

    static func witness() -> [UInt64] {
        (0..<16).map { 0xAAAA_AAAA_AAAA_AAAA &+ UInt64($0) }
    }

    /// Les registres généraux qu'aucune forme ne doit toucher. RAX est exclu
    /// parce que `MOVD xmm, r32` y écrit ; RSP et RBP parce que le harnais
    /// leur donne une pile ; RSI parce qu'il porte l'adresse de la fenêtre.
    static let watchedRegisters: [Int] = [1, 2, 3, 8, 9, 10, 11, 12, 13, 14, 15]

    /// Le registre `index` est-il le même dans les deux fichiers de registres ?
    static func same(_ left: [UInt64], _ right: [UInt64], _ index: Int) -> Bool {
        let low = 2 * index
        let high = low + 1
        return left[low] == right[low] && left[high] == right[high]
    }

    static var path: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/x86-xmm-oracle.tsv")
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
            case "état" where field.count >= 8:
                fixture.states[Int(field[1]) ?? -1] = (
                    State(low0: number(2), high0: number(3),
                          low1: number(4), high1: number(5), rax: number(6)),
                    number(7))
            case "instr" where field.count >= 4:
                fixture.instructions[Int(field[1]) ?? -1] = (bytes(field[2]), String(field[3]))
            case "cas" where field.count >= 9:
                fixture.cases.append(Case(
                    instruction: Int(field[1]) ?? -1, state: Int(field[2]) ?? -1,
                    after: State(low0: number(3), high0: number(4),
                                 low1: number(5), high1: number(6), rax: number(7)),
                    memory: field[8] == "-" ? nil : bytes(field[8])))
            default:
                continue
            }
        }
        return fixture
    }

    func testTheCoreMovesTheSameBitsTheProcessorMoves() throws {
        let fixture = try Self.read(Self.path)
        XCTAssertGreaterThan(fixture.cases.count, 500, "l'oracle doit couvrir, pas illustrer")
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
            registers[0] = before.state.rax
            registers[4] = Self.stackTop
            registers[6] = Self.dataAddress
            let memory = X86Memory(size: 0x4000, base: 0x3000_0000)
            try? memory.load(program.bytes, at: 0x3000_0000)
            try? memory.load(Self.pristine, at: Self.dataAddress)
            var core = X86Core(
                registers: registers, flags: before.flags | X86Core.Flag.reserved,
                rip: 0x3000_0000, memory: memory)
            core.vectors = Self.witnessVectors()
            core.setVector(0, before.state.low0, before.state.high0)
            core.setVector(1, before.state.low1, before.state.high1)
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
                low0: core.vectors[0], high0: core.vectors[1],
                low1: core.vectors[2], high1: core.vectors[3],
                rax: core.registers[0])
            let witnessed = Self.witnessVectors()
            var untouchedVectors = true
            for index in 2..<16 where !Self.same(core.vectors, witnessed, index) {
                untouchedVectors = false
            }
            let untouched = Self.watchedRegisters.allSatisfy {
                core.registers[$0] == Self.witness()[$0]
            }
            // Aucune de ces instructions ne touche un drapeau — l'oracle l'a
            // vérifié sur la machine, et c'est exigé ici aussi.
            let flags = core.flags & X86Core.Flag.arithmetic
            let window = memory.dump(Self.dataAddress, Self.windowSize)
            let expected = item.memory ?? Self.pristine
            if after == item.after && untouched && untouchedVectors
                && flags == before.flags & X86Core.Flag.arithmetic && window == expected {
                agreed += 1
                continue
            }
            byInstruction[program.text, default: 0] += 1
            if disagreements.count < 15 {
                var notes: [String] = []
                if !untouchedVectors { notes.append("un autre XMM a bougé") }
                if !untouched { notes.append("un registre général a bougé") }
                if window != expected { notes.append("la mémoire diffère") }
                if flags != before.flags & X86Core.Flag.arithmetic {
                    notes.append("un drapeau a bougé")
                }
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

    private func hex(_ value: UInt64) -> String {
        String(format: "%016llx", value)
    }

    private func describe(_ state: State) -> String {
        let zero = hex(state.high0) + ":" + hex(state.low0)
        let one = hex(state.high1) + ":" + hex(state.low1)
        return "xmm0=" + zero + " xmm1=" + one + " rax=" + hex(state.rax)
    }
}
