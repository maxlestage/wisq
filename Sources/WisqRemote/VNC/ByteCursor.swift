import Foundation
import WisqCore

/// Sequential reader over a block of already-inflated bytes.
///
/// The framebuffer decoders read from the socket asynchronously, but once a
/// compressed rectangle has been inflated the whole tile stream is in memory and
/// parsing it synchronously is both simpler and faster.
struct ByteCursor {
    private let bytes: [UInt8]
    private var offset: Int

    init(_ data: Data) {
        self.bytes = [UInt8](data)
        self.offset = 0
    }

    var remaining: Int { bytes.count - offset }
    var isAtEnd: Bool { offset >= bytes.count }

    mutating func readUInt8() throws -> UInt8 {
        guard offset < bytes.count else {
            throw WisqError.malformedMessage("données compressées tronquées")
        }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func read(_ count: Int) throws -> ArraySlice<UInt8> {
        guard count >= 0, offset + count <= bytes.count else {
            throw WisqError.malformedMessage("données compressées tronquées")
        }
        defer { offset += count }
        return bytes[offset..<(offset + count)]
    }

    /// CPIXEL, the compressed pixel ZRLE uses.
    ///
    /// With the 32bpp little-endian format wisq negotiates, the colour lives in the
    /// low three bytes and CPIXEL carries exactly those, in the pixel's own byte
    /// order: B, G, R. Note this differs from Tight's TPIXEL, which is always R,G,B.
    mutating func readCompressedPixel() throws -> [UInt8] {
        let slice = try read(3)
        let base = slice.startIndex
        return [slice[base], slice[base + 1], slice[base + 2], 255]
    }

    /// TPIXEL, the pixel Tight uses: always red, green, blue — regardless of the
    /// shifts negotiated for PIXEL. Stored as B,G,R,A to match the framebuffer.
    mutating func readTightPixel() throws -> [UInt8] {
        let slice = try read(3)
        let base = slice.startIndex
        return [slice[base + 2], slice[base + 1], slice[base], 255]
    }

    /// A run length spread over as many bytes as it needs: every 255 means "keep
    /// reading", and the total plus one is the length.
    mutating func readRunLength() throws -> Int {
        var length = 1
        var byte: UInt8
        repeat {
            byte = try readUInt8()
            length += Int(byte)
        } while byte == 255
        return length
    }
}
