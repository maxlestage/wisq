import XCTest
@testable import WisqRemote

/// The GLZ window.
///
/// A note on what these tests are and are not. The header, the bit reader and
/// the family tables could each be compared against a number the reference
/// produces. A ring buffer cannot: `decode-glz.c` states its behaviour, it does
/// not emit a table of answers. So these are unit tests of a data structure
/// whose every rule was read off the reference — not differential tests, and
/// not dressed up as any.
final class SpiceGLZWindowTests: XCTestCase {
    private func image(_ id: UInt64, distance: UInt32 = 0, fill: UInt8 = 0) -> SpiceGLZ.Window.Image {
        SpiceGLZ.Window.Image(
            id: id, winHeadDistance: distance,
            pixels: [UInt8](repeating: fill, count: 16), width: 2, height: 2
        )
    }

    func testAnImageComesBackByTheDistanceThatNamesIt() {
        var window = SpiceGLZ.Window()
        for id in 0..<4 { window.add(image(UInt64(id), fill: UInt8(id))) }

        // A match in image 3 reaching two back means image 1.
        XCTAssertEqual(window.image(from: 3, back: 2)?.id, 1)
        XCTAssertEqual(window.image(from: 3, back: 0)?.id, 3)
        XCTAssertEqual(window.image(from: 3, back: 3)?.id, 0)
    }

    /// **The slot is `id % capacity`, so a stale id lands on a real image of
    /// another generation.** Checking the id after the lookup is the only thing
    /// standing between that and a picture assembled from the wrong frame —
    /// which would look plausible, the worst kind of wrong.
    func testASlotHoldingADifferentGenerationIsNotMistakenForAHit() {
        var window = SpiceGLZ.Window()
        window.add(image(16, fill: 0xAA))       // capacity 16, so slot 0
        XCTAssertNotNil(window.image(from: 16, back: 0))
        // Image 0 would occupy the same slot. It was never added.
        XCTAssertNil(window.image(from: 16, back: 16), "l'identifiant doit être vérifié, pas seulement le créneau")
    }

    func testReachingBackFurtherThanTheFirstImageIsRefused() {
        var window = SpiceGLZ.Window()
        window.add(image(2))
        XCTAssertNil(window.image(from: 2, back: 3), "avant l'image 0 il n'y a rien")
    }

    /// A collision doubles the array and rehashes. Everything already in it has
    /// to survive at its new slot, or a later match resolves to nil and the
    /// image is dropped.
    func testGrowingKeepsEveryImageFindable() {
        var window = SpiceGLZ.Window()
        for id in 0..<40 { window.add(image(UInt64(id))) }
        XCTAssertGreaterThan(window.capacity, SpiceGLZ.Window.initialCapacity)
        for id in 0..<40 {
            XCTAssertEqual(window.image(from: 39, back: UInt32(39 - id))?.id, UInt64(id), "image \(id)")
        }
    }

    /// A grow must rehash on the **new** capacity, not the old one.
    ///
    /// Added because a sabotage using the old modulus survived every other
    /// test here. Not equivalence — an input separates them, it just took
    /// constructing: an id larger than the capacity has to be sitting in the
    /// array when a grow happens, and the ids `40, 24, 8` in that order do it.
    ///
    /// `40 % 32` is 8 while `40 % 64` is 40, so the wrong modulus files image
    /// 40 where image 8 then lands on top of it. It vanishes silently — no
    /// error, just an image the next match cannot find.
    func testGrowingRehashesOnTheNewCapacityAndNotTheOld() {
        var window = SpiceGLZ.Window()
        for id in [40, 24, 8] { window.add(image(UInt64(id))) }
        XCTAssertEqual(window.count, 3, "aucune image ne doit être écrasée par l'agrandissement")
        for id in [40, 24, 8] {
            XCTAssertEqual(window.image(from: 40, back: UInt32(40 - id))?.id, UInt64(id), "image \(id)")
        }
    }

    /// Holes are expected, not exceptional: a VM with several displays uses a
    /// socket per display, so ids arrive out of order. A hole must survive a
    /// grow, and must not stop the images around it being found.
    func testHolesSurviveAGrowAndDoNotSwallowTheirNeighbours() {
        var window = SpiceGLZ.Window()
        for id in [0, 1, 2, 5, 6, 20, 21, 33] { window.add(image(UInt64(id))) }
        for id in [0, 1, 2, 5, 6, 20, 21, 33] {
            XCTAssertEqual(window.image(from: 33, back: UInt32(33 - id))?.id, UInt64(id), "image \(id)")
        }
        for missing in [3, 4, 7, 19] {
            XCTAssertNil(window.image(from: 33, back: UInt32(33 - missing)), "image \(missing)")
        }
    }

    /// `tail_gap` is the first id not yet known present, so it stops at the
    /// first hole even when later ids have landed.
    ///
    /// And it advances **no further than the id just added** — the reference's
    /// loop is bounded by `tail_gap <= img->hdr.id`. So filling a hole does not
    /// run the counter on over images that arrived early; it catches up only
    /// when their own ids come round. Written expecting 3 here first, which was
    /// wrong: it is 2, with image 2 sitting present but uncounted.
    ///
    /// That is not a detail. `releaseAfterAdding` reads `images[tailGap - 1]`
    /// to decide what is still needed, so the image it consults is not always
    /// the newest one in the window.
    func testTheGapAdvancesNoFurtherThanTheImageJustAdded() {
        var window = SpiceGLZ.Window()
        window.add(image(0))
        XCTAssertEqual(window.tailGap, 1)
        window.add(image(2))
        XCTAssertEqual(window.tailGap, 1, "1 manque encore")
        window.add(image(1))
        XCTAssertEqual(window.tailGap, 2, "borné par l'identifiant ajouté, donc il ne saute pas par-dessus 2")
        XCTAssertNotNil(window.image(from: 2, back: 0), "l'image 2 est bien là, simplement pas encore comptée")
        window.add(image(3))
        XCTAssertEqual(window.tailGap, 4, "et il rattrape quand l'identifiant suivant arrive")
    }

    func testReleasingDropsTheOldAndKeepsTheRest() {
        var window = SpiceGLZ.Window()
        for id in 0..<8 { window.add(image(UInt64(id))) }
        window.release(before: 5)
        for id in 0..<5 {
            XCTAssertNil(window.image(from: 7, back: UInt32(7 - id)), "image \(id)")
        }
        for id in 5..<8 {
            XCTAssertEqual(window.image(from: 7, back: UInt32(7 - id))?.id, UInt64(id), "image \(id)")
        }
    }

    /// What the reference runs after every image: the newest one says how far
    /// back anything may still reach, and everything older goes.
    func testTheNewestImageDecidesWhatIsStillNeeded() {
        var window = SpiceGLZ.Window()
        for id in 0..<8 { window.add(image(UInt64(id), distance: 2)) }
        window.releaseAfterAdding()
        // Newest is 7 with a distance of 2, so nothing older than 5 is needed.
        XCTAssertEqual(window.oldest, 5)
        XCTAssertNil(window.image(from: 7, back: 3))
        XCTAssertEqual(window.image(from: 7, back: 2)?.id, 5)
    }

    /// **The divergence, pinned.**
    ///
    /// `glz_decoder_window_clear` resets the array and the gap but not
    /// `oldest`, and `oldest` only ever moves forward. spice-session.c calls it
    /// on reconnect and on session switching — on a window that has been used.
    /// After that the ids restart at zero, every release target falls far below
    /// the stale `oldest`, and nothing is released again while `add` keeps
    /// doubling on each collision: a reconnect leaks the previous session and
    /// the window grows without bound.
    ///
    /// This resets it. Nothing in the protocol asks for the other behaviour; it
    /// is an omission in one function.
    func testClearingLetsTheWindowReleaseAgainAfterAReconnect() {
        var window = SpiceGLZ.Window()
        for id in 0..<200 { window.add(image(UInt64(id), distance: 1)) }
        window.releaseAfterAdding()
        XCTAssertGreaterThan(window.oldest, 0, "la première session a bien libéré")
        let grown = window.capacity

        window.clear()
        XCTAssertEqual(window.oldest, 0, "sans ça, plus rien ne serait jamais libéré")
        XCTAssertEqual(window.capacity, SpiceGLZ.Window.initialCapacity, "et le tableau repart petit")
        XCTAssertGreaterThan(grown, SpiceGLZ.Window.initialCapacity, "il avait bien grandi")
        XCTAssertEqual(window.tailGap, 0)

        // The ids restart, and releasing works again rather than never firing.
        for id in 0..<40 { window.add(image(UInt64(id), distance: 1)) }
        window.releaseAfterAdding()
        XCTAssertEqual(window.oldest, 38)
        XCTAssertEqual(window.count, 2, "seules les images encore atteignables restent")
    }
}
