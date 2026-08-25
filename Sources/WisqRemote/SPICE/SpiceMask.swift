import Foundation

/// The 1-bit mask a draw can carry, and the reason it is not a rectangle.
///
/// Every draw message on the display channel ends with a `QMask`: a flags byte,
/// a point, and a pointer to a bitmap that is usually null. When it is not
/// null, the bitmap says **which pixels of the box the draw is allowed to
/// touch** — `canvas_mask_pixman` intersects the destination region with the
/// region of the mask's set bits, and everything outside is left alone.
///
/// That is why it cannot join the rectangles. A region of set bits in a 1-bit
/// bitmap is an arbitrary shape; expressing it as rectangles is a run-length
/// decomposition that in the worst case has one rectangle per pixel. So the
/// rectangles stay what they were — where the draw *may* write — and this
/// answers, per pixel, whether it does.
///
/// The rectangles are still what gets reported to the renderer, and that is
/// deliberate rather than sloppy: an update region is a hint about what to
/// re-upload, so a superset costs a little bandwidth and a subset loses pixels.
enum SpiceMask {
    /// `SPICE_MASK_FLAGS_INVERS`, bit 0.
    ///
    /// Not the same bit as a bitmap's `TOP_DOWN`, which is bit 2 — and the two
    /// flags bytes sit close enough together in a message to be confused.
    static let inverse: UInt8 = 0x01

    enum Failure: Error, Equatable {
        /// The mask names something this client does not have: a cached image,
        /// or another surface.
        case unavailable
        /// A mask that is not a 1-bit bitmap. The reference has no other case
        /// either — `canvas_get_bitmap_mask` handles exactly two formats.
        case notOneBit
        /// The payload is shorter than the geometry it declares.
        case truncated
    }

    /// A mask resolved against the box it applies to.
    ///
    /// `offsetX` and `offsetY` are baked in at construction so the hot loop is
    /// two additions and a shift. They come out of the reference's coordinate
    /// change: a destination pixel *(x, y)* is mask pixel
    /// *(x − box.left + pos.x, y − box.top + pos.y)*.
    struct Resolved: Equatable, Sendable {
        var width: Int
        var height: Int
        var stride: Int
        var bytes: [UInt8]
        /// `oneBitBE`: the leftmost pixel of a byte is bit 7 rather than bit 0.
        var highBitFirst: Bool
        var topDown: Bool
        var inverted: Bool
        var offsetX: Int
        var offsetY: Int

        /// Whether the draw may write this destination pixel.
        ///
        /// **Outside the mask is refused, not allowed.** The reference clips
        /// the mask's extents and then *intersects*, so a destination pixel
        /// with no mask pixel over it falls outside the mask's region and is
        /// dropped. Treating it as permitted would paint the parts of the box
        /// the mask does not reach — which for a small mask over a large box is
        /// most of it.
        func allows(_ x: Int, _ y: Int) -> Bool {
            let maskX = x + offsetX
            let maskY = y + offsetY
            guard maskX >= 0, maskX < width, maskY >= 0, maskY < height else { return false }

            // Bottom-up is a bitmap's default, here as everywhere else on this
            // channel: the first row of data is the last row of the picture.
            let row = topDown ? maskY : height - 1 - maskY
            // Parenthesised past what Swift needs. The precedence happens to
            // be right — `>>` binds tighter than `+`, `&` tighter than `-` —
            // but a reader checking a bit order should not have to know that,
            // and the two orders differ by a mirror rather than by an error.
            let byte = bytes[row * stride + (maskX >> 3)]
            let slot = UInt8(maskX & 7)
            let bit = highBitFirst ? byte >> (7 - slot) : byte >> slot
            return (bit & 1 == 1) != inverted
        }
    }

    /// Resolves a draw's mask, or reports that there is none.
    ///
    /// `nil` means the draw is unmasked and may write its whole region — the
    /// common case by a wide margin, and the reference's first line
    /// (`if (!mask->bitmap) return;`).
    static func resolve(
        _ mask: SpiceDisplayWire.Mask, box: SpiceDisplayWire.Rect
    ) throws -> Resolved? {
        guard let image = mask.bitmap else { return nil }
        // A mask can name a cached image or another surface. wisq keeps no
        // image cache and does not render surface-to-surface masks, so both are
        // "cannot draw this" rather than "malformed message".
        guard image.descriptor.type == .bitmap, let bitmap = image.bitmap,
              let payload = image.payload else {
            throw Failure.unavailable
        }
        let highBitFirst: Bool
        switch bitmap.format {
        case .oneBitLE: highBitFirst = false
        case .oneBitBE: highBitFirst = true
        default: throw Failure.notOneBit
        }

        let width = Int(bitmap.width)
        let height = Int(bitmap.height)
        let stride = Int(bitmap.stride)
        // The reference reads `ALIGN(x, 8) >> 3` bytes per row and steps by the
        // stride, so the stride has to hold at least that much and the payload
        // has to hold every row.
        guard width > 0, height > 0, stride >= (width + 7) / 8,
              payload.count >= stride * height else {
            throw Failure.truncated
        }

        return Resolved(
            width: width, height: height, stride: stride, bytes: payload,
            highBitFirst: highBitFirst, topDown: bitmap.topDown,
            inverted: mask.flags & inverse != 0,
            offsetX: Int(mask.origin.x) - Int(box.left),
            offsetY: Int(mask.origin.y) - Int(box.top)
        )
    }
}
