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
        // Each side is bounded before the two are multiplied, and that order is
        // the whole point. `width` and `height` are `UInt32` off a socket, so
        // their product reaches 1.8 × 10^19 — past `Int.max`, where Swift traps.
        // The ceiling below was therefore unreachable by exactly the sizes it
        // existed to refuse: `SPICE_MSG_DISPLAY_SURFACE_CREATE` with two
        // `0xFFFFFFFF` fields took the app down inside the guard, at the `*`.
        //
        // The two new clauses accept and refuse precisely what the third one
        // already did — with both sides at least 1, either side exceeding the
        // ceiling puts the product past it too — so nothing legitimate changes
        // size. They only make the product safe to compute: bounded by 2^26
        // each, it cannot leave an `Int`.
        guard width > 0, height > 0,
              width <= Self.maximumPixels, height <= Self.maximumPixels,
              width * height <= Self.maximumPixels else {
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
        let mask = try Self.mask(operation.mask, box: operation.base.box)
        // **A fill's rop combines the brush with the destination**, so the flag
        // that inverts its source is `INVERS_BRUSH`. Reading `INVERS_SRC` here
        // would give a fill that never inverts anything.
        let rop = SpiceROP.descriptor(
            operation.rop, source: .brush, destination: .destination
        )

        let written = Self.regions(of: operation.base, in: surface)
        Self.paint(
            colour, rop: rop, over: written, mask: mask, into: &surface
        )
        surfaces[operation.base.surfaceID] = surface
        return written
    }

    /// A solid colour combined with what is already there.
    ///
    /// Shared by `fill` and `opaque`, which differ in where the rop comes from
    /// and in what has been drawn underneath by the time it runs — not in this.
    private static func paint(
        _ colour: UInt32, rop: SpiceROP, over regions: [SpiceDisplayWire.Rect],
        mask: SpiceMask.Resolved?, into surface: inout Surface
    ) {
        // The colour is a 32-bit word in the surface's own order, so it lands
        // as four bytes little-endian: blue, green, red, then the pad.
        let blue = UInt8(colour & 0xFF)
        let green = UInt8(colour >> 8 & 0xFF)
        let red = UInt8(colour >> 16 & 0xFF)
        let alpha = UInt8(colour >> 24 & 0xFF)

        for rect in regions {
            for y in Int(rect.top)..<Int(rect.bottom) {
                var index = (y * surface.width + Int(rect.left)) * 4
                for x in Int(rect.left)..<Int(rect.right) {
                    defer { index += 4 }
                    guard mask?.allows(x, y) ?? true else { continue }
                    surface.pixels[index] = rop.apply(
                        source: blue, destination: surface.pixels[index]
                    )
                    surface.pixels[index + 1] = rop.apply(
                        source: green, destination: surface.pixels[index + 1]
                    )
                    surface.pixels[index + 2] = rop.apply(
                        source: red, destination: surface.pixels[index + 2]
                    )
                    // The reference applies the rop to the whole 32-bit word,
                    // alpha included. On a surface without one the fourth byte
                    // is held at zero instead, the rule the rest of this file
                    // follows — otherwise `invert` would fill the pad with
                    // 0xFF and every pixel would claim an alpha it does not
                    // have.
                    surface.pixels[index + 3] = surface.hasAlpha
                        ? rop.apply(source: alpha, destination: surface.pixels[index + 3])
                        : 0
                }
            }
        }
    }

    /// `DRAW_STROKE` — a path drawn as one-pixel lines.
    ///
    /// The rop reads the brush as its source and the destination as its
    /// destination, the same pairing a fill uses:
    /// `ropd_descriptor_to_rop(fore_mode, ROP_INPUT_BRUSH, ROP_INPUT_DEST)`.
    /// That matters more here than anywhere else, because the descriptor a
    /// stroke arrives with is very often `XOR` — a rubber-band outline, a caret,
    /// a selection rectangle are all drawn twice so the second one takes the
    /// first off. Read as a copy, they go on and stay on.
    ///
    /// **A pixel is painted once even where a path crosses itself.** Under an
    /// `XOR` the difference is visible: a figure-of-eight painted twice at its
    /// crossing has a hole there. The reference gets this from spans that do
    /// not overlap within one `FillSpans` call; here the walk collects
    /// coordinates first and paints each one once.
    ///
    /// A stroke carries no mask — `SpiceStroke` has no `SpiceQMask` field at
    /// all — so unlike a fill there is nothing to reduce it beyond the clip.
    @discardableResult
    mutating func stroke(
        _ operation: SpiceDisplayWire.Stroke
    ) throws -> [SpiceDisplayWire.Rect] {
        guard var surface = surfaces[operation.base.surfaceID] else {
            throw Failure.unknownSurface(operation.base.surfaceID)
        }
        guard case let .solid(colour) = operation.brush else {
            // A pattern brush is a real thing this does not do yet, and a
            // `none` brush writes nothing at all.
            throw Failure.notDrawable
        }
        let rop = SpiceROP.descriptor(
            operation.foreMode, source: .brush, destination: .destination
        )
        let regions = Self.regions(of: operation.base, in: surface)
        guard !regions.isEmpty else { return [] }

        var touched = Set<Int>()
        for figure in SpiceStrokeRaster.polylines(operation.path) {
            // The dash cycle runs along the whole figure rather than restarting
            // at each vertex: a dashed rectangle's pattern carries around its
            // corners, and restarting would put a dash at every one of them.
            var cycle = operation.attr.dashes.map {
                SpiceStrokeRaster.DashCycle(lengths: $0.lengths, offset: $0.offset)
            }
            for (start, end) in zip(figure, figure.dropFirst()) {
                SpiceStrokeRaster.line(from: start, to: end) { x, y in
                    let drawn = cycle == nil || cycle!.step()
                    guard drawn else { return }
                    guard x >= 0, y >= 0, x < surface.width, y < surface.height else { return }
                    guard regions.contains(where: { rect in
                        x >= Int(rect.left) && x < Int(rect.right)
                            && y >= Int(rect.top) && y < Int(rect.bottom)
                    }) else { return }
                    touched.insert(y * surface.width + x)
                }
            }
        }
        guard !touched.isEmpty else { return [] }

        Self.paint(colour, rop: rop, atPixels: touched, into: &surface)
        surfaces[operation.base.surfaceID] = surface
        return regions
    }

    /// A solid colour combined with what is already at a scattered set of
    /// pixels, rather than over rectangles.
    ///
    /// A stroke's shape is a diagonal run, not a box, so the rectangle-shaped
    /// `paint` above cannot express it. The rop and the alpha rule are the
    /// same, and deliberately so: a stroke inverting a surface without an alpha
    /// channel must leave its pad at zero exactly as a fill does, or the line
    /// would claim an opacity the surface does not have.
    private static func paint(
        _ colour: UInt32, rop: SpiceROP, atPixels pixels: Set<Int>, into surface: inout Surface
    ) {
        let blue = UInt8(colour & 0xFF)
        let green = UInt8(colour >> 8 & 0xFF)
        let red = UInt8(colour >> 16 & 0xFF)
        let alpha = UInt8(colour >> 24 & 0xFF)

        for pixel in pixels {
            let index = pixel * 4
            guard index + 3 < surface.pixels.count else { continue }
            surface.pixels[index] = rop.apply(source: blue, destination: surface.pixels[index])
            surface.pixels[index + 1] = rop.apply(
                source: green, destination: surface.pixels[index + 1]
            )
            surface.pixels[index + 2] = rop.apply(
                source: red, destination: surface.pixels[index + 2]
            )
            surface.pixels[index + 3] = surface.hasAlpha
                ? rop.apply(source: alpha, destination: surface.pixels[index + 3])
                : 0
        }
    }

    /// `DRAW_TEXT` — glyphs painted through a brush.
    ///
    /// **Neither of the message's two modes is a raster operation.** The
    /// reference fills the background with `SPICE_ROP_COPY` and composites the
    /// foreground with `PIXMAN_OP_OVER`, never reading `back_mode` and reading
    /// `fore_mode` only to assert that it is `PUT`. Its own comment says so:
    /// *"Nothing else makes sense for text and we should deprecate it and
    /// actually it means OVER really"*. So this ignores both, deliberately, and
    /// a reader looking for `SpiceROP.descriptor` here will not find it.
    ///
    /// The two steps are separate for a reason a test can see: the background
    /// covers `back_area` whether or not a glyph lands on it, and the glyphs
    /// cover their own union whether or not there is a background. An empty
    /// `back_area` — the common case, transparent text — draws no background at
    /// all rather than a zero-sized one.
    @discardableResult
    mutating func text(
        _ operation: SpiceDisplayWire.Text
    ) throws -> [SpiceDisplayWire.Rect] {
        guard var surface = surfaces[operation.base.surfaceID] else {
            throw Failure.unknownSurface(operation.base.surfaceID)
        }
        guard case let .solid(foreground) = operation.foreBrush else {
            throw Failure.notDrawable
        }
        let regions = Self.regions(of: operation.base, in: surface)
        guard !regions.isEmpty else { return [] }

        if !Self.isEmpty(operation.backArea) {
            guard case let .solid(background) = operation.backBrush else {
                throw Failure.notDrawable
            }
            let behind = regions.compactMap { Self.intersect(operation.backArea, $0) }
            // `SPICE_ROP_COPY`, not the descriptor: the background is written,
            // not combined.
            Self.paint(background, rop: .copy, over: behind, mask: nil, into: &surface)
        }

        if let coverage = SpiceGlyphMask.build(operation.string) {
            Self.paint(foreground, coverage: coverage, over: regions, into: &surface)
        }

        surfaces[operation.base.surfaceID] = surface
        return regions
    }

    static func isEmpty(_ rect: SpiceDisplayWire.Rect) -> Bool {
        rect.right <= rect.left || rect.bottom <= rect.top
    }

    /// A solid colour over the destination, weighted by a coverage mask.
    ///
    /// `PIXMAN_OP_OVER` with a solid source and an alpha mask, which for an
    /// opaque brush comes to `destination + (source − destination) × coverage`.
    /// Written as pixman writes it — `MUL_UN8` on each channel — rather than as
    /// a float multiply, so that A4's 240 and A8's 255 land exactly where the
    /// reference puts them.
    ///
    /// A1 coverage is 0 or 255 and this reduces to a copy, which is why the
    /// same path serves all three depths.
    private static func paint(
        _ colour: UInt32, coverage: SpiceGlyphMask.Coverage,
        over regions: [SpiceDisplayWire.Rect], into surface: inout Surface
    ) {
        let blue = UInt8(colour & 0xFF)
        let green = UInt8(colour >> 8 & 0xFF)
        let red = UInt8(colour >> 16 & 0xFF)

        for rect in regions {
            for y in max(Int(rect.top), coverage.top)..<min(Int(rect.bottom),
                                                            coverage.top + coverage.height) {
                guard y >= 0, y < surface.height else { continue }
                for x in max(Int(rect.left), coverage.left)..<min(Int(rect.right),
                                                                  coverage.left + coverage.width) {
                    guard x >= 0, x < surface.width else { continue }
                    let alpha = coverage.at(x - coverage.left, y - coverage.top)
                    guard alpha > 0 else { continue }
                    let index = (y * surface.width + x) * 4
                    surface.pixels[index] = over(blue, surface.pixels[index], alpha)
                    surface.pixels[index + 1] = over(green, surface.pixels[index + 1], alpha)
                    surface.pixels[index + 2] = over(red, surface.pixels[index + 2], alpha)
                    // The brush is opaque, so where it covers at all it makes
                    // the destination that much more opaque. On a surface with
                    // no alpha channel the pad stays at zero, the rule the rest
                    // of this file follows.
                    surface.pixels[index + 3] = surface.hasAlpha
                        ? max(surface.pixels[index + 3], alpha)
                        : 0
                }
            }
        }
    }

    /// One channel of `PIXMAN_OP_OVER` against an opaque source.
    private static func over(_ source: UInt8, _ destination: UInt8, _ alpha: UInt8) -> UInt8 {
        // destination × (1 − alpha) + source × alpha, in pixman's arithmetic.
        multiply(destination, 255 &- alpha) &+ multiply(source, alpha)
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
        bytesPerSourcePixel: Int,
        blitROP: SpiceROP? = nil
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

        let mask = try Self.mask(operation.mask, box: operation.base.box)
        // A copy's rop combines the image with the destination — the literal
        // reading, and the only one of the three messages for which it is.
        let rop = blitROP ?? SpiceROP.descriptor(
            operation.rop, source: .source, destination: .destination
        )
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
                    guard mask?.allows(x, y) ?? true else { continue }
                    let sourceX = Int(area.left) + (x - Int(box.left)) * Int(area.width)
                        / Int(box.width)
                    guard sourceX >= 0, sourceX < source.width else { continue }

                    let from = (sourceY * source.width + sourceX) * bytesPerSourcePixel
                    let to = (y * surface.width + x) * 4
                    for channel in 0..<3 {
                        surface.pixels[to + channel] = rop.apply(
                            source: source.pixels[from + channel],
                            destination: surface.pixels[to + channel]
                        )
                    }
                    surface.pixels[to + 3] = surface.hasAlpha && bytesPerSourcePixel == 4
                        ? rop.apply(
                            source: source.pixels[from + 3], destination: surface.pixels[to + 3]
                        )
                        : 0
                }
            }
        }
        surfaces[operation.base.surfaceID] = surface
        return written
    }

    // MARK: - The mask every draw carries

    /// A draw's mask, resolved against its box.
    ///
    /// `nil` for the common case of no mask at all. A mask that exists but
    /// cannot be used — one naming a cached image, another surface, or a format
    /// that is not 1-bit — becomes `notDrawable`, which leaves that part of the
    /// screen alone rather than dropping the connection.
    ///
    /// This used to refuse *every* masked draw, and before that `fill` used to
    /// ignore the mask and paint its whole box. Both were wrong in opposite
    /// directions: painting everything destroys pixels the server wanted kept,
    /// painting nothing leaves pixels stale, and the server resends neither.
    static func mask(
        _ mask: SpiceDisplayWire.Mask, box: SpiceDisplayWire.Rect
    ) throws -> SpiceMask.Resolved? {
        do {
            return try SpiceMask.resolve(mask, box: box)
        } catch {
            throw Failure.notDrawable
        }
    }

    /// `DRAW_OPAQUE` — the image, then the brush combined onto it.
    ///
    /// **The order is the whole message.** The reference blits the image with
    /// no raster operation at all and only then calls `draw_brush` with one, so
    /// what the rop combines is the brush with the *image* — the destination
    /// has already been overwritten and is not an operand. That is why the rop
    /// is resolved with `.brush` as its source and `.source` as its
    /// destination, which reads backwards until you know the order.
    ///
    /// Implemented as exactly that composition rather than as a fused loop:
    /// a plain copy, then the shared solid paint. Fusing them would save one
    /// pass over the region and would make the order an implementation detail
    /// instead of the thing the message says.
    @discardableResult
    mutating func opaque(
        _ operation: SpiceDisplayWire.Opaque,
        source: (pixels: [UInt8], width: Int, height: Int),
        bytesPerSourcePixel: Int
    ) throws -> [SpiceDisplayWire.Rect] {
        guard case let .solid(colour) = operation.brush else {
            // A pattern brush, or none at all. `fill` refuses the same two.
            throw Failure.notDrawable
        }

        // The descriptor is carried through unchanged and then *overridden*,
        // rather than replaced with a zero that would collapse to `copy` on its
        // own. Two ways of saying the same thing is one too many: with a zero
        // there, `blitROP` could be deleted and nothing would notice, and the
        // fact that this blit ignores the rop would stop being written down
        // anywhere.
        let written = try copy(
            SpiceDisplayWire.Copy(
                base: operation.base, source: operation.source,
                sourceArea: operation.sourceArea, rop: operation.rop,
                scaleMode: operation.scaleMode, mask: operation.mask
            ),
            source: source, bytesPerSourcePixel: bytesPerSourcePixel,
            blitROP: .copy
        )
        guard var surface = surfaces[operation.base.surfaceID] else {
            throw Failure.unknownSurface(operation.base.surfaceID)
        }
        Self.paint(
            colour,
            rop: SpiceROP.descriptor(operation.rop, source: .brush, destination: .source),
            over: written,
            mask: try Self.mask(operation.mask, box: operation.base.box),
            into: &surface
        )
        surfaces[operation.base.surfaceID] = surface
        return written
    }

    /// `DRAW_TRANSPARENT` — every pixel except the ones matching a colour.
    ///
    /// The simplest compositing there is: one colour in the image means "leave
    /// what is underneath", every other pixel is copied. It is how a cursor or
    /// an icon with a hard-edged silhouette gets drawn without an alpha
    /// channel, and it was being counted as ignored.
    ///
    /// Three details, all from `spice_pixman_blit_colorkey`:
    ///
    ///   * **the comparison is on twenty-four bits.** The key arrives as a
    ///     32-bit word and the reference masks it with `0xffffff` before the
    ///     loop, then compares `0xffffff & pixel`. Comparing all thirty-two
    ///     would make the key never match on a source whose fourth byte is not
    ///     zero — which is most of them;
    ///   * **there is no mask and no rop.** Unlike every other draw with an
    ///     image in it, this message carries neither, and `canvas_draw_transparent`
    ///     calls neither `canvas_mask_pixman` nor `ropd_descriptor_to_rop`;
    ///   * **`src_color` is never read.** It is in the message and the reference
    ///     uses `true_color` for the key. Reading the wrong one of the two gives
    ///     a picture with the wrong holes in it.
    @discardableResult
    mutating func transparent(
        _ operation: SpiceDisplayWire.Transparent,
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

        // The key is an xRGB word, so it lands as blue, green, red — the same
        // order a fill's colour does.
        let keyBlue = UInt8(operation.trueColour & 0xFF)
        let keyGreen = UInt8(operation.trueColour >> 8 & 0xFF)
        let keyRed = UInt8(operation.trueColour >> 16 & 0xFF)

        let written = Self.regions(of: operation.base, in: surface)
        for rect in written {
            for y in Int(rect.top)..<Int(rect.bottom) {
                let sourceY = Int(area.top) + (y - Int(box.top)) * Int(area.height)
                    / Int(box.height)
                guard sourceY >= 0, sourceY < source.height else { continue }

                for x in Int(rect.left)..<Int(rect.right) {
                    let sourceX = Int(area.left) + (x - Int(box.left)) * Int(area.width)
                        / Int(box.width)
                    guard sourceX >= 0, sourceX < source.width else { continue }

                    let from = (sourceY * source.width + sourceX) * bytesPerSourcePixel
                    guard source.pixels[from] != keyBlue
                        || source.pixels[from + 1] != keyGreen
                        || source.pixels[from + 2] != keyRed else { continue }

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

    /// pixman's eight-bit multiply, `MUL_UN8`.
    ///
    /// `a · b / 255`, rounded the way pixman rounds it: add a half, then fold
    /// the carry back in. The obvious `(a * b) / 255` and the cheap
    /// `(a * b) >> 8` both disagree with it on real inputs, and the whole point
    /// of this file is to produce what the reference produces.
    static func multiply(_ lhs: UInt8, _ rhs: UInt8) -> UInt8 {
        let product = UInt32(lhs) * UInt32(rhs) + 0x80
        return UInt8(truncatingIfNeeded: (product + (product >> 8)) >> 8)
    }

    /// `DRAW_ALPHA_BLEND` — source-over, on premultiplied alpha.
    ///
    /// The only draw on this channel that really composites. `__blend_image`
    /// builds a solid mask whose alpha is the message's overall alpha — and
    /// only when that is not `0xff` — then calls `pixman_image_composite32`
    /// with `PIXMAN_OP_OVER`. So the arithmetic is pixman's, not SPICE's:
    ///
    ///     s' = src · overall
    ///     out = s' + dst · (1 − s'ₐ)
    ///
    /// **The source is premultiplied**, and nothing in SPICE says so. There is
    /// no mention of it in the protocol or in `canvas_base.c`, and nothing
    /// anywhere divides by alpha: `SPICE_BITMAP_FMT_RGBA` maps to
    /// `PIXMAN_a8r8g8b8` and pixman's `OVER` is defined on premultiplied
    /// source. Premultiplied is therefore what the pipeline *means* rather than
    /// what anyone wrote down, and reading it the other way produces halos —
    /// a picture, and a wrong one.
    ///
    /// That claim is measured rather than argued. `scripts/spice-alpha-blend/`
    /// runs this formula and pixman itself over 43,008,000 combinations of
    /// source, destination, both alphas and the flag; they agree on every one.
    ///
    /// Two details from the same reading:
    ///
    ///   * **an overall alpha of zero draws nothing at all**, and the reference
    ///     returns before it even looks at the region;
    ///   * **`DEST_HAS_ALPHA` decides whether the destination's fourth byte is
    ///     its alpha.** Clear, pixman is handed an `x8r8g8b8` destination whose
    ///     alpha is implicitly one. `SRC_SURFACE_HAS_ALPHA` is not read here:
    ///     the reference passes it only on the surface-to-surface path.
    @discardableResult
    mutating func alphaBlend(
        _ operation: SpiceDisplayWire.AlphaBlend,
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
        // Nothing to do, and nothing to report: an alpha of zero contributes no
        // pixels, so a renderer has no reason to re-upload the rectangle.
        guard operation.alpha != 0 else { return [] }

        let box = operation.base.box
        let area = operation.sourceArea
        guard area.width > 0, area.height > 0, box.width > 0, box.height > 0 else { return [] }
        let overall = operation.alpha
        let readsDestinationAlpha = operation.readsDestinationAlpha

        let written = Self.regions(of: operation.base, in: surface)
        for rect in written {
            for y in Int(rect.top)..<Int(rect.bottom) {
                let sourceY = Int(area.top) + (y - Int(box.top)) * Int(area.height)
                    / Int(box.height)
                guard sourceY >= 0, sourceY < source.height else { continue }

                for x in Int(rect.left)..<Int(rect.right) {
                    let sourceX = Int(area.left) + (x - Int(box.left)) * Int(area.width)
                        / Int(box.width)
                    guard sourceX >= 0, sourceX < source.width else { continue }

                    let from = (sourceY * source.width + sourceX) * bytesPerSourcePixel
                    let to = (y * surface.width + x) * 4
                    // A three-byte source has no alpha of its own, so it is
                    // opaque — which is what pixman sees when it is handed an
                    // `x8r8g8b8` image.
                    let sourceAlpha = bytesPerSourcePixel == 4 ? source.pixels[from + 3] : 0xFF
                    let scaledAlpha = Self.multiply(sourceAlpha, overall)
                    let keep = 0xFF - scaledAlpha

                    for channel in 0..<3 {
                        let scaled = Self.multiply(source.pixels[from + channel], overall)
                        surface.pixels[to + channel] = scaled
                            &+ Self.multiply(surface.pixels[to + channel], keep)
                    }
                    if surface.hasAlpha {
                        let destinationAlpha = readsDestinationAlpha
                            ? surface.pixels[to + 3] : 0xFF
                        surface.pixels[to + 3] = scaledAlpha
                            &+ Self.multiply(destinationAlpha, keep)
                    } else {
                        // `clear_dest_alpha` in the reference, and this file's
                        // standing rule: an xRGB surface's fourth byte is zero.
                        surface.pixels[to + 3] = 0
                    }
                }
            }
        }
        surfaces[operation.base.surfaceID] = surface
        return written
    }

    /// `DRAW_ROP3` — the general case.
    ///
    /// Pattern, source and destination through one of 256 boolean functions.
    /// The pattern operand is the brush; a pattern *brush* — an image tiled
    /// across the box — is refused, the same refusal `fill` and `opaque` make,
    /// so what reaches the table is a solid colour.
    ///
    /// The reference builds the destination into a temporary image, composites
    /// into it and blits it back. This works in place instead, which is safe
    /// for a reason worth stating: every output pixel depends only on the input
    /// pixels at *its own* coordinate, so unlike `copyBits` there is no overlap
    /// to snapshot around.
    @discardableResult
    mutating func rop3(
        _ operation: SpiceDisplayWire.Rop3,
        source: (pixels: [UInt8], width: Int, height: Int),
        bytesPerSourcePixel: Int
    ) throws -> [SpiceDisplayWire.Rect] {
        guard var surface = surfaces[operation.base.surfaceID] else {
            throw Failure.unknownSurface(operation.base.surfaceID)
        }
        guard case let .solid(colour) = operation.brush else { throw Failure.notDrawable }
        guard bytesPerSourcePixel == 3 || bytesPerSourcePixel == 4 else {
            throw Failure.notDrawable
        }
        guard source.pixels.count >= source.width * source.height * bytesPerSourcePixel else {
            throw Failure.notDrawable
        }
        let mask = try Self.mask(operation.mask, box: operation.base.box)

        let box = operation.base.box
        let area = operation.sourceArea
        guard area.width > 0, area.height > 0, box.width > 0, box.height > 0 else { return [] }

        let table = SpiceROP3(operation.rop3)
        let pattern = [
            UInt8(colour & 0xFF), UInt8(colour >> 8 & 0xFF),
            UInt8(colour >> 16 & 0xFF), UInt8(colour >> 24 & 0xFF),
        ]

        let written = Self.regions(of: operation.base, in: surface)
        for rect in written {
            for y in Int(rect.top)..<Int(rect.bottom) {
                let sourceY = Int(area.top) + (y - Int(box.top)) * Int(area.height)
                    / Int(box.height)
                guard sourceY >= 0, sourceY < source.height else { continue }

                for x in Int(rect.left)..<Int(rect.right) {
                    guard mask?.allows(x, y) ?? true else { continue }
                    let sourceX = Int(area.left) + (x - Int(box.left)) * Int(area.width)
                        / Int(box.width)
                    guard sourceX >= 0, sourceX < source.width else { continue }

                    let from = (sourceY * source.width + sourceX) * bytesPerSourcePixel
                    let to = (y * surface.width + x) * 4
                    for channel in 0..<3 {
                        surface.pixels[to + channel] = table.apply(
                            pattern: pattern[channel],
                            source: source.pixels[from + channel],
                            destination: surface.pixels[to + channel]
                        )
                    }
                    surface.pixels[to + 3] = surface.hasAlpha
                        ? table.apply(
                            pattern: pattern[3],
                            source: bytesPerSourcePixel == 4 ? source.pixels[from + 3] : 0xFF,
                            destination: surface.pixels[to + 3]
                        )
                        : 0
                }
            }
        }
        surfaces[operation.base.surfaceID] = surface
        return written
    }

    // MARK: - The draws that need no codec

    /// `DRAW_COPY_BITS` — the surface copying from itself.
    ///
    /// Two things make it more than a loop.
    ///
    /// The first is **the source has to be clipped too.** The clip and the box
    /// bound where pixels are written; nothing in them bounds where they are
    /// read, and a scroll near an edge names a source row outside the surface.
    /// The reference does it by intersecting the destination region with a
    /// rectangle offset by the distance — `pixman_region32_init_rect(&src, dx,
    /// dy, width, height)` — which is the same as saying the destination must
    /// stay inside the surface once shifted back. That is the `shifted`
    /// rectangle below, and it is not the same as clamping each read: clamping
    /// would duplicate the edge row instead of leaving it alone.
    ///
    /// The second is **the copy overlaps itself.** A window scrolling by ten
    /// pixels reads rows it has just written. `spice_pixman_copy_rect` picks a
    /// direction per rectangle — rows bottom-to-top going down, top-to-bottom
    /// going up, `memmove` within a row — and `copy_region` orders the
    /// rectangles to match. This reads the whole source out first instead. The
    /// result is identical, because the reference's ordering exists precisely
    /// to imitate a snapshot without allocating one; what it costs is the
    /// region's area in bytes, on a copy that was already going to touch it.
    @discardableResult
    mutating func copyBits(
        _ operation: SpiceDisplayWire.CopyBits
    ) throws -> [SpiceDisplayWire.Rect] {
        guard var surface = surfaces[operation.base.surfaceID] else {
            throw Failure.unknownSurface(operation.base.surfaceID)
        }

        let dx = Int(operation.base.box.left) - Int(operation.source.x)
        let dy = Int(operation.base.box.top) - Int(operation.source.y)
        // No distance, no copy. The reference returns without touching the
        // surface, and it matters: with dx and dy both zero every pixel would
        // be copied onto itself, which is work with no effect — but it would
        // also be *reported* as a region drawn, and a renderer would repaint
        // for nothing.
        guard dx != 0 || dy != 0 else { return [] }

        let shifted = SpiceDisplayWire.Rect(
            top: Int32(clamping: dy), left: Int32(clamping: dx),
            bottom: Int32(clamping: dy + surface.height),
            right: Int32(clamping: dx + surface.width)
        )
        let written = Self.regions(of: operation.base, in: surface)
            .compactMap { Self.intersect($0, shifted) }
        guard !written.isEmpty else { return [] }

        // The snapshot, one rectangle at a time and in the destination's
        // coordinates, so the write below needs no arithmetic of its own.
        var snapshots: [[UInt8]] = []
        snapshots.reserveCapacity(written.count)
        for rect in written {
            var pixels = [UInt8]()
            pixels.reserveCapacity(Int(rect.width) * Int(rect.height) * 4)
            for y in Int(rect.top)..<Int(rect.bottom) {
                let row = (y - dy) * surface.width
                let from = (row + Int(rect.left) - dx) * 4
                pixels += surface.pixels[from..<(from + Int(rect.width) * 4)]
            }
            snapshots.append(pixels)
        }

        for (rect, pixels) in zip(written, snapshots) {
            let rowBytes = Int(rect.width) * 4
            for y in Int(rect.top)..<Int(rect.bottom) {
                let to = (y * surface.width + Int(rect.left)) * 4
                let start = (y - Int(rect.top)) * rowBytes
                surface.pixels.replaceSubrange(
                    to..<(to + rowBytes), with: pixels[start..<(start + rowBytes)]
                )
            }
        }
        surfaces[operation.base.surfaceID] = surface
        return written
    }

    /// `DRAW_BLACKNESS`, `DRAW_WHITENESS` and `DRAW_INVERS`.
    ///
    /// The three raster operations with no operand. The reference reaches them
    /// through the same path as a fill and then hands `fill_solid_rects` the
    /// colour — `0x000000`, `0xffffffff` — or `fill_solid_rects_rop` with
    /// `SPICE_ROP_INVERT`.
    ///
    /// **The two constants are not typos of each other**, and the difference is
    /// the whole of what the fourth byte does. Blackness passes `0x000000` and
    /// whiteness `0xffffffff`, so on a surface that has alpha, blackness makes
    /// the region fully transparent and whiteness fully opaque. Invers is a rop
    /// over the whole 32-bit word, so it complements the alpha along with the
    /// colour.
    ///
    /// That asymmetry looks like a bug in the reference and is not one to
    /// paper over: writing `0xff000000` for blackness would be *changing* the
    /// protocol's behaviour on argb32 surfaces to something more sensible, and
    /// the server draws expecting the other. On a surface without alpha the
    /// fourth byte is held at zero regardless, which is the rule `fill`
    /// already follows.
    @discardableResult
    mutating func raster(
        _ operation: SpiceDisplayWire.MaskedRaster
    ) throws -> [SpiceDisplayWire.Rect] {
        guard var surface = surfaces[operation.base.surfaceID] else {
            throw Failure.unknownSurface(operation.base.surfaceID)
        }
        let mask = try Self.mask(operation.mask, box: operation.base.box)

        let written = Self.regions(of: operation.base, in: surface)
        for rect in written {
            for y in Int(rect.top)..<Int(rect.bottom) {
                var index = (y * surface.width + Int(rect.left)) * 4
                for x in Int(rect.left)..<Int(rect.right) {
                    defer { index += 4 }
                    guard mask?.allows(x, y) ?? true else { continue }
                    switch operation.operation {
                    case .blackness:
                        surface.pixels[index] = 0
                        surface.pixels[index + 1] = 0
                        surface.pixels[index + 2] = 0
                    case .whiteness:
                        surface.pixels[index] = 0xFF
                        surface.pixels[index + 1] = 0xFF
                        surface.pixels[index + 2] = 0xFF
                    case .invers:
                        surface.pixels[index] = ~surface.pixels[index]
                        surface.pixels[index + 1] = ~surface.pixels[index + 1]
                        surface.pixels[index + 2] = ~surface.pixels[index + 2]
                    }
                    if surface.hasAlpha {
                        switch operation.operation {
                        case .blackness: surface.pixels[index + 3] = 0x00
                        case .whiteness: surface.pixels[index + 3] = 0xFF
                        case .invers: surface.pixels[index + 3] = ~surface.pixels[index + 3]
                        }
                    } else {
                        surface.pixels[index + 3] = 0
                    }
                }
            }
        }
        surfaces[operation.base.surfaceID] = surface
        return written
    }
}
