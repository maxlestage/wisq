import XCTest

@testable import WisqVM

/// Une **donnée** à cheval sur deux pages.
///
/// **Pourquoi ce fichier existe à côté de `X86PageStraddlingFetchTests`.** Ce
/// dernier a corrigé la lecture de l'*instruction* qui traverse une frontière
/// de page. La donnée, elle, prenait toujours le même chemin faux : le cœur
/// traduit l'adresse du **premier octet**, puis demande à la mémoire huit
/// octets contigus **physiquement**. Tant que les deux pages virtuelles
/// vivent sur deux trames voisines — ce qui est le cas de la carte d'identité
/// du démarrage, et de tout le direct map de Linux — personne ne le voit.
///
/// Là où ça se voit, c'est dans l'espace des modules : `vmalloc` y colle des
/// pages virtuelles contiguës sur des trames prises n'importe où. Un mot de
/// huit octets posé à `…FFC` s'y écrit moitié dans la bonne trame, moitié
/// dans la voisine physique — c'est-à-dire dans la mémoire de quelqu'un
/// d'autre.
///
/// Les deux pages sont donc mises exprès sur des trames **non adjacentes**,
/// et **dans le désordre** : c'est la seule disposition où le défaut se voit,
/// et c'est la disposition ordinaire de `vmalloc`.
final class X86PageStraddlingAccessTests: XCTestCase {
    static let pml4: UInt64 = 0x1_0000
    static let pdpt: UInt64 = 0x1_1000
    static let directory: UInt64 = 0x1_2000
    static let table: UInt64 = 0x1_3000
    static let first: UInt64 = 0x20_0000
    static let second: UInt64 = 0x20_1000
    /// La seconde page virtuelle vit sur une trame *avant* la première.
    static let firstFrame: UInt64 = 0x5_0000
    static let secondFrame: UInt64 = 0x4_0000
    /// La trame qui suit physiquement la première : celle que l'ancien chemin
    /// lisait, et qui n'appartient à personne dans cette carte.
    static let neighbour: UInt64 = 0x5_1000

    static func core() throws -> X86Core {
        let memory = X86Memory(size: 0x10_0000, base: 0)
        let open = X86Core.present | X86Core.writable | X86Core.userAccessible
        try memory.write(pml4, 8, pdpt | open)
        try memory.write(pdpt, 8, directory | open)
        try memory.write(directory &+ (first >> 21 & 0x1FF) * 8, 8, table | open)
        try memory.write(table &+ (first >> 12 & 0x1FF) * 8, 8, firstFrame | open)
        try memory.write(table &+ (second >> 12 & 0x1FF) * 8, 8, secondFrame | open)
        var core = X86Core(registers: [UInt64](repeating: 0, count: 16),
                           rip: first, memory: memory)
        core.system.control[3] = pml4
        core.pagingActive = true
        return core
    }

    // MARK: - Ce que le cœur lit

    /// **Le cas nu.** Huit octets à `…FFC` : quatre dans la première page,
    /// quatre dans la seconde. La trame physiquement voisine porte des octets
    /// bien reconnaissables, et ce ne sont pas eux qu'on doit obtenir.
    func testAWordThatStraddlesTakesItsSecondHalfFromTheSecondPage() throws {
        var core = try Self.core()
        let memory = try XCTUnwrap(core.memory)
        try memory.write(Self.firstFrame &+ 0xFFC, 4, 0x1122_3344)
        try memory.write(Self.secondFrame, 4, 0xAABB_CCDD)
        try memory.write(Self.neighbour, 4, 0xDEAD_BEEF)  // le piège

        let value = try core.readMemory(Self.first &+ 0xFFC, 8)
        XCTAssertEqual(value, 0xAABB_CCDD_1122_3344)
    }

    /// La même chose en écriture : la seconde moitié doit atterrir dans la
    /// seconde page, et la trame voisine ne doit pas bouger d'un octet.
    func testAWordThatStraddlesWritesItsSecondHalfToTheSecondPage() throws {
        var core = try Self.core()
        let memory = try XCTUnwrap(core.memory)
        try memory.write(Self.neighbour, 4, 0xDEAD_BEEF)

        try core.writeMemory(Self.first &+ 0xFFC, 8, 0xAABB_CCDD_1122_3344)
        XCTAssertEqual(try memory.read(Self.firstFrame &+ 0xFFC, 4), 0x1122_3344)
        XCTAssertEqual(try memory.read(Self.secondFrame, 4), 0xAABB_CCDD)
        XCTAssertEqual(try memory.read(Self.neighbour, 4), 0xDEAD_BEEF,
                       "la trame voisine n'a rien reçu")
    }

    /// **Les bords.** Un mot qui finit exactement sur la frontière ne la
    /// traverse pas, et celui qui commence dessus non plus : ce sont les deux
    /// endroits où une découpe se trompe d'un cran.
    func testTheAccessThatEndsOnTheBoundaryDoesNotCross() throws {
        var core = try Self.core()
        let memory = try XCTUnwrap(core.memory)
        try memory.write(Self.firstFrame &+ 0xFF8, 8, 0x0102_0304_0506_0708)
        try memory.write(Self.secondFrame, 8, 0x1112_1314_1516_1718)
        XCTAssertEqual(try core.readMemory(Self.first &+ 0xFF8, 8), 0x0102_0304_0506_0708)
        XCTAssertEqual(try core.readMemory(Self.second, 8), 0x1112_1314_1516_1718)
    }

    /// Un octet ne traverse jamais rien, quelle que soit sa place — le chemin
    /// rapide doit rester le chemin rapide.
    func testASingleByteNeverCrosses() throws {
        var core = try Self.core()
        let memory = try XCTUnwrap(core.memory)
        try memory.write(Self.firstFrame &+ 0xFFF, 1, 0x5A)
        XCTAssertEqual(try core.readMemory(Self.first &+ 0xFFF, 1), 0x5A)
    }

    // MARK: - Quand la seconde page manque

    /// **Une faute, pas des octets inventés.** Si la seconde page n'est pas
    /// là, l'accès doit fauter sur *elle* — et le noyau la posera. Rendre la
    /// moitié qu'on a et zéro pour le reste serait mentir en silence.
    func testAStraddlingReadFaultsOnTheSecondPageWhenItIsAbsent() throws {
        var core = try Self.core()
        let memory = try XCTUnwrap(core.memory)
        try memory.write(Self.table &+ (Self.second >> 12 & 0x1FF) * 8, 8, 0)
        XCTAssertThrowsError(try core.readMemory(Self.first &+ 0xFFC, 8)) { error in
            guard case X86Core.Fault.pageFault(let address) = error else {
                return XCTFail("une faute de page, et pas \(error)")
            }
            XCTAssertEqual(address & ~UInt64(0xFFF), Self.second)
        }
    }

    /// **Et une écriture qui va fauter ne doit rien avoir écrit.** Sans ça, la
    /// première moitié serait déjà posée quand le gestionnaire de faute prend
    /// la main, et l'instruction rejouée l'écrirait deux fois — ce qui est
    /// visible dès qu'elle n'est pas idempotente.
    func testAStraddlingWriteThatFaultsLeavesTheFirstPageUntouched() throws {
        var core = try Self.core()
        let memory = try XCTUnwrap(core.memory)
        try memory.write(Self.firstFrame &+ 0xFFC, 4, 0x1234_5678)
        try memory.write(Self.table &+ (Self.second >> 12 & 0x1FF) * 8, 8, 0)
        XCTAssertThrowsError(try core.writeMemory(Self.first &+ 0xFFC, 8, 0))
        XCTAssertEqual(try memory.read(Self.firstFrame &+ 0xFFC, 4), 0x1234_5678,
                       "rien n'a été posé avant la faute")
    }

    /// La seconde page présente mais **en lecture seule** : c'est une faute
    /// d'écriture, sur elle, et la première ne doit pas non plus bouger.
    func testAStraddlingWriteFaultsWhenTheSecondPageIsReadOnly() throws {
        var core = try Self.core()
        let memory = try XCTUnwrap(core.memory)
        core.system.control[0] |= X86Core.writeProtect
        try memory.write(Self.firstFrame &+ 0xFFC, 4, 0x1234_5678)
        try memory.write(Self.table &+ (Self.second >> 12 & 0x1FF) * 8, 8,
                         Self.secondFrame | X86Core.present | X86Core.userAccessible)
        XCTAssertThrowsError(try core.writeMemory(Self.first &+ 0xFFC, 8, 0))
        XCTAssertEqual(try memory.read(Self.firstFrame &+ 0xFFC, 4), 0x1234_5678)
    }

    // MARK: - Par une vraie instruction

    /// **Et tout ça par le chemin ordinaire.** Un `mov (%rax),%rbx` posé sur
    /// la frontière : c'est la forme qu'un `memcpy` du noyau prend, et c'est
    /// elle qui doit rendre les huit bons octets.
    func testARealLoadAcrossTheBoundaryReadsBothPages() throws {
        var core = try Self.core()
        let memory = try XCTUnwrap(core.memory)
        try memory.write(Self.firstFrame &+ 0xFFC, 4, 0x1122_3344)
        try memory.write(Self.secondFrame, 4, 0xAABB_CCDD)
        try memory.write(Self.neighbour, 4, 0xDEAD_BEEF)
        // 48 8b 18 : mov (%rax),%rbx
        try memory.load([0x48, 0x8B, 0x18], at: Self.firstFrame &+ 0x100)
        core.rip = Self.first &+ 0x100
        core.registers[0] = Self.first &+ 0xFFC
        _ = try core.run(budget: 1)
        XCTAssertEqual(core.registers[3], 0xAABB_CCDD_1122_3344)
    }

    /// Et un `mov %rbx,(%rax)` symétrique : ce que le module reçoit doit
    /// arriver dans les deux pages qui le portent.
    func testARealStoreAcrossTheBoundaryWritesBothPages() throws {
        var core = try Self.core()
        let memory = try XCTUnwrap(core.memory)
        try memory.write(Self.neighbour, 4, 0xDEAD_BEEF)
        // 48 89 18 : mov %rbx,(%rax)
        try memory.load([0x48, 0x89, 0x18], at: Self.firstFrame &+ 0x100)
        core.rip = Self.first &+ 0x100
        core.registers[0] = Self.first &+ 0xFFC
        core.registers[3] = 0xAABB_CCDD_1122_3344
        _ = try core.run(budget: 1)
        XCTAssertEqual(try memory.read(Self.firstFrame &+ 0xFFC, 4), 0x1122_3344)
        XCTAssertEqual(try memory.read(Self.secondFrame, 4), 0xAABB_CCDD)
        XCTAssertEqual(try memory.read(Self.neighbour, 4), 0xDEAD_BEEF)
    }

    /// **La pile aussi.** Un `push` dont le mot traverse la frontière est le
    /// cas le plus vicieux : la pile descend, donc c'est la *fin* du mot qui
    /// est dans la page haute, et la faute doit se prendre sur la page basse.
    func testAPushAcrossTheBoundaryLandsInBothPages() throws {
        var core = try Self.core()
        let memory = try XCTUnwrap(core.memory)
        try memory.load([0x53], at: Self.firstFrame &+ 0x100)  // push %rbx
        core.rip = Self.first &+ 0x100
        core.registers[4] = Self.second &+ 4  // RSP : après le push, …FFC
        core.registers[3] = 0xAABB_CCDD_1122_3344
        _ = try core.run(budget: 1)
        XCTAssertEqual(core.registers[4], Self.first &+ 0xFFC)
        XCTAssertEqual(try memory.read(Self.firstFrame &+ 0xFFC, 4), 0x1122_3344)
        XCTAssertEqual(try memory.read(Self.secondFrame, 4), 0xAABB_CCDD)
    }
}
