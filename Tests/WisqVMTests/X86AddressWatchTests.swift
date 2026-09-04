import XCTest

@testable import WisqVM

/// Qui touche une case — et, depuis que la question porte sur une structure,
/// qui touche laquelle de ses cases.
///
/// **Pourquoi ces tests existent.** Le témoin a nommé le coupable du pointeur
/// nul de `nlplug-findfs` sans qu'aucun test ne le tienne : il n'existait que
/// pour une mesure, et une mesure ne se relit pas. Or il vient de gagner une
/// plage, et une plage a des bords — ce sont exactement les endroits où un
/// instrument ment sans le dire.
final class X86AddressWatchTests: XCTestCase {
    static let program: UInt64 = 0x1000
    static let cell: UInt64 = 0x4000

    /// Un cœur en anneau trois, sans pagination : la traduction est
    /// l'identité, et c'est bien elle qu'on veut voir passer.
    static func core() throws -> X86Core {
        let memory = X86Memory(size: 0x10000, base: 0)
        var core = X86Core(registers: [UInt64](repeating: 0, count: 16),
                           rip: program, memory: memory)
        core.segments[1] = 0x33  // anneau trois
        return core
    }

    func testAnUnarmedWatchKeepsNothing() throws {
        var core = try Self.core()
        _ = try core.translate(Self.cell)
        XCTAssertTrue(core.addressTouched.allSatisfy { $0 == .none })
    }

    /// Une lecture rend ce qu'elle obtient : la valeur d'avant *est* la valeur
    /// lue. C'est ce qui a permis de lire l'histoire d'un champ sans avoir à
    /// noter la valeur d'après.
    func testAReadCarriesTheValueItObtains() throws {
        var core = try Self.core()
        try core.memory?.write(Self.cell, 8, 0xDEAD_BEEF)
        core.watchedAddress = Self.cell
        _ = try core.translate(Self.cell)
        let touch = try XCTUnwrap(core.addressTouched.last { $0 != .none })
        XCTAssertFalse(touch.writing)
        XCTAssertEqual(touch.before, 0xDEAD_BEEF)
        XCTAssertEqual(touch.offset, 0)
        XCTAssertEqual(touch.at, Self.program)
    }

    /// Une écriture, elle, porte ce qu'elle **écrase** — pas ce qu'elle pose.
    /// Le dire est la seule façon de ne pas se tromper en lisant le rapport.
    func testAWriteCarriesWhatItOverwrites() throws {
        var core = try Self.core()
        try core.memory?.write(Self.cell, 8, 0x1234)
        core.watchedAddress = Self.cell
        _ = try core.translate(Self.cell, .write)
        let touch = try XCTUnwrap(core.addressTouched.last { $0 != .none })
        XCTAssertTrue(touch.writing)
        XCTAssertEqual(touch.before, 0x1234)
    }

    /// La plage, et le déplacement qui dit **quel champ**. Sans lui, deux
    /// champs voisins d'une même structure rendent des lignes indiscernables.
    func testARangeNamesWhichFieldWasTouched() throws {
        var core = try Self.core()
        try core.memory?.write(Self.cell &+ 8, 8, 0xAAAA)
        core.watchedAddress = Self.cell
        core.watchedLength = 16
        _ = try core.translate(Self.cell &+ 8)
        let touch = try XCTUnwrap(core.addressTouched.last { $0 != .none })
        XCTAssertEqual(touch.offset, 8)
        XCTAssertEqual(touch.before, 0xAAAA)
    }

    /// Les deux bords. Le premier octet est dedans, celui qui suit la
    /// longueur ne l'est pas — c'est l'erreur d'un cran qu'un témoin de plage
    /// commet en silence.
    func testTheRangeIncludesItsFirstByteAndExcludesTheOneAfterIt() throws {
        var core = try Self.core()
        core.watchedAddress = Self.cell
        core.watchedLength = 16
        _ = try core.translate(Self.cell)
        _ = try core.translate(Self.cell &+ 15)
        _ = try core.translate(Self.cell &+ 16)
        _ = try core.translate(Self.cell &- 1)
        let seen = core.addressTouched.filter { $0 != .none }
        XCTAssertEqual(seen.map(\.offset), [0, 15])
    }

    /// Le noyau n'est pas surveillé : c'est le programme qu'on cherche, et
    /// mêler les deux noierait la seule ligne qui compte.
    func testRingZeroIsNotWatched() throws {
        var core = try Self.core()
        core.segments[1] = 0x10
        core.watchedAddress = Self.cell
        _ = try core.translate(Self.cell)
        XCTAssertTrue(core.addressTouched.allSatisfy { $0 == .none })
    }

    /// **Et ce sont les derniers passages qu'on garde.** La première version
    /// gardait les premiers, et ils tombaient dix-neuf millions d'instructions
    /// avant la faute — un rapport plein, et vide de ce qu'on cherchait.
    func testItKeepsTheLastPassagesAndNotTheFirst() throws {
        var core = try Self.core()
        core.watchedAddress = Self.cell
        let many = X86Core.addressTouchLimit + 3
        for index in 0..<many {
            core.rip = UInt64(index)
            _ = try core.translate(Self.cell)
        }
        let seen = core.addressTouched
        XCTAssertEqual(seen.count, X86Core.addressTouchLimit)
        XCTAssertEqual(seen.first?.at, UInt64(many - X86Core.addressTouchLimit))
        XCTAssertEqual(seen.last?.at, UInt64(many - 1))
    }

    /// Le témoin s'éteint pendant qu'il lit : sans ça, relire la case
    /// repasserait par la traduction, donc par lui, sans fin.
    func testTheWatchDoesNotRecordItsOwnReading() throws {
        var core = try Self.core()
        core.watchedAddress = Self.cell
        _ = try core.translate(Self.cell)
        XCTAssertEqual(core.addressTouched.filter { $0 != .none }.count, 1)
        XCTAssertEqual(core.watchedAddress, Self.cell, "et il se rallume après")
    }
}
