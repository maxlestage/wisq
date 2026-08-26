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
    /// order: B, G, R. Tight's TPIXEL is the other way round — always R,G,B —
    /// and `TightDecoder.readTightPixel` is where that one lives, because Tight
    /// reads from the socket rather than from an inflated block.
    ///
    /// There used to be a `readTightPixel` here too, with **no caller**: a
    /// second spelling of a rule already kept next door, free to drift because
    /// nothing reached it. Sabotage found it — reversing its byte order left
    /// the whole suite green, while reversing the real one turned twenty-nine
    /// tests red. Removed rather than tested: a rule kept in one place cannot
    /// disagree with itself.
    mutating func readCompressedPixel() throws -> [UInt8] {
        let slice = try read(3)
        let base = slice.startIndex
        return [slice[base], slice[base + 1], slice[base + 2], 255]
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
