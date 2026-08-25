import Foundation
import WisqCore

/// The surfaces a SPICE server draws on, and the drawing itself.
///
/// This is where the three finished pieces meet: the display channel says what
/// to draw, the LZ decoder says what the pixels are, and this puts them
/// somewhere. Until it existed each of those was correct and none of them
/// showed anything.
///
/// Everything here is deliberately plain arithmetic over byte arrays, with no
/// actor and no drawing framework, for the same reason the wire layer is: a
/// runner that costs nothing can then check every clipping rule, and clipping
/// rules are where this kind of code goes wrong.
///
/// What goes wrong is worth being exact about, because it differs from the C
/// this protocol grew up in. There, a blit past the end of a row writes the
/// next row and the picture shears — bad, and invisible. Here the array is
/// bounds-checked, so the same mistake traps: the app dies rather than
/// misdraws. Removing the cut below and running the tests demonstrates it —
/// they do not fail, they take the process down. Neither outcome is
/// acceptable when the numbers came off a socket, which is why the cut is a
/// cut and not an assertion.
struct SpiceSurfaces {
    /// A surface's pixels, always four bytes each in BGRA order.
    ///
    /// One layout rather than several on purpose. SPICE names six surface
    /// formats; the two that matter here are 32-bit, and the framebuffer this
    /// eventually reaches is BGRA. Storing anything else would mean converting
    /// twice, and converting in a place with no test around it.
    struct Surface {
        var width: Int
        var height: Int
        /// `true` when the format carries meaningful alpha. An `xRGB` surface
        /// has a padding byte where an `ARGB` one has transparency, and writing
        /// a source's alpha into the pad would make an opaque desktop
        /// see-through in whatever composites it later.
        var hasAlpha: Bool
        var pixels: [UInt8]
    }

    enum Failure: Error, Equatable {
        case unknownSurface(UInt32)
        case surfaceAlreadyExists(UInt32)
        /// A format wisq cannot lay out. Named rather than approximated: a
        /// 16-bit surface written as if it were 32-bit is a screen of noise.
        case unsupportedFormat(SpiceDisplayWire.SurfaceFormat)
        case unreasonableSize(width: UInt32, height: UInt32)
        /// The draw names an encoding, or a shape, this does not do yet. Kept
        /// apart from a malformed message: the caller leaves that region alone
        /// rather than dropping the connection.
        case notDrawable
    }

    /// A ceiling on what a server may ask to allocate.
    ///
    /// 64 megapixels is more than any phone will display and far less than a
    /// `UInt32` allows. Without it, `width * height * 4` from two numbers a
    /// server chose is an allocation a server chose.
    static let maximumPixels = 64 << 20

    private(set) var surfaces: [UInt32: Surface] = [:]

    // MARK: - Lifetime

    mutating func create(_ request: SpiceDisplayWire.SurfaceCreate) throws {
        guard surfaces[request.surfaceID] == nil else {
            throw Failure.surfaceAlreadyExists(request.surfaceID)
        }
        let hasAlpha: Bool
        switch request.format {
        case .xrgb32: hasAlpha = false
        case .argb32: hasAlpha = true
        case .alpha1, .alpha8, .rgb16_555, .rgb16_565:
            throw Failure.unsupportedFormat(request.format)
        }

        let width = Int(request.width)
        let height = Int(request.height)
        guard width > 0, height > 0, width * height <= Self.maximumPixels else {
            throw Failure.unreasonableSize(width: request.width, height: request.height)
        }

        surfaces[request.surfaceID] = Surface(
            width: width, height: height, hasAlpha: hasAlpha,
            pixels: [UInt8](repeating: 0, count: width * height * 4)
        )
    }

    mutating func destroy(_ id: UInt32) {
        surfaces.removeValue(forKey: id)
    }

    // MARK: - Where a draw is allowed to write

    /// The rectangles a draw may touch: its box, cut down to the surface, and
    /// cut again by the clip.
    ///
    /// Both cuts matter and they are not the same cut. The box says where the
    /// server means to draw; the clip says which parts of that the server still
    /// wants visible. Honour only the box and a window that should have stayed
    /// covered gets painted over; honour only the clip and a draw runs off the
    /// surface.
    static func regions(
        of base: SpiceDisplayWire.Base, in surface: Surface
    ) -> [SpiceDisplayWire.Rect] {
        let bounds = SpiceDisplayWire.Rect(
            top: 0, left: 0, bottom: Int32(surface.height), right: Int32(surface.width)
        )
        guard let box = intersect(base.box, bounds) else { return [] }

        switch base.clip {
        case .none:
            return [box]
        case let .rects(rects):
            return rects.compactMap { intersect($0, box) }
        }
    }

    /// The overlap of two rectangles, or `nil` when they do not overlap.
    ///
    /// Returning `nil` rather than an empty rectangle is what stops a negative
    /// width reaching the loops below, where it would be a range that traps or
    /// a count that wraps.
    static func intersect(
        _ lhs: SpiceDisplayWire.Rect, _ rhs: SpiceDisplayWire.Rect
    ) -> SpiceDisplayWire.Rect? {
        let rect = SpiceDisplayWire.Rect(
            top: max(lhs.top, rhs.top),
            left: max(lhs.left, rhs.left),
            bottom: min(lhs.bottom, rhs.bottom),
            right: min(lhs.right, rhs.right)
        )
        return rect.width > 0 && rect.height > 0 ? rect : nil
    }

    // MARK: - Drawing

    /// `DRAW_FILL` with a solid brush.
    ///
    /// Returns the regions actually written, which is what a renderer needs to
    /// know and is not the same as the box it was asked for — most of a fill's
    /// box is often clipped away.
    @discardableResult
    mutating func fill(_ operation: SpiceDisplayWire.Fill) throws -> [SpiceDisplayWire.Rect] {
        guard var surface = surfaces[operation.base.surfaceID] else {
            throw Failure.unknownSurface(operation.base.surfaceID)
        }
        guard case let .solid(colour) = operation.brush else {
            // A pattern brush is a real thing this does not do yet, and a
            // `none` brush writes nothing at all.
            throw Failure.notDrawable
        }

        // The colour is a 32-bit word in the surface's own order, so it lands
        // as four bytes little-endian: blue, green, red, then the pad.
        let blue = UInt8(colour & 0xFF)
        let green = UInt8(colour >> 8 & 0xFF)
        let red = UInt8(colour >> 16 & 0xFF)
        let alpha: UInt8 = surface.hasAlpha ? UInt8(colour >> 24 & 0xFF) : 0

        let written = Self.regions(of: operation.base, in: surface)
        for rect in written {
            for y in Int(rect.top)..<Int(rect.bottom) {
                var index = (y * surface.width + Int(rect.left)) * 4
                for _ in Int(rect.left)..<Int(rect.right) {
                    surface.pixels[index] = blue
                    surface.pixels[index + 1] = green
                    surface.pixels[index + 2] = red
                    surface.pixels[index + 3] = alpha
                    index += 4
                }
            }
        }
        surfaces[operation.base.surfaceID] = surface
        return written
    }

    /// `DRAW_COPY` from a decoded image.
    ///
    /// The source is passed in already decoded rather than decoded here: which
    /// codec produced it is the display channel's business, and keeping that
    /// out means this can be tested with pixels made up on the spot.
    @discardableResult
    mutating func copy(
        _ operation: SpiceDisplayWire.Copy,
        source: (pixels: [UInt8], width: Int, height: Int),
        bytesPerSourcePixel: Int
    ) throws -> [SpiceDisplayWire.Rect] {
        guard var surface = surfaces[operation.base.surfaceID] else {
            throw Failure.unknownSurface(operation.base.surfaceID)
        }
        guard bytesPerSourcePixel == 3 || bytesPerSourcePixel == 4 else {
            throw Failure.notDrawable
        }
        guard source.pixels.count >= source.width * source.height * bytesPerSourcePixel else {
            throw Failure.notDrawable
        }

        let box = operation.base.box
        let area = operation.sourceArea
        guard area.width > 0, area.height > 0, box.width > 0, box.height > 0 else { return [] }

        let written = Self.regions(of: operation.base, in: surface)
        for rect in written {
            for y in Int(rect.top)..<Int(rect.bottom) {
                // Nearest neighbour, and the source coordinate is taken from
                // the *box*, not from the clipped rectangle. A clip moves which
                // pixels get written, never which source pixel each one comes
                // from — computing it from the clip would slide the image
                // sideways wherever something overlapped it.
                let sourceY = Int(area.top) + (y - Int(box.top)) * Int(area.height)
                    / Int(box.height)
                guard sourceY >= 0, sourceY < source.height else { continue }

                for x in Int(rect.left)..<Int(rect.right) {
                    let sourceX = Int(area.left) + (x - Int(box.left)) * Int(area.width)
                        / Int(box.width)
                    guard sourceX >= 0, sourceX < source.width else { continue }

                    let from = (sourceY * source.width + sourceX) * bytesPerSourcePixel
                    let to = (y * surface.width + x) * 4
                    surface.pixels[to] = source.pixels[from]
                    surface.pixels[to + 1] = source.pixels[from + 1]
                    surface.pixels[to + 2] = source.pixels[from + 2]
                    surface.pixels[to + 3] = surface.hasAlpha && bytesPerSourcePixel == 4
                        ? source.pixels[from + 3]
                        : 0
                }
            }
        }
        surfaces[operation.base.surfaceID] = surface
        return written
    }
}
