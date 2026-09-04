import XCTest

@testable import WisqVM

/// Le témoin des adresses non canoniques.
///
/// **Pourquoi il existe.** Le vrai noyau d'Alpine démarre dans wisq jusqu'à
/// l'espace utilisateur, et `/init` y meurt d'une faute de segment que la même
/// image, sous QEMU, ne produit pas. La valeur fautive a toujours la même
/// forme : quarante-huit bits du bas qui ressemblent à un pointeur ordinaire,
/// et des bits posés au-dessus.
///
///     RDI: 00037cde165f7280   ← ce qui a fait mourir feof
///     RDX: 00007f89e85118a0   ← à quoi ressemble un pointeur de la musl
///
/// Le noyau n'imprime que la fin de l'histoire : le registre est déjà pourri
/// quand l'instruction qui s'en sert faute. Ce témoin remonte à l'instruction
/// qui a **fabriqué** la valeur, ce qu'aucun journal ne peut dire.
final class X86CanonicalWatchTests: XCTestCase {
    static let base: UInt64 = 0x1000
    /// La valeur exacte qu'avait RDI à la mort de `/init`.
    static let corrupt: UInt64 = 0x0003_7CDE_165F_7280
    /// Et celle à laquelle un pointeur de la musl ressemble.
    static let plausible: UInt64 = 0x0000_7F89_E851_18A0

    static func core(_ program: [UInt8], ring: UInt16 = 3) -> X86Core {
        let memory = X86Memory(size: 0x10000, base: 0)
        try? memory.load(program, at: base)
        var core = X86Core(registers: [UInt64](repeating: 0, count: 16),
                           rip: base, memory: memory)
        core.segments[1] = ring == 3 ? 0x33 : 0x10
        core.canonicalWatchArmed = true
        return core
    }

    /// `movabs $0x00037cde165f7280, %rax` — la valeur fautive, posée d'un coup.
    static let makeCorrupt: [UInt8] = [0x48, 0xB8, 0x80, 0x72, 0x5F, 0x16, 0xDE, 0x7C, 0x03, 0x00]
    /// `movabs $0x00007f89e85118a0, %rax` — la même chose, mais licite.
    static let makePlausible: [UInt8] = [0x48, 0xB8, 0xA0, 0x18, 0x51, 0xE8, 0x89, 0x7F, 0, 0]
    /// `nop`
    static let nop: [UInt8] = [0x90]

    func testTheTwoHalvesOfTheAddressSpaceAreCanonicalAndTheHoleIsNot() {
        XCTAssertTrue(X86Core.isCanonical(0), "la première adresse d'un programme")
        XCTAssertTrue(X86Core.isCanonical(Self.plausible), "un pointeur de bibliothèque")
        XCTAssertTrue(X86Core.isCanonical(0x0000_7FFF_FFFF_FFFF), "le dernier octet du bas")
        XCTAssertTrue(X86Core.isCanonical(0xFFFF_8000_0000_0000), "le premier du noyau")
        XCTAssertTrue(X86Core.isCanonical(0xFFFF_FFFF_8100_0000), "où Linux se pose")
        XCTAssertTrue(X86Core.isCanonical(UInt64.max))
        // Et le trou, qui n'est l'adresse de rien.
        XCTAssertFalse(X86Core.isCanonical(0x0000_8000_0000_0000), "le premier du trou")
        XCTAssertFalse(X86Core.isCanonical(0xFFFF_7FFF_FFFF_FFFF), "le dernier du trou")
        XCTAssertFalse(X86Core.isCanonical(Self.corrupt), "ce qui a tué /init")
    }

    func testTheWatchNamesTheInstructionThatMadeTheValue() throws {
        var core = Self.core(Self.makeCorrupt)
        _ = try core.run(budget: 1)
        XCTAssertEqual(core.nonCanonicalSeen.count, 1)
        let seen = try XCTUnwrap(core.nonCanonicalSeen.first)
        XCTAssertEqual(seen.rip, Self.base, "l'adresse de l'instruction, pas celle d'après")
        XCTAssertEqual(seen.bytes, Self.makeCorrupt, "ses octets, pour la désassembler")
        XCTAssertEqual(seen.register, 0, "rax")
        XCTAssertEqual(seen.before, 0)
        XCTAssertEqual(seen.after, Self.corrupt)
        XCTAssertEqual(seen.retired, 1)
    }

    func testAValueThatIsAnAddressIsNotReported() throws {
        var core = Self.core(Self.makePlausible)
        _ = try core.run(budget: 1)
        XCTAssertEqual(core.registers[0], Self.plausible)
        XCTAssertTrue(core.nonCanonicalSeen.isEmpty,
                      "un pointeur licite ne doit pas déclencher le témoin")
    }

    func testARegisterThatMerelyKeepsABadValueIsNotBlamedAgain() throws {
        var core = Self.core(Self.makeCorrupt + Self.nop + Self.nop)
        _ = try core.run(budget: 3)
        XCTAssertEqual(core.registers[0], Self.corrupt, "la valeur est bien restée là")
        XCTAssertEqual(core.nonCanonicalSeen.count, 1,
                       "le témoin nomme l'instruction qui fabrique, pas celles qui suivent")
    }

    func testTheKernelIsNotWatched() throws {
        var core = Self.core(Self.makeCorrupt, ring: 0)
        _ = try core.run(budget: 1)
        XCTAssertEqual(core.registers[0], Self.corrupt)
        XCTAssertTrue(core.nonCanonicalSeen.isEmpty,
                      "le noyau met légitimement des masques dans ses registres")
    }

    func testTheWatchIsOffUnlessItIsArmed() throws {
        var core = Self.core(Self.makeCorrupt)
        core.canonicalWatchArmed = false
        _ = try core.run(budget: 1)
        XCTAssertEqual(core.registers[0], Self.corrupt)
        XCTAssertTrue(core.nonCanonicalSeen.isEmpty)
    }

    /// Le plafond. Une fois la première valeur fabriquée elle se recopie de
    /// registre en registre ; sans borne le rapport ferait des milliers de
    /// lignes qui disent la même chose, et la première serait noyée.
    func testTheReportStopsAtItsLimit() throws {
        // `movabs` puis autant de `xchg %rax, %rcx` qu'il faut pour dépasser :
        // chaque échange fait passer la valeur dans un registre qui ne
        // l'avait pas, donc chacun compte.
        let exchange: [UInt8] = [0x48, 0x91]  // xchg %rcx, %rax
        let count = X86Core.nonCanonicalLimit * 3
        var program = Self.makeCorrupt
        for _ in 0..<count { program += exchange }
        var core = Self.core(program)
        _ = try core.run(budget: UInt64(count + 1))
        XCTAssertEqual(core.nonCanonicalSeen.count, X86Core.nonCanonicalLimit)
        XCTAssertEqual(core.nonCanonicalSeen.first?.register, 0,
                       "et c'est bien la première qui est gardée")
    }
}
