import XCTest
@testable import WisqRemote

/// The image cache, the sub-message list that carries its invalidations, and
/// the one rule that makes the pair work: **the server evicts, the client
/// obeys.**
final class SpicePixmapCacheTests: XCTestCase {
    private func u16(_ value: UInt16) -> [UInt8] { [UInt8(value & 0xFF), UInt8(value >> 8)] }
    private func u32(_ value: UInt32) -> [UInt8] { (0..<4).map { UInt8(value >> (8 * $0) & 0xFF) } }
    private func u64(_ value: UInt64) -> [UInt8] { (0..<8).map { UInt8(value >> (8 * $0) & 0xFF) } }

    private func entry(_ side: Int, fill: UInt8 = 0xAB) -> SpicePixmapCache.Entry {
        SpicePixmapCache.Entry(
            pixels: [UInt8](repeating: fill, count: side * side * 4), width: side, height: side
        )
    }

    // MARK: - Le cache

    func testAStoredImageComesBackByItsIdentifier() {
        var cache = SpicePixmapCache(budgetPixels: 1_000)
        XCTAssertTrue(cache.store(7, entry(10)))
        XCTAssertEqual(cache.image(7)?.width, 10)
        XCTAssertEqual(cache.storedPixels, 100)
        XCTAssertNil(cache.image(8), "un identifiant jamais stocké n'est pas un autre")
    }

    /// **The budget is counted in pixels, not bytes**, because that is the unit
    /// the server counts in when it decides whether an image fits:
    /// `dcc_pixmap_cache_unlocked_add(dcc, id, width * height, …)`. Counting
    /// bytes here would drift from the number the other end holds itself to by
    /// exactly the colour depth — four times, and always in the direction that
    /// makes this client refuse things the server thinks it kept.
    func testTheBudgetIsPixelsAndNotBytes() {
        var cache = SpicePixmapCache(budgetPixels: 100)
        XCTAssertTrue(cache.store(1, entry(10)), "100 pixels tiennent dans 100")
        XCTAssertEqual(cache.storedPixels, 100)
        // 400 octets sont entrés dans un budget de 100 : c'est bien la surface
        // qui est comptée.
        XCTAssertEqual(cache.image(1)?.pixels.count, 400)
    }

    /// **Over budget is refused, not made room for.**
    ///
    /// Every instinct says a full cache should evict, and that instinct is
    /// wrong here. The server keeps its own mirror and drives eviction: it
    /// drops its LRU tail and names it in `INVAL_LIST`. A second LRU chain on
    /// this side — ordered by draws rather than by sends — would diverge, and
    /// each divergence is a `FROM_CACHE` naming something already gone, which
    /// draws nothing at all. Refusing is the honest failure: it costs one
    /// re-sent image, where quietly holding more than promised costs the app.
    func testAnImageOverBudgetIsRefusedRatherThanEvictingSomething() {
        var cache = SpicePixmapCache(budgetPixels: 200)
        XCTAssertTrue(cache.store(1, entry(10)))
        XCTAssertTrue(cache.store(2, entry(10)))
        XCTAssertEqual(cache.storedPixels, 200)

        XCTAssertFalse(cache.store(3, entry(10)), "le budget est plein")
        XCTAssertNotNil(cache.image(1), "rien n'a été évincé pour faire de la place")
        XCTAssertNotNil(cache.image(2))
        XCTAssertNil(cache.image(3))
        XCTAssertEqual(cache.count, 2)
    }

    /// `CACHE_REPLACE_ME` on the wire: the server re-sends losslessly what it
    /// had cached lossily, under the same identifier. Replacing has to settle
    /// the accounting, or the budget leaks by the old size every time.
    func testStoringAgainReplacesAndTheAccountingFollows() {
        var cache = SpicePixmapCache(budgetPixels: 500)
        XCTAssertTrue(cache.store(1, entry(10, fill: 0x11)))
        XCTAssertEqual(cache.storedPixels, 100)

        XCTAssertTrue(cache.store(1, entry(20, fill: 0x22)))
        XCTAssertEqual(cache.count, 1, "un seul identifiant")
        XCTAssertEqual(cache.storedPixels, 400, "l'ancienne taille est rendue")
        XCTAssertEqual(cache.image(1)?.pixels.first, 0x22)

        // Et dans l'autre sens, pour que le calcul ne soit pas juste par hasard
        // sur une seule direction.
        XCTAssertTrue(cache.store(1, entry(5)))
        XCTAssertEqual(cache.storedPixels, 25)
    }

    /// Dropping something never held is not an error: the list is the server's,
    /// and it may name an image this client refused to store.
    func testDroppingWhatWasNeverHeldIsNotAnError() {
        var cache = SpicePixmapCache(budgetPixels: 500)
        cache.store(1, entry(10))
        cache.drop(99)
        XCTAssertEqual(cache.storedPixels, 100)
        cache.drop(1)
        XCTAssertEqual(cache.storedPixels, 0)
        XCTAssertEqual(cache.count, 0)
    }

    func testClearingForgetsEverythingAndItsAccounting() {
        var cache = SpicePixmapCache(budgetPixels: 500)
        cache.store(1, entry(10))
        cache.store(2, entry(10))
        cache.clear()
        XCTAssertEqual(cache.count, 0)
        XCTAssertEqual(cache.storedPixels, 0)
        XCTAssertTrue(cache.store(3, entry(10)), "le budget entier est de nouveau libre")
    }

    /// A zero-area image would be a free entry that can never be evicted by
    /// size, and nothing sends one.
    func testAnEmptyImageIsNotStored() {
        var cache = SpicePixmapCache(budgetPixels: 500)
        XCTAssertFalse(cache.store(
            1, SpicePixmapCache.Entry(pixels: [], width: 0, height: 0)
        ))
        XCTAssertEqual(cache.count, 0)
    }

    /// The cache the client builds and the number it announces are the same
    /// promise; a default that disagreed would mean the server sizing itself
    /// against one bound and this client against another.
    func testTheDefaultBudgetIsTheDeclaredOne() {
        XCTAssertEqual(
            SpicePixmapCache().budgetPixels, Int(SpiceDisplayClient.pixmapCachePixels)
        )
        XCTAssertGreaterThan(SpiceDisplayClient.pixmapCachePixels, 0)
    }

    // MARK: - La liste de sous-messages

    /// **`SpiceSubMessageList`'s first field is a count, not a size**, whatever
    /// the reference's struct calls it: `spice_marshaller_add_uint16(sub_list_m,
    /// sub_list_len)` is what goes on the wire. Read as a byte count, a
    /// two-entry list would ask for a hundred-odd offsets and run off the end.
    func testTheSubListLeadsWithACountRatherThanAByteSize() throws {
        // Deux sous-messages, placés après la liste, à des décalages connus.
        var body = [UInt8](repeating: 0, count: 4)     // du corps qui précède
        let listAt = body.count
        body += u16(2)                                  // le NOMBRE d'entrées
        let offsetsAt = body.count
        body += u32(0) + u32(0)                         // réservé pour les décalages
        let firstAt = body.count
        body += u16(105) + u32(3) + [0xAA, 0xBB, 0xCC]
        let secondAt = body.count
        body += u16(5) + u32(1) + [0xDD]

        body.replaceSubrange(offsetsAt..<(offsetsAt + 4), with: u32(UInt32(firstAt)))
        body.replaceSubrange((offsetsAt + 4)..<(offsetsAt + 8), with: u32(UInt32(secondAt)))

        let subs = try SpiceSubMessages.list(at: UInt32(listAt), in: body)
        XCTAssertEqual(subs.count, 2)
        XCTAssertEqual(subs[0].type, 105)
        XCTAssertEqual(subs[0].payload, [0xAA, 0xBB, 0xCC])
        XCTAssertEqual(subs[1].type, 5)
        XCTAssertEqual(subs[1].payload, [0xDD])
    }

    /// **Offset zero is a real offset, not "there is no list".**
    ///
    /// The header's `sub_list` field uses 0 to mean absent, and that check
    /// belongs to the code reading the header. `SPICE_MSG_LIST` — the form a
    /// mini-header server sends — puts its list at the very start of the body,
    /// which is offset 0. Folding the sentinel into the parser made that whole
    /// branch return nothing at all, and it did so silently, which is how it
    /// survived being written.
    func testOffsetZeroIsAListAndNotAnAbsentOne() throws {
        var body = u16(1) + u32(6)
        body += u16(105) + u32(2) + [0x0A, 0x0B]
        let subs = try SpiceSubMessages.list(at: 0, in: body)
        XCTAssertEqual(subs.count, 1, "une liste à l'octet zéro est une liste")
        XCTAssertEqual(subs[0].type, 105)
        XCTAssertEqual(subs[0].payload, [0x0A, 0x0B])
    }

    /// An empty list is empty because its count says so, which is a different
    /// statement from "there was no list here".
    func testACountOfZeroIsAnEmptyList() throws {
        XCTAssertEqual(try SpiceSubMessages.list(at: 0, in: u16(0)).count, 0)
    }

    /// The sizes come off a socket, so they are checked rather than believed.
    func testASubMessageRunningPastTheBodyIsRefused() {
        var body = u16(1) + u32(6)
        body += u16(105) + u32(0xFFFF)                  // une taille impossible
        XCTAssertThrowsError(try SpiceSubMessages.list(at: 0, in: body))

        // Et un décalage qui pointe hors du corps, plutôt qu'une taille.
        XCTAssertThrowsError(
            try SpiceSubMessages.list(at: 0, in: u16(1) + u32(9_999))
        )
    }

    // MARK: - Les invalidations

    /// **`ResourceID` is nine bytes with no padding** — a `uint8` then a
    /// `uint64`. Read as a naturally aligned struct, the second entry would
    /// start a byte early and every identifier after the first would be
    /// nonsense. Three entries, so the drift is visible rather than merely
    /// possible.
    func testAnInvalidationListIsPackedNineBytesAnEntry() throws {
        let payload = u16(3)
            + [1] + u64(0x1111_2222_3333_4444)
            + [1] + u64(0x5555_6666_7777_8888)
            + [0] + u64(0x9999_AAAA_BBBB_CCCC)
        XCTAssertEqual(payload.count, 2 + 3 * 9)

        let resources = try SpiceDisplayWire.invalidations(payload)
        XCTAssertEqual(resources.count, 3)
        XCTAssertEqual(resources[0].id, 0x1111_2222_3333_4444)
        XCTAssertEqual(resources[1].id, 0x5555_6666_7777_8888)
        XCTAssertEqual(resources[2].id, 0x9999_AAAA_BBBB_CCCC)
        XCTAssertEqual(resources[2].type, SpiceDisplayWire.ResourceType.invalid)
    }

    /// The list is typed because it carries palettes too, and this client keeps
    /// no palette cache. Dropping a palette identifier as though it named an
    /// image would evict a picture that is still perfectly good — and the
    /// identifiers come from different spaces, so the collision is a matter of
    /// time rather than luck.
    func testOnlyPixmapsAreDroppedFromAListThatAlsoNamesPalettes() {
        XCTAssertEqual(SpiceDisplayWire.ResourceType.pixmap, 1)
        XCTAssertEqual(SpiceDisplayWire.ResourceType.invalid, 0)
    }
}
