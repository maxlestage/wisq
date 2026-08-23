import XCTest
import WisqCore
import WisqNet
@testable import WisqRemote

final class ZRLEDecoderTests: XCTestCase {
    private func decode(_ fixture: [UInt8], rect: Rect, into framebuffer: Framebuffer) async throws {
        try await CompressedHarness.decode(fixture, encoding: .zrle, rect: rect, into: framebuffer)
    }

    private func pixel(_ framebuffer: Framebuffer, _ x: Int, _ y: Int) -> [UInt8] {
        CompressedHarness.pixel(framebuffer, x, y)
    }

    func testSolidTile() async throws {
        let framebuffer = Framebuffer(width: 4, height: 2)
        try await decode(CompressedFixtures.zrleSolid, rect: Rect(x: 0, y: 0, width: 4, height: 2), into: framebuffer)
        // CPIXEL carries B,G,R for our little-endian format; R=0x10 G=0x20 B=0x30.
        for x in 0..<4 {
            for y in 0..<2 {
                XCTAssertEqual(pixel(framebuffer, x, y), [0x30, 0x20, 0x10, 255])
            }
        }
    }

    func testRawTile() async throws {
        let framebuffer = Framebuffer(width: 2, height: 2)
        try await decode(CompressedFixtures.zrleRaw, rect: Rect(x: 0, y: 0, width: 2, height: 2), into: framebuffer)
        XCTAssertEqual(pixel(framebuffer, 0, 0), [3, 2, 1, 255])
        XCTAssertEqual(pixel(framebuffer, 1, 0), [6, 5, 4, 255])
        XCTAssertEqual(pixel(framebuffer, 0, 1), [9, 8, 7, 255])
        XCTAssertEqual(pixel(framebuffer, 1, 1), [12, 11, 10, 255])
    }

    /// Ten pixels per row means the packed indices leave six spare bits that are
    /// padding, not data — getting that wrong shifts every row after the first.
    func testPackedPaletteWithRowPadding() async throws {
        let framebuffer = Framebuffer(width: 10, height: 2)
        try await decode(CompressedFixtures.zrlePackedPalette, rect: Rect(x: 0, y: 0, width: 10, height: 2), into: framebuffer)
        let red: [UInt8] = [0, 0, 0xFF, 255]
        let blue: [UInt8] = [0xFF, 0, 0, 255]
        for x in 0..<10 {
            XCTAssertEqual(pixel(framebuffer, x, 0), x % 2 == 0 ? blue : red, "ligne 0, colonne \(x)")
            XCTAssertEqual(pixel(framebuffer, x, 1), x % 2 == 0 ? red : blue, "ligne 1, colonne \(x)")
        }
    }

    func testPlainRunLength() async throws {
        let framebuffer = Framebuffer(width: 4, height: 1)
        try await decode(CompressedFixtures.zrlePlainRLE, rect: Rect(x: 0, y: 0, width: 4, height: 1), into: framebuffer)
        for x in 0..<3 { XCTAssertEqual(pixel(framebuffer, x, 0), [9, 9, 9, 255]) }
        XCTAssertEqual(pixel(framebuffer, 3, 0), [50, 100, 200, 255])
    }

    func testPaletteRunLength() async throws {
        let framebuffer = Framebuffer(width: 4, height: 1)
        try await decode(CompressedFixtures.zrlePaletteRLE, rect: Rect(x: 0, y: 0, width: 4, height: 1), into: framebuffer)
        XCTAssertEqual(pixel(framebuffer, 0, 0), [1, 1, 1, 255])
        XCTAssertEqual(pixel(framebuffer, 1, 0), [1, 1, 1, 255])
        XCTAssertEqual(pixel(framebuffer, 2, 0), [2, 2, 2, 255])
        XCTAssertEqual(pixel(framebuffer, 3, 0), [1, 1, 1, 255])
    }

    /// Tiles are 64 wide, so a 70-pixel rectangle is two of them. The second tile
    /// must land at x=64, not back at the origin.
    func testRectangleSpanningTwoTiles() async throws {
        let framebuffer = Framebuffer(width: 70, height: 1)
        try await decode(CompressedFixtures.zrleTwoTiles, rect: Rect(x: 0, y: 0, width: 70, height: 1), into: framebuffer)
        XCTAssertEqual(pixel(framebuffer, 0, 0), [3, 2, 1, 255])
        XCTAssertEqual(pixel(framebuffer, 63, 0), [3, 2, 1, 255])
        XCTAssertEqual(pixel(framebuffer, 64, 0), [6, 5, 4, 255])
        XCTAssertEqual(pixel(framebuffer, 69, 0), [6, 5, 4, 255])
    }

    func testReservedSubencodingIsRejected() async throws {
        // Subencoding 17 with no run flag is unassigned; decoding it as anything
        // would desynchronise the tile stream silently.
        var tile = Data([17])
        tile.append(contentsOf: [UInt8](repeating: 0, count: 32))
        XCTAssertThrowsError(
            try ZRLEDecoder.decode(
                rect: Rect(x: 0, y: 0, width: 2, height: 2),
                data: tile,
                into: Framebuffer(width: 2, height: 2)
            )
        )
    }
}
