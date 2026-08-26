import XCTest
@testable import WisqRemote

/// What the decode path costs, counted rather than timed.
///
/// The remaining item on the optimisation list was "the decoders' hot loops —
/// UnsafePointer, ARM intrinsics". The honest finding is that the structural
/// work is already done, and this file is what makes that a fact rather than a
/// claim: the buffer a codec produces reaches the surface **without being
/// copied**, and the one case that must copy allocates exactly once.
///
/// Buffer identity is the right instrument here, and a stopwatch is the wrong
/// one. Two addresses are equal or they are not; the answer does not change
/// because another process woke up. A timing taken in a shared container says
/// nothing at all, which is why no speed-up is claimed anywhere in this work.
///
/// These are guards, not observations. `rowsTopDown` returning its argument
/// untouched on the common path is easy to lose: rewritten as an unconditional
/// row loop it stays *correct*, passes every orientation test, and silently
/// allocates and copies a full frame on every image a top-down server sends —
/// which is most of them.
final class SpiceDecodeCopyTests: XCTestCase {
    /// Where an array's storage lives. Equal addresses mean one buffer, so no
    /// copy happened between the two observations.
    private func address(_ bytes: [UInt8]) -> UInt {
        bytes.withUnsafeBufferPointer { UInt(bitPattern: $0.baseAddress) }
    }

    private func frame(width: Int, height: Int) -> [UInt8] {
        // Each row filled with its own index, so a flip is visible rather than
        // merely different: a uniform buffer would make a reversed frame and an
        // untouched one compare equal.
        var pixels = [UInt8]()
        for row in 0..<height {
            pixels += [UInt8](repeating: UInt8(row), count: width * 4)
        }
        return pixels
    }

    func testATopDownFrameReachesTheSurfaceWithoutBeingCopied() {
        let pixels = frame(width: 8, height: 6)
        let before = address(pixels)

        let out = SpiceDisplayWire.rowsTopDown(
            pixels, width: 8, height: 6, bytesPerPixel: 4, alreadyTopDown: true
        )

        XCTAssertEqual(address(out), before, "le cas courant recopie la trame")
        XCTAssertEqual(out, pixels)
    }

    /// The other direction, so the test above cannot pass by the function
    /// simply never doing anything.
    func testABottomUpFrameIsFlippedIntoANewBuffer() {
        let pixels = frame(width: 8, height: 6)
        let before = address(pixels)

        let out = SpiceDisplayWire.rowsTopDown(
            pixels, width: 8, height: 6, bytesPerPixel: 4, alreadyTopDown: false
        )

        XCTAssertNotEqual(address(out), before, "le retournement rend le même tampon")
        XCTAssertEqual(out.count, pixels.count)
        // Row 0 of the result is the last row of the source, and so on.
        for row in 0..<6 {
            let start = row * 8 * 4
            XCTAssertEqual(out[start], UInt8(5 - row), "ligne \(row)")
        }
    }

    /// Each of `rowsTopDown`'s refusals, one at a time. They exist so a
    /// degenerate frame is handed back rather than read out of bounds, and each
    /// is also a no-copy path.
    func testDegenerateFramesAreReturnedUntouched() {
        let single = frame(width: 4, height: 1)
        XCTAssertEqual(
            address(
                SpiceDisplayWire.rowsTopDown(
                    single, width: 4, height: 1, bytesPerPixel: 4, alreadyTopDown: false
                )
            ),
            address(single),
            "une trame d'une seule ligne est recopiée"
        )

        let empty = [UInt8]()
        XCTAssertEqual(
            SpiceDisplayWire.rowsTopDown(
                empty, width: 0, height: 4, bytesPerPixel: 4, alreadyTopDown: false
            ),
            empty
        )

        // Short of what the geometry demands: reversing it would read past the
        // end, so it comes back as it went in.
        let truncated = [UInt8](repeating: 1, count: 8 * 4 * 6 - 1)
        XCTAssertEqual(
            address(
                SpiceDisplayWire.rowsTopDown(
                    truncated, width: 8, height: 6, bytesPerPixel: 4, alreadyTopDown: false
                )
            ),
            address(truncated),
            "une trame tronquée est recopiée"
        )
    }

    /// The hand-off itself. Decoded frames travel as `(pixels:width:height:)`
    /// and are never mutated in transit, so copy-on-write means the tuple costs
    /// nothing — which is worth pinning, because the day someone gives that
    /// tuple a mutating member the cost appears with no other symptom.
    func testHandingAFrameOnAsATupleDoesNotCopyIt() {
        let pixels = frame(width: 16, height: 16)
        let before = address(pixels)
        let carried: (pixels: [UInt8], width: Int, height: Int) = (pixels, 16, 16)
        XCTAssertEqual(address(carried.pixels), before)
    }

    /// There is deliberately no test here for "the LZ output buffer is reserved
    /// once and never grown".
    ///
    /// It is true — `decompress` calls `reserveCapacity` with the exact final
    /// size before its loop — but it is not observable from outside. The decoded
    /// count is the same whether the array was sized once or grown ten times,
    /// and `capacity` is not a promise: Swift may round it up, so reading it
    /// back proves nothing either way. `SpiceLZTests` already compares every
    /// reference stream's full output against the encoder's own, which pins the
    /// size as a consequence.
    ///
    /// Writing an assertion here anyway would have produced a test that cannot
    /// fail for the reason its name gives — the worst kind, because it reads as
    /// coverage of a claim nothing is actually holding.
}
