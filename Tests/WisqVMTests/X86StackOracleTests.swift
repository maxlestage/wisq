import XCTest

@testable import WisqVM

/// La pile et les atomiques, contre le **vrai processeur**.
///
/// **Pourquoi ce fichier existe.** Un comptage, et un comptage d'abord mal
/// cadré. Le corpus arithmétique *contient* de la pile : trois de ses seize
/// programmes empilent, appellent, posent un cadre complet. Ce qui manquait
/// n'était pas l'instruction, c'était le **témoin** — ce fichier-là ne rend
/// que RAX, RCX, RDX et les drapeaux. Ni RSP, ni RBP, ni un seul octet de la
/// pile n'y étaient observés : sa fenêtre de mémoire est à 0x30001000 et la
/// pile descend depuis 0x30003000, deux pages plus loin. Un cœur qui décale
/// RSP de huit octets de travers, ou qui écrit son `push` à côté, traversait
/// ces trois programmes sans rien déclencher.
///
/// Or le registre corrompu au moment où `/init` meurt est **RBP** — celui que
/// `pop %rbp` et `leave` restaurent en sortant d'une fonction.
///
/// Le second trou était net : sur les 389 formes du corpus, dix sont des
/// atomiques, et **les dix ont un registre pour destination**. Aucune n'a le
/// préfixe `lock`, aucune n'écrit en mémoire. Le chargeur de la bibliothèque C
/// de l'invité en compte cent vingt-trois, toutes sur de la mémoire.
///
/// **Ce corpus rend les seize registres**, et non trois : quand on cherche
/// quel registre se fait corrompre, on ne peut pas décider d'avance lequel
/// regarder.
final class X86StackOracleTests: XCTestCase {
    struct Case {
        let instruction: Int
        let state: Int
        let registers: [UInt64]
        let flags: UInt64
        /// Les deux fenêtres après coup, ou nil quand elles n'ont pas bougé.
        let data: [UInt8]?
        let stack: [UInt8]?
    }

    struct Fixture {
        var states: [Int: (registers: [UInt64], flags: UInt64)] = [:]
        var instructions: [Int: (bytes: [UInt8], mask: UInt64, text: String)] = [:]
        var cases: [Case] = []
    }

    static let base: UInt64 = 0x3000_0000
    static let dataAddress: UInt64 = 0x3000_1000
    static let stackTop: UInt64 = 0x3000_3000
    static let windowSize = 64
    /// La fenêtre de pile déborde de part et d'autre du sommet : en dessous ce
    /// qu'un `push` écrit, au-dessus ce qu'un `pop` relit.
    static let stackWindow = 128
    static var stackAddress: UInt64 { stackTop &- UInt64(windowSize) }

    static var pristineData: [UInt8] { (0..<windowSize).map { UInt8(0x10 + $0) } }
    static var pristineStack: [UInt8] {
        (0..<windowSize).map { UInt8((0xB0 + $0) & 0xFF) }
            + (0..<windowSize).map { UInt8(0x40 + $0) }
    }

    static var path: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/x86-stack-oracle.tsv")
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
            func window(_ index: Int) -> [UInt8]? {
                field[index] == "-" ? nil : bytes(field[index])
            }
            switch kind {
            case "état" where field.count >= 19:
                fixture.states[Int(field[1]) ?? -1] =
                    ((2..<18).map(number), number(18))
            case "instr" where field.count >= 5:
                fixture.instructions[Int(field[1]) ?? -1] = (
                    bytes(field[2]), number(3), String(field[4]))
            case "cas" where field.count >= 22:
                fixture.cases.append(Case(
                    instruction: Int(field[1]) ?? -1, state: Int(field[2]) ?? -1,
                    registers: (3..<19).map(number), flags: number(19),
                    data: window(20), stack: window(21)))
            default:
                continue
            }
        }
        return fixture
    }

    /// Le nom du registre, pour que le rapport d'un désaccord se lise.
    static let names = [
        "rax", "rcx", "rdx", "rbx", "rsp", "rbp", "rsi", "rdi",
        "r8", "r9", "r10", "r11", "r12", "r13", "r14", "r15",
    ]

    func testTheCoreMovesTheStackTheProcessorMoves() throws {
        let fixture = try Self.read(Self.path)
        XCTAssertGreaterThan(fixture.cases.count, 500, "l'oracle doit couvrir, pas illustrer")
        XCTAssertGreaterThan(fixture.instructions.count, 70)

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
            var registers = before.registers
            // Le pilote pose lui-même le sommet de pile, pour qu'un cas qui
            // déborde n'écrase pas le harnais ; le corpus ne le porte donc pas
            // en entrée, et ce test le pose de la même façon.
            registers[4] = Self.stackTop
            let memory = X86Memory(size: 0x4000, base: Self.base)
            try? memory.load(program.bytes, at: Self.base)
            try? memory.load(Self.pristineData, at: Self.dataAddress)
            try? memory.load(Self.pristineStack, at: Self.stackAddress)
            var core = X86Core(
                registers: registers, flags: before.flags | X86Core.Flag.reserved,
                rip: Self.base, memory: memory)
            do {
                let instruction = try X86Decoder.decode(memory.dump(Self.base, 15))
                try core.execute(instruction)
            } catch {
                byInstruction[program.text, default: 0] += 1
                if disagreements.count < 15 {
                    disagreements.append("  \(program.text) : refusé — \(error)")
                }
                continue
            }
            var notes: [String] = []
            for index in 0..<16 where core.registers[index] != item.registers[index] {
                notes.append("\(Self.names[index]) attendu \(hex(item.registers[index]))"
                    + ", obtenu \(hex(core.registers[index]))")
            }
            if core.flags & program.mask != item.flags & program.mask {
                notes.append("drapeaux attendus \(hex(item.flags & program.mask))"
                    + ", obtenus \(hex(core.flags & program.mask))")
            }
            if memory.dump(Self.dataAddress, Self.windowSize) != item.data ?? Self.pristineData {
                notes.append("la fenêtre de données diffère")
            }
            if memory.dump(Self.stackAddress, Self.stackWindow) != item.stack ?? Self.pristineStack {
                notes.append("la fenêtre de pile diffère")
            }
            if notes.isEmpty {
                agreed += 1
                continue
            }
            byInstruction[program.text, default: 0] += 1
            if disagreements.count < 15 {
                disagreements.append("  " + program.text + ", état " + String(item.state)
                    + "\n    " + notes.joined(separator: "\n    "))
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

    private func hex(_ value: UInt64) -> String { String(format: "%llx", value) }
}
