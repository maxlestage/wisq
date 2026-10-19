import XCTest
@testable import WisqVM

/// La table `0F` : ce qui va droit à la table ordinaire, et ce qui passe par
/// les quatre gestionnaires spécialisés.
final class X86TwoByteDispatchTests: XCTestCase {
    /// **Aucun octet n'est perdu par le raccourci.** Pour chaque octet que
    /// `claimedBySpecialists` laisse à la table ordinaire, avec chaque préfixe
    /// qui change le sens d'une instruction `0F` (aucun, `66`, `F2`, `F3`) et
    /// un opérande registre comme mémoire, aucun des quatre gestionnaires ne
    /// le prend : ni ne rend vrai, ni ne lève. Sans quoi le raccourci
    /// enverrait à la table ordinaire une instruction qu'elle ne sait pas
    /// faire.
    func testWhatGoesStraightToTheOrdinaryTableIsClaimedByNoSpecialist() throws {
        var tried = 0
        for opcode in UInt8.min...UInt8.max where !X86Core.claimedBySpecialists(opcode) {
            for prefix in [nil, 0x66, 0xF2, 0xF3] as [UInt8?] {
                for modrm: UInt8 in [0xC0, 0x00] {
                    let bytes = (prefix.map { [$0] } ?? []) + [0x0F, opcode, modrm] + [UInt8](repeating: 0, count: 8)
                    guard let instruction = try? X86Decoder.decode(bytes) else { continue }
                    let memory = X86Memory(size: 0x4000, base: 0x1000)
                    var registers = [UInt64](repeating: 0x1800, count: 16)
                    registers[4] = 0x3000
                    let fresh = X86Core(registers: registers, rip: 0x1000, memory: memory)
                    let label = String(format: "0F %02X, préfixe %@, ModRM %02X", opcode,
                                       prefix.map { String(format: "%02X", $0) } ?? "aucun", modrm)
                    var core = fresh
                    XCTAssertEqual(try? core.systemInstruction(instruction, opcode), false, "système : \(label)")
                    core = fresh
                    XCTAssertEqual(try? core.vectorInstruction(instruction, opcode), false, "vectoriel : \(label)")
                    core = fresh
                    XCTAssertEqual(try? core.vectorArithmetic(instruction, opcode), false, "arithmétique : \(label)")
                    core = fresh
                    XCTAssertEqual(try? core.floatInstruction(instruction, opcode), false, "flottant : \(label)")
                    tried += 1
                }
            }
        }
        XCTAssertGreaterThan(tried, 1000, "le parcours a bien essayé quelque chose")
    }

    /// Les octets qu'on sait spécialisés le sont, et les plus fréquents des
    /// ordinaires ne le sont pas.
    func testTheMaskNamesTheRightBytes() {
        for opcode: UInt8 in [0x6F, 0x7F, 0xEF, 0x58, 0x2E, 0xA2, 0x30, 0x22, 0xFE, 0xD7, 0x13, 0x17] {
            XCTAssertTrue(X86Core.claimedBySpecialists(opcode), String(format: "0F %02X", opcode))
        }
        for opcode: UInt8 in [0x84, 0x85, 0x94, 0x44, 0xB6, 0xBE, 0xAF, 0x1F, 0xA3, 0xB1, 0xC8] {
            XCTAssertFalse(X86Core.claimedBySpecialists(opcode), String(format: "0F %02X", opcode))
        }
    }
}
