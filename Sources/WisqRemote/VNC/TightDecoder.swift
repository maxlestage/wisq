import Foundation
import WisqCore
import WisqNet

/// Tight (RFC 6143 §7.7.6): the encoding TigerVNC and TightVNC reach for first.
///
/// Where ZRLE has one zlib stream and one tile format, Tight has four streams the
/// server picks between per rectangle, three filters, and a "if it is under twelve
/// bytes, do not bother compressing" rule. That complexity buys the best ratio of
/// any lossless RFB encoding.
///
/// JPEG is deliberately absent. A server may only send JPEG rectangles if the
/// client advertised a quality level, and wisq advertises none — so this decoder
/// never has to deal with them, and nothing platform-specific creeps into the
/// protocol layer. Adding JPEG later means advertising a quality level and
/// decoding through ImageIO on Apple platforms; see docs/ROADMAP.md.
struct TightDecoder {
    let stream: any ByteStream
    let streams: RFBStreams
    let framebuffer: Framebuffer

    private enum Filter: UInt8 {
        case copy = 0
        case palette = 1
        case gradient = 2
    }

    /// Anything shorter than this is sent uncompressed: zlib's own overhead would
    /// cost more than it saves.
    private static let compressionThreshold = 12

    func decode(rect: Rect) async throws {
        guard rect.width > 0, rect.height > 0 else { return }

        let control = try await stream.readUInt8()
        // The low nibble asks for zlib streams to be restarted before use.
        for streamIndex in 0..<4 where control & (1 << UInt8(streamIndex)) != 0 {
            try streams.resetTight(streamIndex)
        }

        let kind = control >> 4
        switch kind {
        case 0x8:
            let colour = try await readTightPixel()
            var pixels = [UInt8](repeating: 0, count: rect.width * rect.height * 4)
            for index in 0..<(rect.width * rect.height) {
                pixels[index * 4] = colour[0]
                pixels[index * 4 + 1] = colour[1]
                pixels[index * 4 + 2] = colour[2]
                pixels[index * 4 + 3] = 255
            }
            framebuffer.write(rect: rect, bgra: pixels)

        case 0x9:
            throw WisqError.unsupportedEncoding(RFB.Encoding.tight.rawValue)

        case 0xA...0xF:
            throw WisqError.malformedMessage("octet de contrôle Tight réservé (\(control))")

        default:
            try await decodeBasic(rect: rect, kind: kind)
        }
    }

    private func decodeBasic(rect: Rect, kind: UInt8) async throws {
        let streamIndex = Int(kind & 0x3)
        let filter: Filter
        if kind & 0x4 != 0 {
            let raw = try await stream.readUInt8()
            guard let parsed = Filter(rawValue: raw) else {
                throw WisqError.malformedMessage("filtre Tight inconnu (\(raw))")
            }
            filter = parsed
        } else {
            filter = .copy
        }

        switch filter {
        case .copy:
            let data = try await readData(expecting: rect.width * rect.height * 3, stream: streamIndex)
            framebuffer.write(rect: rect, bgra: expandTightPixels(data, count: rect.width * rect.height))

        case .palette:
            let paletteSize = Int(try await stream.readUInt8()) + 1
            var palette: [[UInt8]] = []
            palette.reserveCapacity(paletteSize)
            for _ in 0..<paletteSize { palette.append(try await readTightPixel()) }

            // Two colours pack to one bit per pixel with rows byte-aligned;
            // anything more uses a whole byte per pixel.
            let expected = paletteSize == 2
                ? ((rect.width + 7) / 8) * rect.height
                : rect.width * rect.height
            let data = try await readData(expecting: expected, stream: streamIndex)
            framebuffer.write(
                rect: rect,
                bgra: try expandPalette(data, palette: palette, rect: rect)
            )

        case .gradient:
            let data = try await readData(expecting: rect.width * rect.height * 3, stream: streamIndex)
            framebuffer.write(rect: rect, bgra: applyGradient(data, rect: rect))
        }
    }

    // MARK: - Reading

    private func readTightPixel() async throws -> [UInt8] {
        // TPIXEL is always red, green, blue — unlike ZRLE's CPIXEL, which follows
        // the negotiated byte order. Stored B,G,R,A for the framebuffer.
        let bytes = [UInt8](try await stream.read(exactly: 3))
        return [bytes[2], bytes[1], bytes[0], 255]
    }

    private func readData(expecting size: Int, stream streamIndex: Int) async throws -> [UInt8] {
        guard size > 0 else { return [] }
        if size < Self.compressionThreshold {
            return [UInt8](try await stream.read(exactly: size))
        }

        let length = try await readCompactLength()
        let compressed = try await stream.read(exactly: length)
        let inflated = try streams.tight(streamIndex).inflate(compressed)
        guard inflated.count == size else {
            throw WisqError.malformedMessage(
                "Tight a produit \(inflated.count) octets au lieu de \(size)"
            )
        }
        return [UInt8](inflated)
    }

    /// Up to three bytes, seven significant bits each, high bit meaning "continues".
    private func readCompactLength() async throws -> Int {
        let first = try await stream.readUInt8()
        var length = Int(first & 0x7F)
        guard first & 0x80 != 0 else { return length }

        let second = try await stream.readUInt8()
        length |= Int(second & 0x7F) << 7
        guard second & 0x80 != 0 else { return length }

        let third = try await stream.readUInt8()
        length |= Int(third & 0xFF) << 14
        return length
    }

    // MARK: - Filters

    private func expandTightPixels(_ data: [UInt8], count: Int) -> [UInt8] {
        var pixels = [UInt8](repeating: 255, count: count * 4)
        for index in 0..<count {
            let source = index * 3
            let target = index * 4
            pixels[target] = data[source + 2]       // blue
            pixels[target + 1] = data[source + 1]   // green
            pixels[target + 2] = data[source]       // red
        }
        return pixels
    }

    private func expandPalette(_ data: [UInt8], palette: [[UInt8]], rect: Rect) throws -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: rect.width * rect.height * 4)

        if palette.count == 2 {
            let rowBytes = (rect.width + 7) / 8
            for row in 0..<rect.height {
                for column in 0..<rect.width {
                    let byte = data[row * rowBytes + column / 8]
                    let entry = Int((byte >> (7 - UInt8(column % 8))) & 1)
                    place(palette[entry], at: row * rect.width + column, in: &pixels)
                }
            }
        } else {
            for index in 0..<(rect.width * rect.height) {
                let entry = Int(data[index])
                guard entry < palette.count else {
                    throw WisqError.malformedMessage("index de palette Tight hors limites")
                }
                place(palette[entry], at: index, in: &pixels)
            }
        }
        return pixels
    }

    /// The gradient filter sends each component as its difference from a
    /// prediction built out of the pixels left, above, and above-left. It is what
    /// makes photographic content compress at all without JPEG.
    private func applyGradient(_ data: [UInt8], rect: Rect) -> [UInt8] {
        var pixels = [UInt8](repeating: 255, count: rect.width * rect.height * 4)
        // Decoded RGB, kept separately because the prediction reads back neighbours.
        var decoded = [UInt8](repeating: 0, count: rect.width * rect.height * 3)

        for row in 0..<rect.height {
            for column in 0..<rect.width {
                for component in 0..<3 {
                    let here = (row * rect.width + column) * 3 + component
                    let left = column > 0 ? Int(decoded[here - 3]) : 0
                    let above = row > 0 ? Int(decoded[here - rect.width * 3]) : 0
                    let aboveLeft = (row > 0 && column > 0) ? Int(decoded[here - rect.width * 3 - 3]) : 0

                    let prediction = min(max(left + above - aboveLeft, 0), 255)
                    decoded[here] = UInt8((Int(data[here]) + prediction) & 0xFF)
                }
                let source = (row * rect.width + column) * 3
                let target = (row * rect.width + column) * 4
                pixels[target] = decoded[source + 2]       // blue
                pixels[target + 1] = decoded[source + 1]   // green
                pixels[target + 2] = decoded[source]       // red
            }
        }
        return pixels
    }

    private func place(_ colour: [UInt8], at index: Int, in pixels: inout [UInt8]) {
        let base = index * 4
        pixels[base] = colour[0]
        pixels[base + 1] = colour[1]
        pixels[base + 2] = colour[2]
        pixels[base + 3] = colour[3]
    }
}
