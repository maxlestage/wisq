import XCTest
@testable import WisqRemote

/// The ternary raster operation.
///
/// One line of code stands in for the reference's 256 generated handlers, so
/// the tests carry the weight. Two independent things pin the indexing:
///
///   * **the named GDI constants**, which come from Windows' documentation
///     rather than from anything in this repository — `SRCCOPY` is `0xCC` and
///     means "the source", and only one bit order makes that true;
///   * **`scripts/spice-rop3/check-rop3.py`**, which reads the 218 formulas out
///     of the reference's `rop3.c` and evaluates each over all eight operand
///     combinations. That check does not run here because it needs the C file;
///     it runs from the script directory and its result is recorded there.
final class SpiceROP3Tests: XCTestCase {
    /// Windows names these, and the names are the point: they are external
    /// evidence for the bit order, not a restatement of it.
    private enum Opcode {
        static let blackness: UInt8 = 0x00
        static let notSourceEraseNorPattern: UInt8 = 0x11   // DSon: ~(src | dest)
        static let sourceAnd: UInt8 = 0x88                  // SRCAND
        static let sourceInvert: UInt8 = 0x66               // SRCINVERT
        static let destinationInvert: UInt8 = 0x55          // DSTINVERT
        static let sourceCopy: UInt8 = 0xCC                 // SRCCOPY
        static let destinationCopy: UInt8 = 0xAA            // DSTCOPY
        static let sourcePaint: UInt8 = 0xEE                // SRCPAINT
        static let patternCopy: UInt8 = 0xF0                // PATCOPY
        static let patternInvert: UInt8 = 0x5A              // PATINVERT
        static let whiteness: UInt8 = 0xFF
    }

    // MARK: - The named operations

    /// **Only one bit order makes these names true**, which is what makes them
    /// worth writing down. Read the table the other way — the way `SpiceROP`
    /// reads its four-bit one, from the top — and `SRCCOPY` becomes something
    /// else entirely.
    func testTheNamedGDIOperationsDoWhatTheirNamesSay() {
        let pattern: UInt8 = 0b1111_0000
        let source: UInt8 = 0b1100_1100
        let destination: UInt8 = 0b1010_1010

        func apply(_ opcode: UInt8) -> UInt8 {
            SpiceROP3(opcode).apply(
                pattern: pattern, source: source, destination: destination
            )
        }

        XCTAssertEqual(apply(Opcode.blackness), 0x00)
        XCTAssertEqual(apply(Opcode.whiteness), 0xFF)
        XCTAssertEqual(apply(Opcode.sourceCopy), source, "SRCCOPY")
        XCTAssertEqual(apply(Opcode.destinationCopy), destination, "DSTCOPY")
        XCTAssertEqual(apply(Opcode.patternCopy), pattern, "PATCOPY")
        XCTAssertEqual(apply(Opcode.sourceAnd), source & destination, "SRCAND")
        XCTAssertEqual(apply(Opcode.sourcePaint), source | destination, "SRCPAINT")
        XCTAssertEqual(apply(Opcode.sourceInvert), source ^ destination, "SRCINVERT")
        XCTAssertEqual(apply(Opcode.destinationInvert), ~destination, "DSTINVERT")
        XCTAssertEqual(apply(Opcode.patternInvert), pattern ^ destination, "PATINVERT")
        XCTAssertEqual(
            apply(Opcode.notSourceEraseNorPattern), ~(source | destination), "DSon"
        )

        // The three operands are deliberately the three "column" patterns of a
        // three-input truth table, so every one of the eight combinations
        // appears exactly once across the byte. A test using equal operands
        // would agree with a table that muddled two of them.
        var seen = Set<Int>()
        for bit in 0..<8 {
            seen.insert(
                Int(pattern >> UInt8(bit) & 1) << 2 | Int(source >> UInt8(bit) & 1) << 1
                    | Int(destination >> UInt8(bit) & 1)
            )
        }
        XCTAssertEqual(seen.count, 8, "les huit combinaisons sont couvertes")
    }

    /// The opcode *is* the result for the eight combinations, read off in
    /// order — which is the same statement as the implementation and so is
    /// checked against the named constants above rather than trusted alone.
    func testEveryOpcodeReproducesItselfFromTheEightCombinations() {
        for raw in UInt8.min...UInt8.max {
            let operation = SpiceROP3(raw)
            var rebuilt: UInt8 = 0
            for index in UInt8(0)..<8 {
                let bit = operation.apply(
                    pattern: index >> 2 & 1 == 1 ? 0xFF : 0,
                    source: index >> 1 & 1 == 1 ? 0xFF : 0,
                    destination: index & 1 == 1 ? 0xFF : 0
                )
                XCTAssertTrue(bit == 0x00 || bit == 0xFF, "opcode \(raw), index \(index)")
                if bit == 0xFF { rebuilt |= 1 << index }
            }
            XCTAssertEqual(rebuilt, raw)
        }
    }

    /// Every channel is independent, and every bit within it: the result for a
    /// byte is the result for each of its bits. Sixteen million checks would be
    /// the exhaustive form; this samples the operands and is exhaustive over
    /// the opcodes, which is where a mistake would live.
    func testTheOperationIsBitwiseAndIndependentPerBit() {
        let values: [UInt8] = [0x00, 0x01, 0x0F, 0x55, 0xAA, 0x7F, 0x80, 0xF0, 0xFE, 0xFF]
        for raw in UInt8.min...UInt8.max {
            let operation = SpiceROP3(raw)
            for pattern in values {
                for source in values {
                    for destination in values {
                        let got = operation.apply(
                            pattern: pattern, source: source, destination: destination
                        )
                        var expected: UInt8 = 0
                        for bit in UInt8(0)..<8 {
                            let index = (pattern >> bit & 1) << 2 | (source >> bit & 1) << 1
                                | (destination >> bit & 1)
                            expected |= (raw >> index & 1) << bit
                        }
                        guard got == expected else {
                            return XCTFail("opcode \(raw) : \(got) au lieu de \(expected)")
                        }
                    }
                }
            }
        }
    }

    // MARK: - What the reference leaves out

    /// **The 38 opcodes the reference does not implement are exactly the 38
    /// that ignore at least one operand.**
    ///
    /// Not a coincidence: those are the ones a server sends as a simpler
    /// message instead — `0xCC` as a `DRAW_COPY`, `0xF0` as a `DRAW_FILL`,
    /// `0x00` as a `DRAW_BLACKNESS` — and `rop3.c` calls
    /// `spice_critical("not implemented")` if one arrives anyway.
    ///
    /// The list is checked against `rop3.c` itself by
    /// `scripts/spice-rop3/check-rop3.py`. What is checked *here* is the
    /// property, so that `ignores` cannot drift away from the arithmetic the
    /// script relies on.
    func testTheDegenerateOpcodesAreExactlyTheThirtyEight() {
        let degenerate = (UInt8.min...UInt8.max).filter { raw in
            let operation = SpiceROP3(raw)
            return SpiceROP3.Operand.allCases.contains { operation.ignores($0) }
        }
        XCTAssertEqual(degenerate.count, 38)
        // The ones with names, all of which have a dedicated message.
        for opcode in [Opcode.blackness, Opcode.whiteness, Opcode.sourceCopy,
                       Opcode.destinationCopy, Opcode.patternCopy, Opcode.sourceAnd,
                       Opcode.sourcePaint, Opcode.sourceInvert, Opcode.destinationInvert] {
            XCTAssertTrue(degenerate.contains(opcode), "0x\(String(opcode, radix: 16))")
        }
        // And one that needs all three, so the property is not vacuous.
        XCTAssertFalse(degenerate.contains(0x01), "DPSoon a besoin des trois")
        XCTAssertFalse(degenerate.contains(0xE2))
    }

    func testIgnoringAnOperandMeansFlippingItChangesNothing() {
        for raw in UInt8.min...UInt8.max {
            let operation = SpiceROP3(raw)
            for operand in SpiceROP3.Operand.allCases where operation.ignores(operand) {
                for other in UInt8(0)..<4 {
                    let first: UInt8 = other >> 1 & 1 == 1 ? 0xFF : 0
                    let second: UInt8 = other & 1 == 1 ? 0xFF : 0
                    let low: UInt8
                    let high: UInt8
                    switch operand {
                    case .pattern:
                        low = operation.apply(pattern: 0, source: first, destination: second)
                        high = operation.apply(pattern: 0xFF, source: first, destination: second)
                    case .source:
                        low = operation.apply(pattern: first, source: 0, destination: second)
                        high = operation.apply(pattern: first, source: 0xFF, destination: second)
                    case .destination:
                        low = operation.apply(pattern: first, source: second, destination: 0)
                        high = operation.apply(pattern: first, source: second, destination: 0xFF)
                    }
                    XCTAssertEqual(low, high, "opcode \(raw), \(operand)")
                }
            }
        }
    }

    func testTheTernaryNoOperationIsDestinationCopy() {
        XCTAssertTrue(SpiceROP3(Opcode.destinationCopy).leavesTheDestinationAlone)
        XCTAssertFalse(SpiceROP3(Opcode.sourceCopy).leavesTheDestinationAlone)
    }
}
