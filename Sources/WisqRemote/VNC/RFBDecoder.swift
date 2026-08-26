import Foundation
import WisqCore
import WisqNet

/// Decodes framebuffer rectangles off the wire into the shared `Framebuffer`.
///
/// Every decoder here works on the 32bpp little-endian format wisq negotiates, so
/// pixels arrive as B,G,R,X and land in the buffer with only the alpha byte fixed up.
struct RFBDecoder {
    let stream: any ByteStream
    let framebuffer: Framebuffer
    /// Session-lived zlib streams. Compressed encodings depend on their
    /// dictionaries surviving from one rectangle to the next.
    let streams: RFBStreams

    /// Result of decoding one rectangle: either it painted pixels, or it carried
    /// out-of-band information the session needs to act on.
    enum Outcome {
        case painted(Rect)
        case resized(width: Int, height: Int)
        case renamed(String)
        case serverSupportsResize
        case cursorChanged(RemoteCursor)
        case endOfRectangles
        case ignored
    }

    func decodeRectangle() async throws -> Outcome {
        let x = Int(try await stream.readUInt16())
        let y = Int(try await stream.readUInt16())
        let width = Int(try await stream.readUInt16())
        let height = Int(try await stream.readUInt16())
        let encoding = try await stream.readInt32()
        let rect = Rect(x: x, y: y, width: width, height: height)

        switch RFB.Encoding(rawValue: encoding) {
        case .raw:
            try await decodeRaw(rect)
            return .painted(rect)
        case .copyRect:
            let srcX = Int(try await stream.readUInt16())
            let srcY = Int(try await stream.readUInt16())
            framebuffer.copy(from: Point(x: srcX, y: srcY), to: rect)
            return .painted(rect)
        case .rre:
            try await decodeRRE(rect)
            return .painted(rect)
        case .hextile:
            try await decodeHextile(rect)
            return .painted(rect)
        case .zlib:
            try await decodeZlib(rect)
            return .painted(rect)
        case .zrle:
            try await decodeZRLE(rect)
            return .painted(rect)
        case .tight:
            try await TightDecoder(stream: stream, streams: streams, framebuffer: framebuffer)
                .decode(rect: rect)
            return .painted(rect)
        case .cursor:
            // x,y carry the hotspot rather than a position.
            return .cursorChanged(try await decodeCursor(rect))
        case .desktopSize:
            return .resized(width: width, height: height)
        case .extendedDesktopSize:
            try await consumeExtendedDesktopSize()
            // x carries the reason and y the result code; a non-zero result means
            // the server refused our resize and kept its own geometry.
            let accepted = y == 0
            return accepted ? .resized(width: width, height: height) : .serverSupportsResize
        case .desktopName:
            let length = Int(try await stream.readUInt32())
            guard length <= RFBLimits.maximumTextBytes else {
                throw WisqError.malformedMessage(
                    "nom de bureau de \(length) octets, plafond \(RFBLimits.maximumTextBytes)")
            }
            return .renamed(try await stream.readLatin1(count: length))
        case .lastRect:
            return .endOfRectangles
        default:
            throw WisqError.unsupportedEncoding(encoding)
        }
    }

    // MARK: - Encodings

    private func decodeRaw(_ rect: Rect) async throws {
        guard rect.width > 0, rect.height > 0 else { return }
        var pixels = [UInt8](try await stream.read(exactly: rect.width * rect.height * 4))
        // The X byte is undefined on the wire; Core Graphics reads it as alpha.
        for index in stride(from: 3, to: pixels.count, by: 4) { pixels[index] = 255 }
        framebuffer.write(rect: rect, bgra: pixels)
    }

    /// Zlib (encoding 6) is Raw pixels through the session's zlib stream — the
    /// simplest possible win, and the fallback when a server speaks neither ZRLE
    /// nor Tight.
    private func decodeZlib(_ rect: Rect) async throws {
        let length = Int(try await stream.readUInt32())
        let ceiling = RFBLimits.maximumCompressedBytes(for: rect)
        guard length <= ceiling else {
            throw WisqError.malformedMessage(
                "bloc zlib de \(length) octets pour un rectangle qui en admet \(ceiling)")
        }
        let compressed = try await stream.read(exactly: length)
        var pixels = [UInt8](try streams.zlib.inflate(compressed))
        guard pixels.count == rect.width * rect.height * 4 else {
            throw WisqError.malformedMessage(
                "zlib a produit \(pixels.count) octets au lieu de \(rect.width * rect.height * 4)"
            )
        }
        for index in stride(from: 3, to: pixels.count, by: 4) { pixels[index] = 255 }
        framebuffer.write(rect: rect, bgra: pixels)
    }

    private func decodeZRLE(_ rect: Rect) async throws {
        let length = Int(try await stream.readUInt32())
        let ceiling = RFBLimits.maximumCompressedBytes(for: rect)
        guard length <= ceiling else {
            throw WisqError.malformedMessage(
                "bloc ZRLE de \(length) octets pour un rectangle qui en admet \(ceiling)")
        }
        let compressed = try await stream.read(exactly: length)
        let tiles = try streams.zrle.inflate(compressed)
        try ZRLEDecoder.decode(rect: rect, data: tiles, into: framebuffer)
    }

    private func decodeRRE(_ rect: Rect) async throws {
        let subrectangleCount = Int(try await stream.readUInt32())
        let background = try await readPixel()

        var tile = [UInt8](repeating: 0, count: max(0, rect.width * rect.height * 4))
        fill(&tile, width: rect.width, rect: Rect(x: 0, y: 0, width: rect.width, height: rect.height), colour: background)

        for _ in 0..<subrectangleCount {
            let colour = try await readPixel()
            let x = Int(try await stream.readUInt16())
            let y = Int(try await stream.readUInt16())
            let width = Int(try await stream.readUInt16())
            let height = Int(try await stream.readUInt16())
            fill(&tile, width: rect.width, rect: Rect(x: x, y: y, width: width, height: height), colour: colour)
        }
        framebuffer.write(rect: rect, bgra: tile)
    }

    /// Hextile splits the rectangle into 16×16 tiles, each either raw or a
    /// background colour plus a handful of subrectangles.
    private func decodeHextile(_ rect: Rect) async throws {
        var background: [UInt8] = [0, 0, 0, 255]
        var foreground: [UInt8] = [255, 255, 255, 255]

        var tileY = rect.y
        while tileY < rect.y + rect.height {
            let tileHeight = min(16, rect.y + rect.height - tileY)
            var tileX = rect.x
            while tileX < rect.x + rect.width {
                let tileWidth = min(16, rect.x + rect.width - tileX)
                let tileRect = Rect(x: tileX, y: tileY, width: tileWidth, height: tileHeight)
                let subencoding = try await stream.readUInt8()

                if subencoding & Hextile.raw != 0 {
                    try await decodeRaw(tileRect)
                } else {
                    if subencoding & Hextile.backgroundSpecified != 0 {
                        background = try await readPixel()
                    }
                    if subencoding & Hextile.foregroundSpecified != 0 {
                        foreground = try await readPixel()
                    }

                    var tile = [UInt8](repeating: 0, count: tileWidth * tileHeight * 4)
                    fill(&tile, width: tileWidth,
                         rect: Rect(x: 0, y: 0, width: tileWidth, height: tileHeight),
                         colour: background)

                    if subencoding & Hextile.anySubrects != 0 {
                        let count = Int(try await stream.readUInt8())
                        let coloured = subencoding & Hextile.subrectsColoured != 0
                        for _ in 0..<count {
                            let colour = coloured ? try await readPixel() : foreground
                            // Position and size are packed as two nibbles each.
                            let xy = try await stream.readUInt8()
                            let wh = try await stream.readUInt8()
                            let subrect = Rect(
                                x: Int(xy >> 4), y: Int(xy & 0x0F),
                                width: Int(wh >> 4) + 1, height: Int(wh & 0x0F) + 1
                            )
                            fill(&tile, width: tileWidth, rect: subrect, colour: colour)
                        }
                    }
                    framebuffer.write(rect: tileRect, bgra: tile)
                }
                tileX += 16
            }
            tileY += 16
        }
    }

    /// Cursor pseudo-encoding: pixels in the negotiated format, then a 1-bit mask,
    /// each row of which is padded to a whole byte, MSB = leftmost pixel.
    private func decodeCursor(_ rect: Rect) async throws -> RemoteCursor {
        guard rect.width > 0, rect.height > 0 else {
            return RemoteCursor(width: 0, height: 0, hotspotX: 0, hotspotY: 0, bgra: [])
        }
        guard rect.width <= 256, rect.height <= 256 else {
            throw WisqError.malformedMessage("curseur démesuré (\(rect.width)×\(rect.height))")
        }

        var pixels = [UInt8](try await stream.read(exactly: rect.width * rect.height * 4))
        let maskRowBytes = (rect.width + 7) / 8
        let mask = [UInt8](try await stream.read(exactly: maskRowBytes * rect.height))

        for row in 0..<rect.height {
            for column in 0..<rect.width {
                let bit = (mask[row * maskRowBytes + column / 8] >> (7 - UInt8(column % 8))) & 1
                pixels[(row * rect.width + column) * 4 + 3] = bit == 1 ? 255 : 0
            }
        }
        return RemoteCursor(
            width: rect.width, height: rect.height,
            hotspotX: rect.x, hotspotY: rect.y,
            bgra: pixels
        )
    }

    private func consumeExtendedDesktopSize() async throws {
        let screenCount = Int(try await stream.readUInt8())
        _ = try await stream.read(exactly: 3)
        if screenCount > 0 {
            _ = try await stream.read(exactly: screenCount * 16)
        }
    }

    // MARK: - Helpers

    private func readPixel() async throws -> [UInt8] {
        var pixel = [UInt8](try await stream.read(exactly: 4))
        pixel[3] = 255
        return pixel
    }

    /// Paints a solid rectangle inside a tile buffer of `width` pixels per row.
    private func fill(_ buffer: inout [UInt8], width: Int, rect: Rect, colour: [UInt8]) {
        guard width > 0, rect.width > 0, rect.height > 0, colour.count == 4 else { return }
        let rows = buffer.count / (width * 4)
        var row = [UInt8]()
        row.reserveCapacity(rect.width * 4)
        for _ in 0..<rect.width { row.append(contentsOf: colour) }

        for line in 0..<rect.height {
            let y = rect.y + line
            guard y >= 0, y < rows, rect.x >= 0 else { continue }
            let clippedWidth = min(rect.width, width - rect.x)
            guard clippedWidth > 0 else { continue }
            let start = (y * width + rect.x) * 4
            buffer.replaceSubrange(start..<(start + clippedWidth * 4), with: row[0..<(clippedWidth * 4)])
        }
    }

    private enum Hextile {
        static let raw: UInt8 = 0x01
        static let backgroundSpecified: UInt8 = 0x02
        static let foregroundSpecified: UInt8 = 0x04
        static let anySubrects: UInt8 = 0x08
        static let subrectsColoured: UInt8 = 0x10
    }
}
