import Foundation

/// The image SPICE sends as two codecs over the same pixels.
///
/// `jpegAlpha` is a JPEG for the colour and an `xxxa` LZ stream for the
/// opacity, one after the other in a single payload. Neither half is unusual;
/// what is unusual is that they describe **the same pixels**, so the second
/// writes the fourth byte of what the first produced rather than an image of
/// its own.
///
/// Two things to get right, and both are quiet:
///
///   * **Where the JPEG ends is a number in the message.** Looking for a JPEG
///     end marker would be a guess, and the alpha stream has no magic of its
///     own that could not also occur inside JPEG data.
///   * **The two halves must agree about which way up they are.** The outer
///     flags decide, and the LZ stream carries the same claim; the reference
///     canvas refuses the image when they disagree rather than picking one.
///     Picking one would show a picture with its opacity upside down.
enum SpiceJPEGAlphaDecoder {
    static var isAvailable: Bool { JPEGDecoder.isAvailable }

    /// Decodes both halves, or reports the image undrawable.
    ///
    /// Returns `nil` rather than throwing for the cases the reference canvas
    /// also declines: no decoder, or the two halves disagreeing. Those leave
    /// that part of the screen alone. A malformed *stream* still throws — that
    /// is a connection to drop, not a rectangle to skip.
    static func pixels(
        _ payload: [UInt8], shape: SpiceDisplayWire.Image.JPEGAlpha
    ) throws -> (pixels: [UInt8], width: Int, height: Int)? {
        guard shape.jpegBytes > 0, shape.jpegBytes <= payload.count else { return nil }
        guard let colour = try? JPEGDecoder.decode(Data(payload[0..<shape.jpegBytes]))
        else { return nil }

        var pixels = colour.bgra
        let alpha = try SpiceLZ.applyAlpha(Array(payload[shape.jpegBytes...]), to: &pixels)

        // The reference canvas asserts all three and yields nothing when any
        // fails. Sizes that disagree would have the alpha pass writing past the
        // colour it is meant to cover; an orientation that disagrees would show
        // the picture with its opacity upside down.
        guard alpha.width == colour.width,
              alpha.height == colour.height,
              alpha.topDown == shape.topDown else { return nil }

        return (pixels, colour.width, colour.height)
    }
}
