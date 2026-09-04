import XCTest

@testable import WisqVM

/// Une instruction qui faute à mi-chemin doit pouvoir être **rejouée**.
///
/// **Ce que la mesure a montré.** nlplug-findfs s'endormait pour toujours
/// sur `futex(verrou, WAIT, -1)` : le mot de son verrou valait 0xFFFFFFFF,
/// impossible par construction. Le témoin d'adresse a donné l'histoire du
/// mot, cycle après cycle : `__unlock` fait `lock xadd %eax,(%rdi)` avec
/// EAX = 0x7FFFFFFF, et le mot passait de 0x9FFFFFFF à 0x3FFFFFFE, de
/// 0xBFFFFFFF à 0x7FFFFFFE, de 0xFFFFFFFF à 0xFFFFFFFE — **v + v**, jamais
/// v + 0x7FFFFFFF.
///
/// La cause n'est pas l'addition : c'est l'ordre. `XADD` écrivait le
/// registre source (EAX ← ancienne valeur) **avant** d'écrire la mémoire ;
/// or la page venait d'être partagée par `fork()` et n'était plus
/// inscriptible, donc l'écriture fautait, le noyau copiait la page, et
/// l'instruction repartait — avec EAX qui portait déjà l'ancienne valeur.
/// La reprise additionnait la destination à elle-même.
///
/// La règle, pour toute instruction qui écrit un registre **et** la
/// mémoire : la mémoire d'abord, parce que c'est elle qui peut fauter, et le
/// registre ensuite. Ces tests font fauter l'écriture sur une page en
/// lecture seule, rendent la page inscriptible, et rejouent — comme le
/// noyau le fait à chaque copie-sur-écriture.
final class X86ReplayableInstructionTests: XCTestCase {
    static let pml4: UInt64 = 0x2000
    static let code: UInt64 = 0x1000
    static let data: UInt64 = 0x6000
    static let stack: UInt64 = 0x7000

    /// Quatre niveaux, trois pages : le code et la pile ouvertes, la donnée
    /// **en lecture seule** — comme une page privée juste après un `fork()`.
    static func core(_ bytes: [UInt8]) throws -> X86Core {
        let ram = X86Memory(size: 0x10000, base: 0)
        try ram.load(bytes, at: code)
        let open = X86Core.present | X86Core.writable | X86Core.userAccessible
        try ram.write(pml4, 8, 0x3000 | open)
        try ram.write(0x3000, 8, 0x4000 | open)
        try ram.write(0x4000, 8, 0x5000 | open)
        for page in [code, stack] { try ram.write(0x5000 + (page >> 12) * 8, 8, page | open) }
        try ram.write(0x5000 + (data >> 12) * 8, 8, data | X86Core.present | X86Core.userAccessible)
        var core = X86Core(registers: [UInt64](repeating: 0, count: 16), rip: code, memory: ram)
        core.system.control[3] = pml4
        core.pagingActive = true
        core.segments[1] = 0x33  // anneau trois : la lecture seule s'applique
        core.registers[3] = data
        core.registers[4] = stack + 0x800
        return core
    }

    /// Le noyau a copié la page : elle est inscriptible maintenant.
    static func makeWritable(_ core: X86Core) throws {
        let ram = try XCTUnwrap(core.memory)
        try ram.write(0x5000 + (data >> 12) * 8, 8,
                      data | X86Core.present | X86Core.writable | X86Core.userAccessible)
    }

    /// Le cas mesuré : `lock xadd %eax,(%rbx)` sur 0xBFFFFFFF avec
    /// EAX = 0x7FFFFFFF doit donner 0x3FFFFFFE — pas 0x7FFFFFFE.
    func testXADDReplayedAfterAWriteFaultAddsTheSourceNotTheDestinationTwice() throws {
        var core = try Self.core([0xB8, 0xFF, 0xFF, 0xFF, 0x7F, 0xF0, 0x0F, 0xC1, 0x03])
        try core.memory?.write(Self.data, 4, 0xBFFF_FFFF)
        XCTAssertThrowsError(try core.run(budget: 2), "la page est en lecture seule : ça faute")
        XCTAssertEqual(core.rip, Self.code + 5, "RIP reste sur l'instruction fautive")
        try Self.makeWritable(core)
        try core.run(budget: 1)
        XCTAssertEqual(try core.memory?.read(Self.data, 4), 0x3FFF_FFFE)
        XCTAssertEqual(core.registers[0], 0xBFFF_FFFF, "EAX reçoit l'ancienne valeur, une fois")
    }

    /// `xchg %eax,(%rbx)` : la mémoire d'abord, le registre ensuite, et le
    /// rejeu est exact.
    func testXCHGReplayedAfterAWriteFaultSwapsExactlyOnce() throws {
        var core = try Self.core([0xB8, 0x11, 0x00, 0x00, 0x00, 0x87, 0x03])
        try core.memory?.write(Self.data, 4, 0x22)
        XCTAssertThrowsError(try core.run(budget: 2))
        try Self.makeWritable(core)
        try core.run(budget: 1)
        XCTAssertEqual(try core.memory?.read(Self.data, 4), 0x11)
        XCTAssertEqual(core.registers[0], 0x22)
    }

    /// `pop (%rbx)` : la pile ne doit pas avoir bougé quand l'écriture faute,
    /// sinon le rejeu dépile la case suivante.
    func testPOPToMemoryReplayedAfterAWriteFaultPopsExactlyOnce() throws {
        var core = try Self.core([0x8F, 0x03])
        let top = core.registers[4]
        try core.memory?.write(top, 8, 0xCAFE)
        try core.memory?.write(top + 8, 8, 0xBEEF)
        XCTAssertThrowsError(try core.run(budget: 1))
        XCTAssertEqual(core.registers[4], top, "RSP intact après la faute")
        try Self.makeWritable(core)
        try core.run(budget: 1)
        XCTAssertEqual(try core.memory?.read(Self.data, 8), 0xCAFE)
        XCTAssertEqual(core.registers[4], top + 8)
    }

    /// `cmpxchg` réussi : les drapeaux et la mémoire, pas l'accumulateur —
    /// et le rejeu l'écrit une fois.
    func testCMPXCHGReplayedAfterAWriteFaultStoresExactlyOnce() throws {
        // mov $0,%eax ; mov $0x80000001,%edx ; lock cmpxchg %edx,(%rbx)
        var core = try Self.core([0xB8, 0x00, 0x00, 0x00, 0x00, 0xBA, 0x01, 0x00, 0x00, 0x80,
                                  0xF0, 0x0F, 0xB1, 0x13])
        try core.memory?.write(Self.data, 4, 0)
        XCTAssertThrowsError(try core.run(budget: 3))
        XCTAssertEqual(core.registers[0], 0, "l'accumulateur n'a pas bougé")
        try Self.makeWritable(core)
        try core.run(budget: 1)
        XCTAssertEqual(try core.memory?.read(Self.data, 4), 0x8000_0001)
        XCTAssertNotEqual(core.flags & X86Core.Flag.zero, 0)
    }
}
