import XCTest

@testable import WisqVM

/// Les branchements, contre le **vrai processeur**.
///
/// **Pourquoi ce fichier existe.** Un comptage, et il est sans appel : le
/// chargeur dynamique de l'invité contient **4 659 `jmp`, 4 436 `call`,
/// 1 851 `ret` et près de neuf mille sauts conditionnels**. Sur les quatre
/// corpus déjà figés — arithmétique, vectoriel, chaînes, pile — **aucune
/// forme de branchement**. Les seize programmes du corpus arithmétique en
/// contiennent trois, et par accident : ils étaient là pour prouver autre
/// chose.
///
/// **Le tableau des conditions, lui, est déjà prouvé** : seize `setcc` et
/// seize `cmovcc` sont dans le corpus arithmétique, et le cœur évalue la
/// condition d'un saut par la même fonction. Ce qui n'est prouvé nulle part,
/// c'est **où un branchement atterrit** — le signe du déplacement, le fait
/// qu'il se compte depuis la *fin* de l'instruction et non son début, les
/// deux largeurs, et le retour.
///
/// **Chaque cas est un programme, pas une instruction.** Un saut ne se lit pas
/// dans un registre : il faut lui donner plusieurs endroits où atterrir et
/// faire écrire à chacun une marque. C'est la marque, au bout, qui dit par où
/// l'on est passé.
final class X86BranchOracleTests: XCTestCase {
    struct State: Equatable {
        var rax: UInt64
        var rcx: UInt64
        var rdx: UInt64
        var rsp: UInt64
        var flags: UInt64
    }

    struct Case {
        let program: Int
        let state: Int
        let after: State
    }

    struct Fixture {
        var flags: [Int: UInt64] = [:]
        var programs: [Int: (bytes: [UInt8], name: String)] = [:]
        var cases: [Case] = []
    }

    static let base: UInt64 = 0x3000_0000
    static let dataAddress: UInt64 = 0x3000_1000
    static let stackTop: UInt64 = 0x3000_3000

    static func witness() -> [UInt64] {
        (0..<16).map { 0xAAAA_AAAA_AAAA_AAAA &+ UInt64($0) }
    }

    /// Les registres qu'aucun programme ne doit toucher. RAX, RCX et RDX
    /// portent les marques et les compteurs ; RSP et RBP sont la pile.
    static let watchedRegisters: [Int] = [3, 8, 9, 10, 11, 12, 13, 14, 15]

    static var path: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/x86-branch-oracle.tsv")
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
            case "état" where field.count >= 3:
                fixture.flags[Int(field[1]) ?? -1] = number(2)
            case "instr" where field.count >= 4:
                fixture.programs[Int(field[1]) ?? -1] = (bytes(field[2]), String(field[3]))
            case "cas" where field.count >= 8:
                fixture.cases.append(Case(
                    program: Int(field[1]) ?? -1, state: Int(field[2]) ?? -1,
                    after: State(rax: number(3), rcx: number(4), rdx: number(5),
                                 rsp: number(6), flags: number(7))))
            default:
                continue
            }
        }
        return fixture
    }

    func testTheCoreLandsWhereTheProcessorLands() throws {
        let fixture = try Self.read(Self.path)
        XCTAssertGreaterThan(fixture.cases.count, 500, "l'oracle doit couvrir, pas illustrer")
        XCTAssertGreaterThan(fixture.programs.count, 50)

        var disagreements: [String] = []
        var byProgram: [String: Int] = [:]
        var agreed = 0
        for item in fixture.cases {
            guard let flags = fixture.flags[item.state],
                  let program = fixture.programs[item.program]
            else {
                XCTFail("cas orphelin : programme \(item.program), état \(item.state)")
                continue
            }
            var registers = Self.witness()
            registers[0] = 0
            registers[4] = Self.stackTop
            registers[6] = Self.dataAddress
            let memory = X86Memory(size: 0x4000, base: Self.base)
            try? memory.load(program.bytes, at: Self.base)
            var core = X86Core(registers: registers,
                               flags: flags | X86Core.Flag.reserved,
                               rip: Self.base, memory: memory)
            // Un programme entier, jusqu'à ce qu'on en sorte par le bas. Le
            // budget compte les instructions et borne les boucles : un cœur
            // qui saute mal pourrait tourner sans fin, et un test qui pend
            // n'est pas un test qui échoue.
            var remaining = 512
            var refused: Error?
            let end = Self.base &+ UInt64(program.bytes.count)
            while core.rip >= Self.base && core.rip < end && remaining > 0 {
                do {
                    let available = min(X86Instruction.maximumLength,
                                        Int(end &- core.rip))
                    let instruction = try X86Decoder.decode(
                        memory.dump(core.rip, available))
                    try core.execute(instruction)
                } catch {
                    refused = error
                    break
                }
                remaining -= 1
            }
            if let refused {
                byProgram[program.name, default: 0] += 1
                if disagreements.count < 12 {
                    disagreements.append("  \(program.name) : refusé — \(refused)")
                }
                continue
            }
            let after = State(rax: core.registers[0], rcx: core.registers[1],
                              rdx: core.registers[2], rsp: core.registers[4],
                              flags: core.flags & X86Core.Flag.arithmetic)
            let untouched = Self.watchedRegisters.allSatisfy {
                core.registers[$0] == Self.witness()[$0]
            }
            if after == item.after && untouched && remaining > 0 {
                agreed += 1
                continue
            }
            byProgram[program.name, default: 0] += 1
            if disagreements.count < 12 {
                var notes: [String] = []
                if !untouched { notes.append("un registre témoin a bougé") }
                if remaining == 0 { notes.append("le budget s'est épuisé — boucle sans fin ?") }
                let suffix = notes.isEmpty ? "" : " — " + notes.joined(separator: ", ")
                disagreements.append(
                    "  " + program.name + ", drapeaux " + hex(flags)
                        + "\n    attendu " + describe(item.after)
                        + "\n    obtenu  " + describe(after) + suffix)
            }
        }

        let total = fixture.cases.count
        if !disagreements.isEmpty {
            let summary = byProgram.sorted { $0.value > $1.value }
                .map { "\($0.key) × \($0.value)" }.joined(separator: ", ")
            XCTFail("""
                \(total - agreed) désaccords sur \(total) avec le vrai processeur.
                Par programme : \(summary)
                \(disagreements.joined(separator: "\n"))
                """)
        }
        XCTAssertEqual(agreed, total)
    }

    private func describe(_ state: State) -> String {
        "rax=" + hex(state.rax) + " rcx=" + hex(state.rcx) + " rdx=" + hex(state.rdx)
            + " rsp=" + hex(state.rsp) + " drapeaux=" + hex(state.flags)
    }

    private func hex(_ value: UInt64) -> String { String(format: "%llx", value) }
}
