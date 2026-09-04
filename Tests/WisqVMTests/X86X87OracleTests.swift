import XCTest

@testable import WisqVM

/// La pile x87, contre le **vrai processeur**.
///
/// Huitième corpus. 67 formes, 3 618 cas, fabriqués par
/// `scripts/build-x86-x87-oracle.py`. Le harnais a dû apprendre à charger et
/// relire les huit registres de quatre-vingts bits — `FRSTOR` à l'aller,
/// `FNSAVE` au retour — et la preuve que ça n'a rien changé au reste est que
/// les sept corpus d'avant se régénèrent **à l'octet près**.
///
/// **Ce que ce corpus mesure et qu'aucun autre ne pouvait mesurer :**
///
/// - **Une pile, pas des registres.** `ST(0)` est le sommet, pas un registre.
///   Chaque chargement le décrémente, chaque rangement qui dépile
///   l'incrémente, et le mot d'étiquettes suit — indexé par registre
///   **physique**, alors que l'image de sauvegarde range les valeurs dans
///   l'ordre de la **pile**. Les deux conventions cohabitent.
/// - **Quatre-vingts bits, en logiciel.** Swift a `Float80` sur x86 et pas sur
///   l'ARM d'Apple ; s'en servir referait l'erreur que la tranche précédente
///   vient de corriger. Le corpus porte exprès `1 + 2⁻⁶³`, π sur soixante-quatre
///   bits et `2⁶⁴ - 1` : une implémentation qui passerait par le double les
///   manquerait toutes.
/// - **`DC` et `DE` renversent la soustraction et la division** par rapport à
///   `D8`. Le champ 4 est `FSUB` sur l'un et `FSUBR` sur l'autre. Ce n'est pas
///   une symétrie mais une irrégularité, et la manquer donne le bon calcul à
///   l'envers.
final class X86X87OracleTests: XCTestCase {
    struct Case {
        let instruction: Int
        let state: Int
        let top: Int
        let status: UInt16
        let tags: UInt16
        let registers: [String]
        let rax: UInt64
        let flags: UInt64
        let memory: [UInt8]?
    }

    struct Fixture {
        var states: [Int: (zero: X86Extended, one: X86Extended)] = [:]
        var instructions: [Int: (bytes: [UInt8], text: String)] = [:]
        var cases: [Case] = []
    }

    static let dataAddress: UInt64 = 0x3000_1000
    static let stackTop: UInt64 = 0x3000_3000
    static let windowSize = 64
    static let top = 6
    static let control: UInt16 = 0x037F
    static var pristine: [UInt8] { (0..<windowSize).map { UInt8(0x10 + $0) } }

    static func witness() -> [UInt64] {
        (0..<16).map { 0xAAAA_AAAA_AAAA_AAAA &+ UInt64($0) }
    }

    static let watchedRegisters: [Int] = [1, 2, 3, 8, 9, 10, 11, 12, 13, 14, 15]

    static var path: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/x86-x87-oracle.tsv")
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
            case "état" where field.count >= 6:
                fixture.states[Int(field[1]) ?? -1] = (extended(field[4]), extended(field[5]))
            case "instr" where field.count >= 4:
                fixture.instructions[Int(field[1]) ?? -1] = (bytes(field[2]), String(field[3]))
            case "cas" where field.count >= 16:
                fixture.cases.append(Case(
                    instruction: Int(field[1]) ?? -1, state: Int(field[2]) ?? -1,
                    top: Int(field[3]) ?? 0,
                    status: UInt16(field[4], radix: 16) ?? 0,
                    tags: UInt16(field[5], radix: 16) ?? 0,
                    registers: (6..<14).map { String(field[$0]) },
                    rax: UInt64(field[14], radix: 16) ?? 0,
                    flags: UInt64(field[15], radix: 16) ?? 0,
                    memory: field.count > 16 && field[16] != "-" ? bytes(field[16]) : nil))
            default:
                continue
            }
        }
        return fixture
    }

    func testTheCoreKeepsTheSameStackTheProcessorKeeps() throws {
        let fixture = try Self.read(Self.path)
        XCTAssertGreaterThan(fixture.cases.count, 3000, "l'oracle doit couvrir, pas illustrer")
        XCTAssertGreaterThan(fixture.instructions.count, 60)

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
            registers[4] = Self.stackTop
            registers[6] = Self.dataAddress
            let memory = X86Memory(size: 0x4000, base: 0x3000_0000)
            try? memory.load(program.bytes, at: 0x3000_0000)
            try? memory.load(Self.pristine, at: Self.dataAddress)
            var core = X86Core(registers: registers, flags: 0x002 | X86Core.Flag.reserved,
                               rip: 0x3000_0000, memory: memory)
            core.x87Control = Self.control
            core.x87Status = 0
            core.x87Tags = 0xFFFF
            core.x87TopIndex = Self.top
            core.setStack(0, before.zero)
            core.setStack(1, before.one)

            do {
                let instruction = try X86Decoder.decode(memory.dump(0x3000_0000, 15))
                try core.execute(instruction)
            } catch {
                byInstruction[program.text, default: 0] += 1
                if disagreements.count < 12 {
                    disagreements.append("  \(program.text) : refusé — \(error)")
                }
                continue
            }

            let got = (0..<8).map { core.stack($0).bytes.map {
                String(format: "%02x", $0) }.joined() }
            let window = memory.dump(Self.dataAddress, Self.windowSize)
            let expected = item.memory ?? Self.pristine
            let untouched = Self.watchedRegisters.allSatisfy {
                core.registers[$0] == Self.witness()[$0]
            }
            // **Le mot d'état entier, pas seulement le sommet.** Il porte les
            // drapeaux d'exception — opération invalide, faute de pile — et
            // les trois bits de condition qu'une comparaison écrit. Ne
            // comparer que le sommet laisserait passer une instruction qui
            // calcule juste et rend compte faux.
            if got == item.registers && core.x87Status == item.status
                && core.x87Tags == item.tags && core.registers[0] == item.rax
                && core.flags & X86Core.Flag.arithmetic == item.flags
                && window == expected && untouched {
                agreed += 1
                continue
            }
            byInstruction[program.text, default: 0] += 1
            if disagreements.count < 12 {
                var notes: [String] = []
                if core.x87Status != item.status {
                    notes.append("état \(String(core.x87Status, radix: 16))"
                                 + " au lieu de \(String(item.status, radix: 16))")
                }
                if core.x87Tags != item.tags {
                    notes.append("étiquettes \(String(core.x87Tags, radix: 16))"
                                 + " au lieu de \(String(item.tags, radix: 16))")
                }
                if core.registers[0] != item.rax { notes.append("rax") }
                if core.flags & X86Core.Flag.arithmetic != item.flags {
                    notes.append("drapeaux")
                }
                if window != expected { notes.append("la mémoire diffère") }
                if !untouched { notes.append("un registre général a bougé") }
                let suffix = notes.isEmpty ? "" : " — " + notes.joined(separator: ", ")
                disagreements.append(
                    "  " + program.text + ", état " + String(item.state) + suffix
                        + "\n    attendu " + item.registers[0...2].joined(separator: " ")
                        + "\n    obtenu  " + got[0...2].joined(separator: " "))
            }
        }

        let total = fixture.cases.count
        if !disagreements.isEmpty {
            let summary = byInstruction.sorted { $0.value > $1.value }
                .prefix(12).map { "\($0.key) × \($0.value)" }.joined(separator: ", ")
            XCTFail("""
                \(total - agreed) désaccords sur \(total) avec le vrai processeur.
                Par instruction : \(summary)
                \(disagreements.joined(separator: "\n"))
                """)
        }
        XCTAssertEqual(agreed, total)
    }
}
