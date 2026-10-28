import XCTest

@testable import WisqVM

/// **Les témoins sont lus une fois par course**, en entrant dans `run`, et
/// plus à chaque instruction. C'est sûr parce qu'aucune instruction ne les
/// arme : seul l'appelant les change, entre deux courses.
///
/// Ce qu'il faut tenir, c'est donc l'entre-deux : un témoin armé après une
/// première course doit être vu par la suivante — même quand la page du code
/// est déjà gardée (`fetchTag`) et que rien d'autre ne forcerait la
/// lecture de l'instruction à repasser par `translate`.
final class X86WatchesPerRunTests: XCTestCase {
    typealias Pages = X86PagePermissionTests
    static let open = Pages.present | Pages.writable | Pages.user

    /// **Le témoin d'adresse armé entre deux courses.** La première course
    /// garde la page du code ; la seconde, le témoin posé sur l'instruction
    /// suivante, doit voir sa lecture.
    func testAnAddressWatchArmedBetweenRunsSeesTheNextFetch() throws {
        var core = try Pages.core([0x90, 0x90], subjectFlags: Self.open, ring: 0)
        XCTAssertEqual(try core.run(budget: 1), 1)
        XCTAssertEqual(core.fetchTag, Pages.program &+ 1, "la page du code est gardée")
        core.watchedAddress = Pages.program + 1
        core.watchesKernel = true
        XCTAssertEqual(try core.run(budget: 1), 1)
        let touch = try XCTUnwrap(core.addressTouched.last { $0 != .none },
                                  "la lecture de l'instruction surveillée")
        XCTAssertEqual(touch.offset, 0)
        XCTAssertFalse(touch.writing)
    }

    /// **Et éteint entre deux courses**, la course suivante ne le voit plus.
    func testAnAddressWatchClearedBetweenRunsSeesNothing() throws {
        var core = try Pages.core([0x90, 0x90, 0x90], subjectFlags: Self.open, ring: 0)
        core.watchedAddress = Pages.program + 0x800
        core.watchesKernel = true
        XCTAssertEqual(try core.run(budget: 1), 1)
        core.watchedAddress = nil
        XCTAssertEqual(try core.run(budget: 2), 2)
        XCTAssertTrue(core.addressTouched.allSatisfy { $0 == .none })
    }

    /// **Le témoin des programmes armé entre deux courses.** Un programme
    /// d'anneau trois tourne d'abord sans lui ; armé, la course suivante
    /// passe par `executeWatched`, qui note l'espace d'adressage.
    func testTheProgramWatchArmedBetweenRunsTakesTheNextInstruction() throws {
        var core = try Pages.core([0x90, 0x90], subjectFlags: Self.open, ring: 3)
        XCTAssertEqual(try core.run(budget: 1), 1)
        XCTAssertTrue(core.addressSpacesSeen.isEmpty, "éteint, il ne voit rien")
        core.canonicalWatchArmed = true
        XCTAssertEqual(try core.run(budget: 1), 1)
        XCTAssertEqual(core.addressSpacesSeen, [core.system.control[3]])
    }
}
