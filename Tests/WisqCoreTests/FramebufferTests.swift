import XCTest
@testable import WisqCore

final class FramebufferTests: XCTestCase {
    func testWriteLandsAtTheRightOffset() {
        let framebuffer = Framebuffer(width: 4, height: 4)
        let red: [UInt8] = [0, 0, 255, 255]   // BGRA
        framebuffer.write(rect: Rect(x: 1, y: 2, width: 1, height: 1), bgra: red)

        let pixels = framebuffer.snapshot().pixels
        let offset = (2 * 4 + 1) * 4
        XCTAssertEqual(Array(pixels[offset..<(offset + 4)]), red)
    }

    func testWriteClipsInsteadOfTrapping() {
        let framebuffer = Framebuffer(width: 2, height: 2)
        let block = [UInt8](repeating: 9, count: 4 * 4 * 4)
        framebuffer.write(rect: Rect(x: 1, y: 1, width: 4, height: 4), bgra: block)
        XCTAssertEqual(framebuffer.snapshot().pixels.count, 16)
    }

    func testCopyRectHandlesOverlap() {
        let framebuffer = Framebuffer(width: 4, height: 1)
        // Row: A B C D, one distinct byte pattern per pixel.
        for x in 0..<4 {
            framebuffer.write(rect: Rect(x: x, y: 0, width: 1, height: 1),
                              bgra: [UInt8(x), UInt8(x), UInt8(x), 255])
        }
        // Shift the first three pixels one to the right, overlapping the source.
        framebuffer.copy(from: Point(x: 0, y: 0), to: Rect(x: 1, y: 0, width: 3, height: 1))

        let pixels = framebuffer.snapshot().pixels
        XCTAssertEqual(pixels[0], 0)
        XCTAssertEqual(pixels[4], 0)
        XCTAssertEqual(pixels[8], 1)
        XCTAssertEqual(pixels[12], 2)
    }

    func testResizeClearsContents() {
        let framebuffer = Framebuffer(width: 2, height: 2)
        framebuffer.write(rect: Rect(x: 0, y: 0, width: 1, height: 1), bgra: [1, 2, 3, 4])
        framebuffer.resize(width: 3, height: 3)
        XCTAssertEqual(framebuffer.snapshot().pixels.count, 3 * 3 * 4)
        XCTAssertTrue(framebuffer.snapshot().pixels.allSatisfy { $0 == 0 })
    }
}
