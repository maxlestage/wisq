import XCTest
@testable import WisqVM

/// **Les bornes de la mémoire, aux deux bouts et au-delà.** `X86Memory.offset`
/// les vérifie sans piège ni test de `base` à part : une adresse sous `base`
/// et une adresse si haute que l'indice plus la largeur repasserait par zéro
/// doivent rester dehors, et le dernier octet dedans.
final class X86MemoryBoundsTests: XCTestCase {
    private static let base: UInt64 = 0x10_0000
    private static let size = 4096

    private func outside(_ memory: X86Memory, _ address: UInt64, _ width: Int,
                         file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try memory.read(address, width), "lecture", file: file, line: line) { error in
            XCTAssertEqual(error as? X86Core.Fault, .outsideMemory(address), file: file, line: line)
        }
        XCTAssertThrowsError(try memory.write(address, width, 0xFF), "écriture", file: file, line: line)
    }

    /// Le dernier mot qui tient est lu ; un octet plus loin, il sort.
    func testTheLastWordFitsAndOneByteFurtherDoesNot() throws {
        let memory = X86Memory(size: Self.size, base: Self.base)
        let last = Self.base + UInt64(Self.size - 8)
        try memory.write(last, 8, 0x0123_4567_89AB_CDEF)
        XCTAssertEqual(try memory.read(last, 8), 0x0123_4567_89AB_CDEF)
        XCTAssertEqual(try memory.read(Self.base + UInt64(Self.size - 1), 1), 0x01)
        outside(memory, last + 1, 8)
        outside(memory, Self.base + UInt64(Self.size), 1)
    }

    /// **Sous `base`** : la soustraction circulaire en fait un indice immense,
    /// que le premier test écarte — sans lui, rien d'autre ne le ferait.
    func testAnAddressBelowTheBaseIsOutside() {
        let memory = X86Memory(size: Self.size, base: Self.base)
        outside(memory, Self.base - 1, 1)
        outside(memory, Self.base - 8, 8)
        outside(memory, 0, 4)
    }

    /// **Tout en haut** : `indice + largeur` y repasserait par zéro, et une
    /// borne qui ne regarderait que la somme accepterait l'accès.
    func testAnAddressWhoseEndWrapsPastZeroIsOutside() {
        let memory = X86Memory(size: Self.size, base: 0)
        outside(memory, .max, 1)
        outside(memory, .max - 3, 8)
        outside(memory, .max - 7, 8)
    }
}
