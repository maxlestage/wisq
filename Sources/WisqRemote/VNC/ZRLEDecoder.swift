import Foundation
import WisqCore

/// ZRLE (RFC 6143 §7.7.5): the rectangle arrives as one zlib blob which inflates
/// into a stream of 64×64 tiles, each independently choosing between raw pixels,
/// a solid colour, a packed palette, or run-length runs.
///
/// This is the encoding that makes a remote desktop usable off a LAN. A 1080p
/// screen in Raw is 8 MB per full frame; the same screen in ZRLE is typically two
/// orders of magnitude less, because most tiles are flat colour or a handful of
/// palette entries.
enum ZRLEDecoder {
    static let tileSize = 64

    static func decode(rect: Rect, data: Data, into framebuffer: Framebuffer) throws {
        guard rect.width > 0, rect.height > 0 else { return }
        var cursor = ByteCursor(data)

        var tileY = rect.y
        while tileY < rect.y + rect.height {
            let tileHeight = min(tileSize, rect.y + rect.height - tileY)
            var tileX = rect.x
            while tileX < rect.x + rect.width {
                let tileWidth = min(tileSize, rect.x + rect.width - tileX)
                let tile = Rect(x: tileX, y: tileY, width: tileWidth, height: tileHeight)
                let pixels = try decodeTile(width: tileWidth, height: tileHeight, from: &cursor)
                framebuffer.write(rect: tile, bgra: pixels)
                tileX += tileSize
            }
            tileY += tileSize
        }
    }

    private static func decodeTile(width: Int, height: Int, from cursor: inout ByteCursor) throws -> [UInt8] {
        let count = width * height
        var pixels = [UInt8](repeating: 0, count: count * 4)

        let subencoding = try cursor.readUInt8()
        let isRunLength = subencoding & 0x80 != 0
        let paletteSize = Int(subencoding & 0x7F)

        switch (isRunLength, paletteSize) {
        case (false, 0):
            // Raw tile.
            for index in 0..<count {
                write(try cursor.readCompressedPixel(), at: index, in: &pixels)
            }

        case (false, 1):
            // Solid tile — the common case on any desktop with a plain background.
            let colour = try cursor.readCompressedPixel()
            for index in 0..<count { write(colour, at: index, in: &pixels) }

        case (false, 2...16):
            let palette = try readPalette(size: paletteSize, from: &cursor)
            try decodePackedPalette(
                palette: palette, width: width, height: height,
                from: &cursor, into: &pixels
            )

        case (true, 0):
            // Plain RLE: a colour and how many pixels it covers, repeatedly.
            var index = 0
            while index < count {
                let colour = try cursor.readCompressedPixel()
                let run = try cursor.readRunLength()
                guard run > 0, index + run <= count else {
                    throw WisqError.malformedMessage("longueur de série ZRLE hors tuile")
                }
                for offset in 0..<run { write(colour, at: index + offset, in: &pixels) }
                index += run
            }

        case (true, 2...127):
            let palette = try readPalette(size: paletteSize, from: &cursor)
            var index = 0
            while index < count {
                var entry = Int(try cursor.readUInt8())
                var run = 1
                // The high bit says a run length follows; without it the entry
                // covers a single pixel.
                if entry & 0x80 != 0 {
                    entry &= 0x7F
                    run = try cursor.readRunLength()
                }
                guard entry < palette.count, run > 0, index + run <= count else {
                    throw WisqError.malformedMessage("série de palette ZRLE invalide")
                }
                for offset in 0..<run { write(palette[entry], at: index + offset, in: &pixels) }
                index += run
            }

        default:
            // 17…127 without runs, and 129 with, are unassigned by the spec.
            throw WisqError.malformedMessage("sous-encodage ZRLE réservé (\(subencoding))")
        }
        return pixels
    }

    /// Palette indices are bit-packed at the smallest width that fits, and each
    /// row restarts on a byte boundary.
    private static func decodePackedPalette(
        palette: [[UInt8]],
        width: Int,
        height: Int,
        from cursor: inout ByteCursor,
        into pixels: inout [UInt8]
    ) throws {
        let bitsPerIndex = palette.count <= 2 ? 1 : (palette.count <= 4 ? 2 : 4)
        let mask = UInt8((1 << bitsPerIndex) - 1)

        for row in 0..<height {
            var bitsLeft = 0
            var current: UInt8 = 0
            for column in 0..<width {
                if bitsLeft == 0 {
                    current = try cursor.readUInt8()
                    bitsLeft = 8
                }
                bitsLeft -= bitsPerIndex
                let entry = Int((current >> UInt8(bitsLeft)) & mask)
                guard entry < palette.count else {
                    throw WisqError.malformedMessage("index de palette ZRLE hors limites")
                }
                write(palette[entry], at: row * width + column, in: &pixels)
            }
            // Whatever is left of the final byte of the row is padding.
        }
    }

    private static func readPalette(size: Int, from cursor: inout ByteCursor) throws -> [[UInt8]] {
        var palette: [[UInt8]] = []
        palette.reserveCapacity(size)
        for _ in 0..<size {
            palette.append(try cursor.readCompressedPixel())
        }
        return palette
    }

    private static func write(_ colour: [UInt8], at index: Int, in pixels: inout [UInt8]) {
        let base = index * 4
        pixels[base] = colour[0]
        pixels[base + 1] = colour[1]
        pixels[base + 2] = colour[2]
        pixels[base + 3] = colour[3]
    }
}
