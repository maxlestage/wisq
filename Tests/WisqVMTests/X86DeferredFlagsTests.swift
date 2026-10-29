import XCTest

@testable import WisqVM

/// **Les drapeaux de l'arithmétique, calculés à la lecture.**
///
/// `ADD`, `SUB`, `CMP` et les opérations logiques ne posent plus leurs six
/// drapeaux : elles notent de quoi les retrouver, et c'est la lecture de
/// `flags` qui les assemble. `X86FlagsAtOnceTests` tient que le mot rendu est
/// le bon pour une opération ; ce qu'on tient ici, c'est l'**état** qui
/// attend entre deux lectures — ce qu'une seconde opération remplace, ce
/// qu'une écriture efface, et les drapeaux qui ne sont pas les leurs.
final class X86DeferredFlagsTests: XCTestCase {
    typealias Flag = X86Core.Flag

    /// **Une opération remplace celle qui attendait.** Un `add` qui retient,
    /// puis un `and` : la retenue du premier ne survit pas au second.
    func testASecondOperationReplacesTheFirst() {
        var core = X86Core()
        _ = core.add(0xFF, 0x01, 1)
        XCTAssertNotEqual(core.flags & Flag.carry, 0, "0xFF + 1 retient")
        _ = core.logic(0x80, 1)
        XCTAssertEqual(core.flags & (Flag.carry | Flag.zero | Flag.overflow | Flag.auxiliary), 0)
        XCTAssertNotEqual(core.flags & Flag.sign, 0)
    }

    /// **Ce qui avait été écrit avant ne transparaît pas.** Les six drapeaux
    /// posés à la main, puis une opération logique qui les veut presque tous
    /// à zéro : aucun des six d'avant ne reste.
    func testSettledArithmeticBitsDoNotLeakThroughAPendingOperation() {
        var core = X86Core()
        core.flags = Flag.reserved | X86Core.arithmeticFlags
        _ = core.logic(0x01, 1)
        XCTAssertEqual(core.flags, Flag.reserved, "1 : ni zéro, ni signe, parité impaire")
    }

    /// **Les drapeaux qui ne sont pas les leurs restent** : l'interruption,
    /// la direction, posées avant, et ce qu'une opération attend par-dessus.
    func testOtherFlagsSurviveAndCompose() {
        var core = X86Core()
        core.flags = Flag.reserved | Flag.interrupt | Flag.direction
        _ = core.subtract(0, 1, 4)
        XCTAssertEqual(core.flags & (Flag.interrupt | Flag.direction), Flag.interrupt | Flag.direction)
        XCTAssertNotEqual(core.flags & Flag.carry, 0, "0 − 1 emprunte")
        XCTAssertNotEqual(core.flags & Flag.sign, 0)
    }

    /// **Une écriture règle tout.** `set` lit les drapeaux en attente, en
    /// change un, et réécrit le mot : la retenue posée par l'opération est
    /// toujours là, et l'opération n'attend plus.
    func testWritingAFlagKeepsWhatWasPending() {
        var core = X86Core()
        _ = core.add(0xFFFF_FFFF, 1, 4)
        core.set(Flag.interrupt, true)
        XCTAssertEqual(core.pendingSize, 0, "l'écriture a tout réglé")
        XCTAssertNotEqual(core.flags & Flag.carry, 0)
        XCTAssertNotEqual(core.flags & Flag.zero, 0)
        XCTAssertNotEqual(core.flags & Flag.interrupt, 0)
    }

    /// **Le mot écrit l'emporte sur ce qui attendait**, même quand il efface
    /// les six : une opération puis `popf` d'un mot vide.
    func testAWrittenWordWinsOverAPendingOperation() {
        var core = X86Core()
        _ = core.subtract(1, 2, 8)
        core.flags = Flag.reserved
        XCTAssertEqual(core.flags, Flag.reserved)
    }

    /// **La lecture ne change rien** : deux lectures rendent le même mot, et
    /// l'opération attend toujours.
    func testReadingTwiceGivesTheSameWord() {
        var core = X86Core()
        _ = core.add(0x7F, 0x01, 1)
        let first = core.flags
        XCTAssertEqual(core.flags, first)
        XCTAssertNotEqual(first & Flag.overflow, 0, "0x7F + 1 déborde en octet")
        XCTAssertNotEqual(core.pendingSize, 0)
    }
}
