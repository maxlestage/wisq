import Foundation
import WisqCore
#if canImport(ImageIO) && canImport(CoreGraphics)
import CoreGraphics
import ImageIO
#endif

/// JPEG decoding for Tight's lossy path.
///
/// The protocol layer stays platform-neutral: on Apple platforms this wraps
/// ImageIO, elsewhere it reports itself unavailable — and the encoding
/// negotiation checks `isAvailable`, so a platform without a decoder simply
/// never advertises a quality level and a compliant server never sends JPEG.
enum JPEGDecoder {
    static var isAvailable: Bool {
        #if canImport(ImageIO) && canImport(CoreGraphics)
        return true
        #else
        return false
        #endif
    }

    /// Decodes a JPEG into BGRA matching the framebuffer's layout.
    static func decode(_ data: Data) throws -> (width: Int, height: Int, bgra: [UInt8]) {
        #if canImport(ImageIO) && canImport(CoreGraphics)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [
                  kCGImageSourceShouldCache: false,
              ] as CFDictionary) else {
            throw WisqError.malformedMessage("JPEG illisible")
        }

        let width = image.width
        let height = image.height
        guard width > 0, height > 0, width <= 16384, height <= 16384 else {
            throw WisqError.malformedMessage("dimensions JPEG invalides (\(image.width)×\(image.height))")
        }

        // Redrawing through a context guarantees the BGRA little-endian layout
        // whatever pixel format the codec decoded to.
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else {
            throw WisqError.malformedMessage("conversion JPEG impossible")
        }
        for index in stride(from: 3, to: pixels.count, by: 4) { pixels[index] = 255 }
        return (width, height, pixels)
        #else
        throw WisqError.notImplemented("décodage JPEG indisponible sur cette plateforme")
        #endif
    }
}
