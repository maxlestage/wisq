import XCTest

@testable import WisqVM

/// D'où venait-on quand on a sauté dans le vide ?
///
/// Les quatre morts de `mdev` sont des sauts vers une page absente, et
/// l'adresse d'arrivée n'apprend rien : elle n'existe pas. Ce qui apprend,
/// c'est **l'adresse de départ** — la dernière instruction qui a abouti est,
/// elle, dans du code cartographié, et ses octets la nomment.
///
/// **Et tous ne comptent pas.** Une première version gardait chaque
/// récupération d'instruction sur une page absente ; la mesure en a rendu
/// **neuf cent quatre** en une exécution, presque toutes le cas le plus
/// ordinaire du monde — une page de code chargée à la demande. Le noyau la
/// pose, l'instruction reprend, il ne s'est rien passé. Les seize gardés
/// étaient tous de ceux-là, et les quatre qui tuaient `mdev` étaient parmi
/// les jetés.
final class X86LostJumpWatchTests: XCTestCase {
    static let pml4: UInt64 = 0x2000
    static let pdpt: UInt64 = 0x3000
    static let program: UInt64 = 0x1000

    /// Un cœur paginé dont seul le premier gigaoctet est cartographié : tout
    /// ce qui est au-delà est une page absente, et c'est ce qu'on veut.
    static func core(_ bytes: [UInt8]) throws -> X86Core {
        let memory = X86Memory(size: 0x10000, base: 0)
        try memory.load(bytes, at: program)
        let open = X86Core.present | X86Core.writable | X86Core.userAccessible
        try memory.write(pml4, 8, pdpt | open)
        try memory.write(pdpt, 8, X86Core.present | X86Core.hugePage | open)
        var core = X86Core(registers: [UInt64](repeating: 0, count: 16),
                           rip: program, memory: memory)
        core.system.control[3] = pml4
        core.pagingActive = true
        core.segments[1] = 0x33  // anneau trois
        core.canonicalWatchArmed = true
        return core
    }

    /// Un saut ordinaire ne laisse rien : il y en a des milliards.
    func testAJumpThatLandsSomewhereRealIsNotWorthReporting() throws {
        // `eb 00` : jmp sur l'instruction suivante, puis `90` nop.
        var core = try Self.core([0xEB, 0x00, 0x90])
        _ = try? core.run(budget: 2)
        XCTAssertEqual(core.lostJumpTally, 0)
    }

    /// Et un saut vers une page qu'aucune table ne porte est nommé, **avec
    /// l'endroit d'où il partait**. C'est la seule moitié utile : l'arrivée
    /// n'existe pas, le départ si.
    func testAJumpIntoNothingNamesWhereItCameFrom() throws {
        // `e9 ...` : jmp relatif loin au-delà du gigaoctet cartographié.
        let far = UInt32(0x4000_0000 - Int(Self.program) - 5)
        var core = try Self.core([0xE9] + (0..<4).map {
            UInt8(truncatingIfNeeded: far >> (8 * UInt32($0)))
        })
        _ = try? core.run(budget: 2)
        XCTAssertEqual(core.lostJumpTally, 1)
        // Le noyau de ce test ne résout rien : la main ne revient jamais à
        // l'adresse visée, donc le saut compte.
        core.rip = 0x1234
        core.settleLostJump(0x1234)
        XCTAssertEqual(core.lostJumpsUnresolved, 1)
        let lost = try XCTUnwrap(core.jumpsLost.last)
        XCTAssertEqual(lost.at, 0x4000_0000, "l'adresse qui n'existe pas")
        XCTAssertEqual(lost.from, Self.program, "et celle qui l'a fabriquée")
        XCTAssertEqual(lost.fromBytes.first, 0xE9, "les octets du saut lui-même")
    }

    /// Le noyau n'est pas surveillé : quand il saute dans le décor, c'est un
    /// autre problème, et le mêler à celui du programme noierait les deux.
    func testTheKernelIsNotWatched() throws {
        var core = try Self.core([0xE9, 0xFB, 0xFF, 0xFF, 0x3F])
        core.segments[1] = 0x10
        _ = try? core.run(budget: 2)
        XCTAssertEqual(core.lostJumpTally, 0)
    }

    func testTheWatchIsOffUnlessItIsArmed() throws {
        var core = try Self.core([0xE9, 0xFB, 0xFF, 0xFF, 0x3F])
        core.canonicalWatchArmed = false
        _ = try? core.run(budget: 2)
        XCTAssertEqual(core.lostJumpTally, 0)
    }

    /// **Une lecture manquée n'est pas un saut manqué.** Un programme qui
    /// touche une page absente en *données* est le cas ordinaire — c'est comme
    /// ça qu'une pile grandit. Confondre les deux remplirait le rapport de
    /// bruit et cacherait le seul cas qui compte.
    func testAMissingDataPageIsNotALostJump() throws {
        // `8b 04 25 ...` : mov 0x40000000(%rip-less), %eax — une lecture.
        var core = try Self.core([0x8B, 0x04, 0x25, 0x00, 0x00, 0x00, 0x40])
        _ = try? core.run(budget: 1)
        XCTAssertEqual(core.lostJumpTally, 0, "c'est une lecture, pas un saut")
    }

    /// **Un saut que le noyau résout ne compte pas.** C'est le cas ordinaire
    /// — une page de code chargée à la demande — et il y en a des centaines
    /// par démarrage. Les garder noierait les quatre qui tuent un programme.
    func testAJumpTheKernelResolvesIsForgotten() throws {
        var core = try Self.core([0x90])
        core.previousRip = 0x1000
        core.noteLostJump(0x4000_0000)
        // La main revient **à l'endroit visé** : la page est là, l'instruction
        // reprend, il ne s'est rien passé.
        core.settleLostJump(0x4000_0000)
        XCTAssertEqual(core.lostJumpTally, 1, "on l'a bien vu passer")
        XCTAssertEqual(core.lostJumpsUnresolved, 0, "mais il ne comptait pas")
        XCTAssertTrue(core.jumpsLost.isEmpty)
    }

    /// Et on garde les derniers de ceux qui comptent, avec leur total.
    func testItKeepsTheLastOnesAndSaysHowManyThereWere() throws {
        var core = try Self.core([0x90])
        let many = X86Core.lostJumpLimit + 5
        for index in 0..<many {
            core.previousRip = UInt64(index)
            core.noteLostJump(UInt64(0x9000_0000 + index))
            core.settleLostJump(0)  // ailleurs : le noyau n'a rien résolu
        }
        XCTAssertEqual(core.lostJumpsUnresolved, UInt64(many))
        XCTAssertEqual(core.lostJumps.count, X86Core.lostJumpLimit)
        XCTAssertEqual(core.lostJumpTally, UInt64(many))
        let kept = core.jumpsLost
        XCTAssertEqual(kept.first?.from, UInt64(many - X86Core.lostJumpLimit))
        XCTAssertEqual(kept.last?.from, UInt64(many - 1))
    }
}
