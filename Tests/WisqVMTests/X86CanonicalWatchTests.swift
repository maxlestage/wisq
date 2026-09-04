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
/// Le noyau n'imprime que la fin de l'histoire. Ce témoin remonte à
/// l'instruction qui a **fabriqué** la valeur.
///
/// **La première version signalait tout registre qui acquérait une valeur non
/// canonique, et la mesure l'a démolie en un essai** : sur un vrai démarrage
/// elle a rempli son rapport avec le filtre de Bloom du chargeur dynamique —
/// des `1 << 61` et des mots de hachage, qui sont des masques de bits et non
/// des adresses. Rien, dans un registre, ne dit lequel des deux il est ; seul
/// l'**usage** le dit. `testTheBitmasksOfALoaderAreNotReported` tient cette
/// leçon.
final class X86CanonicalWatchTests: XCTestCase {
    static let program: UInt64 = 0x1000
    static let pml4: UInt64 = 0x5000
    static let pdpt: UInt64 = 0x6000
    /// La valeur exacte qu'avait RDI à la mort de `/init`.
    static let corrupt: UInt64 = 0x0003_7CDE_165F_7280

    /// Un cœur en anneau trois, avec une pagination d'identité sur le premier
    /// gibioctet : sans pagination, `translate` rend l'adresse telle quelle et
    /// il n'y a pas de moment où une valeur devient une adresse.
    static func core(_ instructions: [UInt8], ring: UInt16 = 3) throws -> X86Core {
        let memory = X86Memory(size: 0x10000, base: 0)
        try memory.load(instructions, at: program)
        try memory.write(pml4, 8, pdpt | X86Core.present | X86Core.writable
            | X86Core.userAccessible)
        try memory.write(pdpt, 8, X86Core.present | X86Core.hugePage | X86Core.writable
            | X86Core.userAccessible)
        var core = X86Core(registers: [UInt64](repeating: 0, count: 16),
                           rip: program, memory: memory)
        core.system.control[3] = pml4
        core.pagingActive = true
        core.segments[1] = ring == 3 ? 0x33 : 0x10
        core.canonicalWatchArmed = true
        return core
    }

    /// `movabs $0x00037cde165f7280, %rax` — la valeur fautive, posée d'un coup.
    static let makeCorrupt: [UInt8] = [0x48, 0xB8, 0x80, 0x72, 0x5F, 0x16, 0xDE, 0x7C, 0x03, 0x00]
    /// `movabs $0x2000, %rax` — une adresse cartographiée, elle.
    static let makeReal: [UInt8] = [0x48, 0xB8, 0x00, 0x20, 0, 0, 0, 0, 0, 0]
    /// `mov (%rax), %rax` — le moment où la valeur devient une adresse.
    static let dereference: [UInt8] = [0x48, 0x8B, 0x00]

    /// Faire tourner jusqu'à ce que ça s'arrête ; une faute de page sans IDT
    /// sort d'ici, et c'est ce qu'on attend du cas fautif.
    static func run(_ core: inout X86Core, _ budget: UInt64) {
        _ = try? core.run(budget: budget)
    }

    func testTheTwoHalvesOfTheAddressSpaceAreCanonicalAndTheHoleIsNot() {
        XCTAssertTrue(X86Core.isCanonical(0), "la première adresse d'un programme")
        XCTAssertTrue(X86Core.isCanonical(0x0000_7F89_E851_18A0), "un pointeur de bibliothèque")
        XCTAssertTrue(X86Core.isCanonical(0x0000_7FFF_FFFF_FFFF), "le dernier octet du bas")
        XCTAssertTrue(X86Core.isCanonical(0xFFFF_8000_0000_0000), "le premier du noyau")
        XCTAssertTrue(X86Core.isCanonical(0xFFFF_FFFF_8100_0000), "où Linux se pose")
        XCTAssertTrue(X86Core.isCanonical(UInt64.max))
        XCTAssertFalse(X86Core.isCanonical(0x0000_8000_0000_0000), "le premier du trou")
        XCTAssertFalse(X86Core.isCanonical(0xFFFF_7FFF_FFFF_FFFF), "le dernier du trou")
        XCTAssertFalse(X86Core.isCanonical(Self.corrupt), "ce qui a tué /init")
    }

    func testTheWatchNamesWhereTheAddressWasBorn() throws {
        var core = try Self.core(Self.makeCorrupt + Self.dereference)
        Self.run(&core, 2)
        XCTAssertEqual(core.nonCanonicalSeen.count, 1)
        let seen = try XCTUnwrap(core.nonCanonicalSeen.first)
        XCTAssertEqual(seen.address, Self.corrupt, "l'adresse employée")
        XCTAssertEqual(seen.rip, Self.program &+ UInt64(Self.makeCorrupt.count),
                       "l'instruction qui s'en sert, pas celle qui l'a faite")
        let carried = try XCTUnwrap(seen.carrying.first)
        XCTAssertEqual(seen.carrying.count, 1, "un seul registre la porte")
        XCTAssertEqual(carried.register, 0, "rax")
        XCTAssertEqual(carried.value, Self.corrupt)
        XCTAssertEqual(carried.bornAt, Self.program,
                       "et c'est le movabs qui l'y a mise")
        XCTAssertEqual(Array(carried.bornBytes.prefix(Self.makeCorrupt.count)),
                       Self.makeCorrupt,
                       "avec ses octets, pour qu'on la désassemble sans deviner")
        XCTAssertEqual(seen.cameFrom, Self.program,
                       "la dernière instruction qui a abouti")
        XCTAssertEqual(Array(seen.cameFromBytes.prefix(Self.makeCorrupt.count)),
                       Self.makeCorrupt)
    }

    /// Quand l'adresse fautive **est** RIP, c'est un saut parti dans le décor,
    /// et ce qu'on veut savoir est quelle instruction a sauté. C'est la forme
    /// qu'a prise cinq fois le vrai démarrage avant la mort de `/init`.
    func testAJumpIntoTheHoleNamesTheInstructionThatJumped() throws {
        // movabs $corrompu, %rax ; jmp *%rax
        let jump: [UInt8] = [0xFF, 0xE0]
        var core = try Self.core(Self.makeCorrupt + jump)
        Self.run(&core, 3)
        let seen = try XCTUnwrap(core.nonCanonicalSeen.first)
        XCTAssertEqual(seen.address, Self.corrupt)
        XCTAssertEqual(seen.rip, Self.corrupt,
                       "l'adresse employée est RIP lui-même : c'est une lecture d'instruction")
        XCTAssertEqual(seen.cameFrom, Self.program &+ UInt64(Self.makeCorrupt.count),
                       "et c'est le saut indirect qui y a mené")
        XCTAssertEqual(Array(seen.cameFromBytes.prefix(2)), jump)
    }

    func testMakingTheValueIsNotEnoughToFire() throws {
        var core = try Self.core(Self.makeCorrupt)
        Self.run(&core, 1)
        XCTAssertEqual(core.registers[0], Self.corrupt, "la valeur est bien là")
        XCTAssertTrue(core.nonCanonicalSeen.isEmpty,
                      "tant qu'on ne s'en sert pas, ce n'est pas une adresse")
    }

    func testARealAddressDoesNotFire() throws {
        var core = try Self.core(Self.makeReal + Self.dereference)
        Self.run(&core, 2)
        XCTAssertTrue(core.nonCanonicalSeen.isEmpty)
    }

    /// **La leçon de la première version.** Un chargeur dynamique fabrique des
    /// masques de soixante-quatre bits — `1 << 61` pour son filtre de Bloom —
    /// et les promène de registre en registre. Aucun n'est une adresse, et
    /// aucun ne doit être signalé.
    func testTheBitmasksOfALoaderAreNotReported() throws {
        // mov $61, %cl ; mov $1, %r12 ; shl %cl, %r12 ; mov %r12, %r9
        let bloom: [UInt8] = [0xB1, 0x3D]
            + [0x49, 0xC7, 0xC4, 0x01, 0x00, 0x00, 0x00]
            + [0x49, 0xD3, 0xE4]
            + [0x4D, 0x89, 0xE1]
        var core = try Self.core(bloom + Self.makeReal + Self.dereference)
        Self.run(&core, 6)
        XCTAssertEqual(core.registers[12], 1 << 61, "le masque est bien fabriqué")
        XCTAssertFalse(X86Core.isCanonical(core.registers[12]),
                       "et il n'est pas canonique — c'est tout le piège")
        XCTAssertTrue(core.nonCanonicalSeen.isEmpty,
                      "un masque de bits n'est pas une adresse")
    }

    func testTheKernelIsNotWatched() throws {
        var core = try Self.core(Self.makeCorrupt + Self.dereference, ring: 0)
        Self.run(&core, 2)
        XCTAssertTrue(core.nonCanonicalSeen.isEmpty,
                      "le noyau met légitimement des masques dans ses registres")
    }

    func testTheWatchIsOffUnlessItIsArmed() throws {
        var core = try Self.core(Self.makeCorrupt + Self.dereference)
        core.canonicalWatchArmed = false
        Self.run(&core, 2)
        XCTAssertTrue(core.nonCanonicalSeen.isEmpty)
    }

    func testTheReportStopsAtItsLimit() throws {
        var core = try Self.core(Self.makeCorrupt)
        Self.run(&core, 1)
        for _ in 0...(X86Core.nonCanonicalLimit + 3) {
            core.noteNonCanonical(address: Self.corrupt)
        }
        XCTAssertEqual(core.nonCanonicalSeen.count, X86Core.nonCanonicalLimit)
    }
}
