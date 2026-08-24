import Foundation

/// Decoding for the display channel's messages.
///
/// Kept apart from the type definitions next door because this is where the
/// judgement is: every function below reads bytes chosen by a server, and the
/// interesting part of each is what it refuses.
extension SpiceDisplayWire {
    /// A message body, and the pointer rule that goes with it.
    ///
    /// SPICE draw messages do not carry their operands inline. They carry a
    /// `uint32` offset from the start of the body, and the operand sits
    /// somewhere else in the same body — usually after the fixed part, but the
    /// protocol does not promise that and a server is free to lay it out any
    /// way it likes. So a body is addressed, not streamed.
    ///
    /// Which makes it a place where a malicious or broken server gets to choose
    /// where this code reads. The rules come from the demarshaller the protocol
    /// generates for itself: null is zero, anything at or past the end is an
    /// error.
    ///
    /// The refusal to follow an offset already on the current path is an
    /// addition, and an honest note about it: no path through this decoder can
    /// cycle today, because an image follows no further pointer and the depth
    /// is at most two. It is here for the messages not decoded yet —
    /// `DRAW_ROP3` and `DRAW_OPAQUE` nest brushes and masks that each carry an
    /// image — where a server could otherwise hand this a structure that
    /// contains itself. The test exercises `follow` directly, because a test
    /// built from a crafted message agreed with the guarded code for an
    /// unrelated reason and proved nothing.
    struct Body {
        let bytes: [UInt8]
        /// Offsets on the path from the message root to where we are now.
        private var following: Set<Int> = []

        init(_ bytes: [UInt8]) { self.bytes = bytes }

        func reader(at offset: Int = 0) throws -> SpiceWire.Reader {
            try SpiceWire.Reader(bytes, from: offset)
        }

        /// Resolves a pointer field, or reports that it was null.
        ///
        /// Returns `nil` for a null pointer, which is a normal thing for a
        /// server to send — a fill has no mask, a copy names a cached image —
        /// and is why this is an optional rather than a throw.
        func follow(_ pointer: UInt32) throws -> (reader: SpiceWire.Reader, body: Body)? {
            guard pointer != 0 else { return nil }

            let offset = Int(pointer)
            guard offset < bytes.count else { throw SpiceError.truncated }
            guard !following.contains(offset) else { throw SpiceError.invalidData }

            var nested = self
            nested.following.insert(offset)
            return (try nested.reader(at: offset), nested)
        }
    }

    // MARK: - Geometry

    static func rect(from reader: inout SpiceWire.Reader) throws -> Rect {
        // top, left, bottom, right — the protocol's order, not the usual one.
        Rect(
            top: Int32(bitPattern: try reader.u32()),
            left: Int32(bitPattern: try reader.u32()),
            bottom: Int32(bitPattern: try reader.u32()),
            right: Int32(bitPattern: try reader.u32())
        )
    }

    static func point(from reader: inout SpiceWire.Reader) throws -> Point {
        Point(
            x: Int32(bitPattern: try reader.u32()),
            y: Int32(bitPattern: try reader.u32())
        )
    }

    /// The clip is inline rather than behind a pointer — `@to_ptr` in the
    /// protocol description means the *C struct* holds a pointer, not that the
    /// wire does. Reading it as a pointer would consume four bytes and then
    /// treat a rectangle count as an offset.
    static func clip(from reader: inout SpiceWire.Reader) throws -> Clip {
        switch try reader.u8() {
        case 0:
            return .none
        case 1:
            let count = try reader.u32()
            // Appended one at a time, with no capacity reserved from `count`.
            //
            // That is the whole defence, and it is why there is no bound here.
            // A bound was written — `count` against the bytes remaining — and a
            // sabotage showed it did nothing: the array grows only as reads
            // succeed, and a read past the end throws, so a count of four
            // billion ends on the first iteration either way. The same thing
            // happened with the channel list, where the real hazard was `map`
            // reserving from an untrusted count. Reserve nothing and there is
            // nothing to bound.
            var rects: [Rect] = []
            for _ in 0..<count { rects.append(try rect(from: &reader)) }
            return .rects(rects)
        case let other:
            // `PATH` was type 2 and was removed from the protocol. Treating an
            // unknown clip as "no clip" would draw over the parts of the screen
            // the server asked to be left alone.
            _ = other
            throw SpiceError.invalidData
        }
    }

    static func base(from reader: inout SpiceWire.Reader) throws -> Base {
        Base(
            surfaceID: try reader.u32(),
            box: try rect(from: &reader),
            clip: try clip(from: &reader)
        )
    }

    // MARK: - Whole messages

    static func mode(_ payload: [UInt8]) throws -> Mode {
        var reader = try SpiceWire.Reader(payload, from: 0)
        return Mode(width: try reader.u32(), height: try reader.u32(), bits: try reader.u32())
    }

    static func surfaceCreate(_ payload: [UInt8]) throws -> SurfaceCreate {
        var reader = try SpiceWire.Reader(payload, from: 0)
        let surfaceID = try reader.u32()
        let width = try reader.u32()
        let height = try reader.u32()
        let rawFormat = try reader.u32()
        guard let format = SurfaceFormat(rawValue: rawFormat) else {
            // A format this client cannot lay out is named rather than guessed
            // at: guessing means every pixel afterwards is wrong, and wrong in
            // a way that still fills the screen with something.
            throw SpiceError.invalidData
        }
        return SurfaceCreate(
            surfaceID: surfaceID, width: width, height: height,
            format: format, flags: try reader.u32()
        )
    }

    static func surfaceDestroy(_ payload: [UInt8]) throws -> UInt32 {
        var reader = try SpiceWire.Reader(payload, from: 0)
        return try reader.u32()
    }

    // MARK: - Images

    static func image(at pointer: UInt32, in body: Body) throws -> Image? {
        guard let (found, nested) = try body.follow(pointer) else { return nil }
        var reader = found

        let id = try reader.u64()
        let rawType = try reader.u8()
        guard let type = ImageType(rawValue: rawType) else { throw SpiceError.invalidData }
        let descriptor = ImageDescriptor(
            id: id,
            type: type,
            flags: try reader.u8(),
            width: try reader.u32(),
            height: try reader.u32()
        )

        // Only the uncompressed case has a shape this decoder can state. The
        // rest are named and left alone rather than half-read: a QUIC or LZ
        // payload's own header is part of its codec, and reading fields out of
        // it here would be inventing a layout.
        guard type == .bitmap else {
            _ = nested
            return Image(descriptor: descriptor, bitmap: nil)
        }

        let rawFormat = try reader.u8()
        guard let format = BitmapFormat(rawValue: rawFormat) else { throw SpiceError.invalidData }
        let flags = try reader.u8()
        let width = try reader.u32()
        let height = try reader.u32()
        let stride = try reader.u32()

        // `PAL_FROM_CACHE` is bit 1. When it is set the palette is an
        // identifier; otherwise it is a pointer, which is not followed here
        // because nothing yet paints palettised bitmaps.
        let paletteFromCache = flags & 0x02 != 0
        let cachedPaletteID = paletteFromCache ? try reader.u64() : nil
        if !paletteFromCache { _ = try reader.u32() }

        return Image(
            descriptor: descriptor,
            bitmap: Bitmap(
                format: format, flags: flags, width: width, height: height,
                stride: stride, cachedPaletteID: cachedPaletteID
            )
        )
    }

    static func brush(from reader: inout SpiceWire.Reader, in body: Body) throws -> Brush {
        switch try reader.u8() {
        case 0:
            return .none
        case 1:
            return .solid(try reader.u32())
        case 2:
            let pointer = try reader.u32()
            return .pattern(image: try image(at: pointer, in: body),
                            origin: try point(from: &reader))
        default:
            throw SpiceError.invalidData
        }
    }

    static func mask(from reader: inout SpiceWire.Reader, in body: Body) throws -> Mask {
        let flags = try reader.u8()
        let origin = try point(from: &reader)
        let pointer = try reader.u32()
        return Mask(flags: flags, origin: origin, bitmap: try image(at: pointer, in: body))
    }

    // MARK: - Draw messages

    static func fill(_ payload: [UInt8]) throws -> Fill {
        let body = Body(payload)
        var reader = try body.reader()
        return Fill(
            base: try base(from: &reader),
            brush: try brush(from: &reader, in: body),
            rop: try reader.u16(),
            mask: try mask(from: &reader, in: body)
        )
    }

    static func copy(_ payload: [UInt8]) throws -> Copy {
        let body = Body(payload)
        var reader = try body.reader()
        let header = try base(from: &reader)
        let sourcePointer = try reader.u32()
        return Copy(
            base: header,
            source: try image(at: sourcePointer, in: body),
            sourceArea: try rect(from: &reader),
            rop: try reader.u16(),
            scaleMode: try reader.u8(),
            mask: try mask(from: &reader, in: body)
        )
    }
}
