import XCTest
@testable import WisqVM

/// Le cache des instructions décodées : il sert, et il ne ment jamais.
final class X86DecodeCacheTests: XCTestCase {
    private func machine(_ program: [UInt8]) throws -> X86Core {
        let memory = X86Memory(size: 0x4000, base: 0x1000)
        try memory.load(program, at: 0x1000)
        var registers = [UInt64](repeating: 0, count: 16)
        registers[4] = 0x1000 + 0x4000 - 0x100
        return X86Core(registers: registers, rip: 0x1000, memory: memory)
    }

    /// **Le code qui se réécrit.** Une boucle exécute `incq %rax`, remplace
    /// ses deux derniers octets pour en faire `decq %rax`, et repasse au même
    /// endroit : c'est la nouvelle instruction qui doit tourner, alors que
    /// l'ancienne est dans le cache, à la même adresse. Un cache qui ne
    /// vérifiait pas ses octets rendrait `rax = 2` au lieu de `0`.
    func testCodeThatRewritesItselfRunsItsNewInstruction() throws {
        var core = try machine([
            0x48, 0xFF, 0xC0,  // 1000 : incq %rax  (devient decq %rax)
            0x48, 0x83, 0xF9, 0x01,  // 1003 : cmpq $1, %rcx
            0x74, 0x0F,  // 1007 : je 1018
            0x48, 0xFF, 0xC1,  // 1009 : incq %rcx
            0x66, 0xC7, 0x04, 0x25, 0x01, 0x10, 0x00, 0x00, 0xFF, 0xC8,  // 100c : movw $0xc8ff, 0x1001
            0xEB, 0xE8,  // 1016 : jmp 1000
            0xF4,  // 1018 : hlt
        ])
        _ = try core.run(budget: 100)
        XCTAssertTrue(core.halted)
        XCTAssertEqual(core.registers[0], 0, "decq après incq : la seconde passe a lu le code réécrit")
        XCTAssertEqual(core.registers[1], 1)
    }

    /// Une boucle repasse sur les mêmes instructions : après le premier tour,
    /// elles viennent du cache. Mille tours de trois instructions, et trois
    /// décodages — le reste trouvé.
    func testALoopIsDecodedOnceAndThenFound() throws {
        var core = try machine([
            0x48, 0xFF, 0xC0,  // 1000 : incq %rax
            0x48, 0xFF, 0xC9,  // 1003 : decq %rcx
            0x75, 0xF8,  // 1006 : jne 1000
            0xF4,  // 1008 : hlt
        ])
        core.registers[1] = 1000
        _ = try core.run(budget: 10_000)
        XCTAssertEqual(core.registers[0], 1000)
        XCTAssertGreaterThanOrEqual(core.decodeCache.hits, 2995)
        XCTAssertLessThanOrEqual(core.decodeCache.misses, 4)
    }

    /// Le cache se paie en mémoire, une fois par machine : il doit rester
    /// petit devant la RAM de l'invité, même sur un téléphone.
    func testTheCacheStaysSmallBesideTheGuestsMemory() {
        XCTAssertLessThanOrEqual(X86DecodeCache.footprint, 8 << 20, "huit Mio au plus")
        XCTAssertGreaterThanOrEqual(X86DecodeCache.slots, 1 << 16,
                                    "l'espace utilisateur ne tient pas dans moins")
    }

    /// La case elle-même : une entrée ne sert que pour ses octets, et que si
    /// elle tient dans ce que la lecture s'autorise — la borne de page quand
    /// la pagination est active.
    func testAnEntryServesOnlyItsBytesAndOnlyWithinTheAllowedRoom() throws {
        let memory = X86Memory(size: 0x1000)
        let jump: [UInt8] = [0x0F, 0x8E, 0x10, 0x20, 0x30, 0x40]  // jle rel32, six octets
        try memory.load(jump, at: 0x100)
        let cache = X86DecodeCache()
        let decoded = try X86Decoder.decode(jump)
        XCTAssertNil(cache.lookup(memory.bytes, at: 0x100, size: memory.size, available: 15),
                     "rien encore")
        cache.store(decoded, memory.bytes, at: 0x100, size: memory.size)
        XCTAssertEqual(cache.lookup(memory.bytes, at: 0x100, size: memory.size, available: 15),
                       decoded)
        XCTAssertNil(cache.lookup(memory.bytes, at: 0x100, size: memory.size, available: 4),
                     "six octets ne tiennent pas dans les quatre qui restent de la page")
        // L'octet qui suit l'instruction n'en fait pas partie : le changer ne
        // change rien.
        memory.bytes[0x106] = 0xCC
        XCTAssertEqual(cache.lookup(memory.bytes, at: 0x100, size: memory.size, available: 15),
                       decoded)
        // Le dernier octet du déplacement, si.
        memory.bytes[0x105] = 0x41
        XCTAssertNil(cache.lookup(memory.bytes, at: 0x100, size: memory.size, available: 15))
        // Au bord de la mémoire, pas de lecture de seize octets : on décode.
        cache.store(decoded, memory.bytes, at: 0x1000 - 8, size: memory.size)
        XCTAssertNil(cache.lookup(memory.bytes, at: 0x1000 - 8, size: memory.size, available: 8))
    }
}
