import XCTest

@testable import WisqVM

/// **L'aiguillage choisi au décodage** (`X86Core.Route`) mène les formes
/// chaudes droit à leur gestionnaire, sans passer par les tables. Il ne doit
/// rien changer d'autre que le chemin : ce qu'une instruction fait est ce que
/// la table lui faisait faire.
///
/// Les gestionnaires eux-mêmes sont jugés par les oracles du cœur, qui
/// passent tous par `perform`, donc par l'aiguillage. Ce qui reste à tenir
/// ici, c'est le choix : le bon gestionnaire pour chaque octet, et aucun pour
/// ceux qui ne sont pas à lui.
final class X86RouteTests: XCTestCase {
    typealias Route = X86Core.Route

    /// Les octets aiguillés, et vers quoi. Écrit à la main, et non recopié de
    /// `Route.number` : c'est la table qu'on juge.
    static func expected(_ map: X86Instruction.OpcodeMap, _ opcode: UInt8) -> UInt8 {
        switch (map, opcode) {
        case (.oneByte, 0x00...0x3D) where opcode & 0x07 <= 5: return Route.arithmetic
        case (.oneByte, 0x80), (.oneByte, 0x81), (.oneByte, 0x83): return Route.arithmeticImmediate
        case (.oneByte, 0x84), (.oneByte, 0x85): return Route.test
        case (.oneByte, 0x88), (.oneByte, 0x89): return Route.movStore
        case (.oneByte, 0x8A), (.oneByte, 0x8B): return Route.movLoad
        case (.oneByte, 0x70...0x7F): return Route.jumpShort
        case (.oneByte, 0x8D): return Route.lea
        case (.twoByte, 0x80...0x8F): return Route.jumpNear
        case (.twoByte, 0xB6), (.twoByte, 0xB7): return Route.moveZeroExtend
        default: return 0
        }
    }

    /// **Les 768 octets des trois tables, un par un.** `82` n'est pas
    /// aiguillé — il n'existe pas en mode 64 bits —, ni `06`, `07`, `0E`…
    /// dont les trois bits du bas valent 6 ou 7.
    func testEveryOpcodeTakesTheRouteItShould() {
        for map in [X86Instruction.OpcodeMap.oneByte, .twoByte, .threeByte38] {
            for opcode in 0...255 {
                let byte = UInt8(opcode)
                XCTAssertEqual(Route.number(map, byte), Self.expected(map, byte),
                               "\(map) \(String(byte, radix: 16))")
            }
        }
    }

    /// **Rien de ce qu'un gestionnaire spécialisé réclame n'est aiguillé.**
    /// Ces octets-là — les instructions système, les vectorielles, le
    /// flottant — sont lus par d'autres avant `twoByte`, et l'aiguillage ne
    /// doit pas les leur prendre.
    func testNothingTheSpecialistsClaimIsRouted() {
        for opcode in 0...255 where X86Core.claimedBySpecialists(UInt8(opcode)) {
            XCTAssertEqual(Route.number(.twoByte, UInt8(opcode)), 0, String(opcode, radix: 16))
        }
    }

    /// **Le décodeur pose le numéro**, et ne le pose pas sous un VEX : `C5 F9
    /// 6F` n'est pas un `0F 6F`, et `C4 E2 79 B6`… non plus un `MOVZX`.
    func testTheDecoderSetsTheRouteAndNotUnderVEX() throws {
        XCTAssertEqual(try X86Decoder.decode([0x48, 0x89, 0xC3]).route, Route.movStore)
        XCTAssertEqual(try X86Decoder.decode([0x0F, 0xB6, 0xC1]).route, Route.moveZeroExtend)
        XCTAssertEqual(try X86Decoder.decode([0x0F, 0x84, 0, 0, 0, 0]).route, Route.jumpNear)
        XCTAssertEqual(try X86Decoder.decode([0x90]).route, 0)
        // vmovdqa xmm0, xmm1 : la table `0F`, sous VEX.
        XCTAssertEqual(try X86Decoder.decode([0xC5, 0xF9, 0x6F, 0xC1]).route, 0)
    }

    /// **L'aiguillage et la table rendent la même machine.** Chaque forme
    /// aiguillée est exécutée deux fois, sur deux cœurs identiques : par
    /// `perform`, qui prend l'aiguillage, et par la table elle-même
    /// (`oneByte`, `performTwoByte`). Registres, drapeaux, RIP, saut pris et
    /// mémoire doivent s'accorder — un octet mené au mauvais gestionnaire
    /// s'y verrait.
    func testTheRouteAndTheTableAgree() throws {
        var forms: [[UInt8]] = []
        for opcode in 0x00...0x3D where opcode & 0x07 <= 5 {
            switch opcode & 0x07 {
            case 4: forms.append([UInt8(opcode), 0x5A])
            case 5: forms.append([0x48, UInt8(opcode), 0x5A, 0xA5, 0, 0x80])
            default:
                forms.append([0x48, UInt8(opcode), 0xD8])        // registre à registre
                forms.append([UInt8(opcode), 0x47, 0x10])        // [rdi + 0x10]
            }
        }
        for opcode: UInt8 in [0x80, 0x81, 0x83] {
            for reg: UInt8 in 0...7 {
                let immediate: [UInt8] = opcode == 0x81 ? [0x34, 0x12, 0, 0x80] : [0x9C]
                forms.append([0x48, opcode, 0xC0 | reg << 3 | 3] + immediate)
                forms.append([opcode, 0x47 | reg << 3, 0x08] + immediate)
            }
        }
        for opcode: UInt8 in [0x84, 0x85, 0x88, 0x89, 0x8A, 0x8B] {
            forms.append([opcode, 0xE3])                // octets hauts sans REX
            forms.append([0x48, opcode, 0x47, 0x18])
            forms.append([0x66, opcode, 0x1F])
        }
        forms.append([0x48, 0x8D, 0x44, 0x8F, 0x20])    // lea rax, [rdi + rcx*4 + 0x20]
        for code in 0...15 {
            forms.append([0x70 | UInt8(code), 0x7E])
            forms.append([0x0F, 0x80 | UInt8(code), 0x00, 0x01, 0, 0])
        }
        forms.append([0x48, 0x0F, 0xB6, 0xC7])
        forms.append([0x0F, 0xB7, 0x47, 0x04])
        forms.append([0x66, 0x0F, 0xB6, 0xE3])

        for bytes in forms {
            let instruction = try X86Decoder.decode(bytes)
            XCTAssertNotEqual(instruction.route, 0, "\(bytes) devait être aiguillé")
            for flags: UInt64 in [0x2, 0x8D7, 0x45, 0x881] {
                var routed = Self.core(flags: flags)
                var table = Self.core(flags: flags)
                try routed.perform(instruction)
                switch instruction.map {
                case .oneByte: try table.oneByte(instruction, instruction.opcode)
                default: try table.performTwoByte(instruction, instruction.opcode)
                }
                XCTAssertEqual(routed.registers, table.registers, "\(bytes)")
                XCTAssertEqual(routed.flags, table.flags, "\(bytes) drapeaux \(flags)")
                XCTAssertEqual(routed.rip, table.rip, "\(bytes)")
                XCTAssertEqual(routed.jumped, table.jumped, "\(bytes)")
                XCTAssertEqual(try routed.memory!.read(0x2000, 8), try table.memory!.read(0x2000, 8))
                XCTAssertEqual(try routed.memory!.read(0x2008, 8), try table.memory!.read(0x2008, 8))
                XCTAssertEqual(try routed.memory!.read(0x2010, 8), try table.memory!.read(0x2010, 8))
                XCTAssertEqual(try routed.memory!.read(0x2018, 8), try table.memory!.read(0x2018, 8))
            }
        }
    }

    /// Un cœur sans pagination, RDI sur une zone de données remplie, et des
    /// registres qui ne valent pas zéro — pour que chaque opération ait
    /// quelque chose à changer.
    static func core(flags: UInt64) -> X86Core {
        let memory = X86Memory(size: 0x4000, base: 0)
        var registers = [UInt64](repeating: 0, count: 16)
        for index in 0..<16 { registers[index] = 0x0123_4567_89AB_CDEF &* UInt64(index + 1) }
        registers[7] = 0x2000  // RDI
        registers[1] = 3       // RCX, l'index de `lea`
        var core = X86Core(registers: registers, rip: 0x1000, memory: memory)
        for offset in stride(from: 0, to: 0x40, by: 8) {
            try? memory.write(0x2000 + UInt64(offset), 8, 0xF0E1_D2C3_B4A5_9687 &+ UInt64(offset))
        }
        core.flags = flags
        return core
    }
}
