import Foundation
import WisqNet
import XCTest
@testable import WisqRemote

/// The display channel driven against a scripted server.
///
/// No socket: `MemoryByteStream` is what the server says and what the client
/// said back, which is how the ordering rules below can be asserted rather than
/// hoped for. The same shape the link and handshake tests use.
final class SpiceDisplayChannelTests: XCTestCase {
    /// `STREAM_ACTIVATE_REPORT`, by its raw number because there is no case for
    /// it. A message that draws nothing and that this client will therefore
    /// never implement — which is the only kind that can safely stand for
    /// "ignored" in a test. Every draw used here before it eventually got
    /// implemented and broke the test that named it.
    private static let permanentlyIgnored: UInt16 = 319

    private func u32(_ value: UInt32) -> [UInt8] { (0..<4).map { UInt8(value >> (8 * $0) & 0xFF) } }
    private func i32(_ value: Int32) -> [UInt8] { u32(UInt32(bitPattern: value)) }
    private func u16(_ value: UInt16) -> [UInt8] { (0..<2).map { UInt8(value >> (8 * $0) & 0xFF) } }
    private func u64(_ value: UInt64) -> [UInt8] { (0..<8).map { UInt8(value >> (8 * $0) & 0xFF) } }

    /// A server message, framed the way the protocol frames one.
    private func message(_ type: UInt16, _ payload: [UInt8], serial: UInt64 = 1) -> Data {
        SpiceWire.message(type, serial: serial, payload: Data(payload))
    }

    private func surfaceCreate(id: UInt32 = 0, _ width: UInt32, _ height: UInt32) -> Data {
        message(
            SpiceDisplayWire.Message.surfaceCreate.rawValue,
            u32(id) + u32(width) + u32(height) + u32(32) + u32(0)
        )
    }

    /// A `DRAW_FILL` of one colour over a box, with no clip and no mask.
    private func fill(
        surface: UInt32 = 0, _ top: Int32, _ left: Int32, _ bottom: Int32, _ right: Int32,
        colour: UInt32
    ) -> Data {
        var body = u32(surface)
        body += i32(top) + i32(left) + i32(bottom) + i32(right)
        body += [0]                                    // no clip
        body += [1] + u32(colour)                      // solid brush
        body += [0, 0]                                 // rop
        body += [0] + i32(0) + i32(0) + u32(0)         // mask
        return message(SpiceDisplayWire.Message.drawFill.rawValue, body)
    }

    /// `DRAW_COPY_BITS`: the base, then two words that are a point.
    private func copyBits(
        surface: UInt32 = 0, _ top: Int32, _ left: Int32, _ bottom: Int32, _ right: Int32,
        from source: SpiceDisplayWire.Point
    ) -> Data {
        var body = u32(surface)
        body += i32(top) + i32(left) + i32(bottom) + i32(right)
        body += [0]                                    // no clip
        body += i32(source.x) + i32(source.y)
        return message(SpiceDisplayWire.Message.copyBits.rawValue, body)
    }

    /// One of the three operand-free rasters: the base, then a null mask.
    private func raster(
        _ type: UInt16, surface: UInt32 = 0,
        _ top: Int32, _ left: Int32, _ bottom: Int32, _ right: Int32
    ) -> Data {
        var body = u32(surface)
        body += i32(top) + i32(left) + i32(bottom) + i32(right)
        body += [0]                                    // no clip
        body += [0] + i32(0) + i32(0) + u32(0)         // mask
        return message(type, body)
    }

    /// A draw whose source is an inline uncompressed bitmap of one colour.
    ///
    /// Shared by the copy, blend and opaque tests because the only thing that
    /// differs between them is the message number and, for opaque, one extra
    /// brush before the rop.
    private func drawFromBitmap(_ type: UInt16, colour: UInt32, brush: UInt32? = nil) -> Data {
        let width = 4, height = 2
        var image = u32(1) + u32(0)                    // image id
        image += [0, 0]                                // type: bitmap, flags
        image += u32(UInt32(width)) + u32(UInt32(height))
        image += [8, 0x04]                             // 32-bit, TOP_DOWN
        image += u32(UInt32(width)) + u32(UInt32(height)) + u32(UInt32(width * 4))
        image += u32(0)                                // palette: null
        for _ in 0..<(width * height) { image += u32(colour) }

        var body = u32(0)                                                  // surface
        body += i32(0) + i32(0) + i32(Int32(height)) + i32(Int32(width))   // box
        body += [0]                                                        // clip: none
        // The image sits after the fixed part, and the pointer is an offset
        // from the start of the body.
        let fixed = 4 + 16 + 1 + 4 + 16 + (brush == nil ? 0 : 5) + 2 + 1 + 13
        body += u32(UInt32(fixed))                                         // src_bitmap
        body += i32(0) + i32(0) + i32(Int32(height)) + i32(Int32(width))   // src_area
        if let brush { body += [1] + u32(brush) }
        body += [0, 0]                                                     // rop
        body += [0]                                                        // scale mode
        body += [0] + i32(0) + i32(0) + u32(0)                             // mask
        return message(type, body + image)
    }

    /// `DRAW_TRANSPARENT`: base, image, area, and two colour words — no rop, no
    /// scale mode and no mask, unlike every other draw that carries an image.
    private func transparentDraw(colour: UInt32, key: UInt32) -> Data {
        let width = 4, height = 2
        var image = u32(1) + u32(0)
        image += [0, 0]
        image += u32(UInt32(width)) + u32(UInt32(height))
        image += [8, 0x04]
        image += u32(UInt32(width)) + u32(UInt32(height)) + u32(UInt32(width * 4))
        image += u32(0)
        for _ in 0..<(width * height) { image += u32(colour) }

        var body = u32(0)
        body += i32(0) + i32(0) + i32(Int32(height)) + i32(Int32(width))
        body += [0]
        let fixed = 4 + 16 + 1 + 4 + 16 + 4 + 4
        body += u32(UInt32(fixed))
        body += i32(0) + i32(0) + i32(Int32(height)) + i32(Int32(width))
        body += u32(0) + u32(key)
        return message(SpiceDisplayWire.Message.drawTransparent.rawValue, body + image)
    }

    /// `DRAW_ALPHA_BLEND`: base, then a flags byte and an alpha byte, and only
    /// then the image pointer.
    private func alphaBlendDraw(colour: UInt32, alpha: UInt8) -> Data {
        let width = 4, height = 2
        var image = u32(1) + u32(0)
        image += [0, 0]
        image += u32(UInt32(width)) + u32(UInt32(height))
        image += [9, 0x04]                             // RGBA, TOP_DOWN
        image += u32(UInt32(width)) + u32(UInt32(height)) + u32(UInt32(width * 4))
        image += u32(0)
        for _ in 0..<(width * height) { image += u32(colour) }

        var body = u32(0)
        body += i32(0) + i32(0) + i32(Int32(height)) + i32(Int32(width))
        body += [0]
        body += [0, alpha]
        let fixed = 4 + 16 + 1 + 2 + 4 + 16
        body += u32(UInt32(fixed))
        body += i32(0) + i32(0) + i32(Int32(height)) + i32(Int32(width))
        return message(SpiceDisplayWire.Message.drawAlphaBlend.rawValue, body + image)
    }

    /// `DRAW_ROP3`: opaque's shape with a one-byte opcode where the two-byte
    /// rop descriptor was.
    private func rop3Draw(colour: UInt32, opcode: UInt8) -> Data {
        let width = 4, height = 2
        var image = u32(1) + u32(0)
        image += [0, 0]
        image += u32(UInt32(width)) + u32(UInt32(height))
        image += [8, 0x04]
        image += u32(UInt32(width)) + u32(UInt32(height)) + u32(UInt32(width * 4))
        image += u32(0)
        for _ in 0..<(width * height) { image += u32(colour) }

        var body = u32(0)
        body += i32(0) + i32(0) + i32(Int32(height)) + i32(Int32(width))
        body += [0]
        let fixed = 4 + 16 + 1 + 4 + 16 + 5 + 1 + 1 + 13
        body += u32(UInt32(fixed))
        body += i32(0) + i32(0) + i32(Int32(height)) + i32(Int32(width))
        body += [1] + u32(0x0000_00FF)                 // solid brush
        body += [opcode]
        body += [0]                                    // scale mode
        body += [0] + i32(0) + i32(0) + u32(0)         // mask
        return message(SpiceDisplayWire.Message.drawRop3.rawValue, body + image)
    }

    private func capabilities(preferredCompression: Bool) -> [UInt32] {
        preferredCompression
            ? SpiceDisplayClient.capabilityWords([.preferredCompression])
            : []
    }

    // MARK: - What the client says first

    /// `INIT` before the preference, and that order is the protocol's rather
    /// than a taste: the server does not draw until `INIT` arrives, and a
    /// preference sent first can reach a server that has not yet decided this
    /// client exists.
    func testTheInitMessageIsSentBeforeTheCompressionPreference() async throws {
        let server = MemoryByteStream()
        let channel = SpiceDisplayChannel(stream: server)

        _ = try await channel.announce(serverCapabilities: capabilities(preferredCompression: true))

        var reader = SpiceWire.Reader(await server.written)
        let first = try SpiceWire.decodeDataHeader(Data(try reader.bytes(18)))
        XCTAssertEqual(first.type, SpiceDisplayClient.Message.initialise.rawValue)
        _ = try reader.bytes(Int(first.size))

        let second = try SpiceWire.decodeDataHeader(Data(try reader.bytes(18)))
        XCTAssertEqual(second.type, SpiceDisplayClient.Message.preferredCompression.rawValue)
        // Which encoding is asked for is decided and tested in
        // `SpiceDisplayClientTests`; what this test is about is that it comes
        // second. Taken from there rather than restated, so the two cannot
        // drift apart — they already did twice, when QUIC became decodable and
        // the request changed from `lz` to `autoLZ`, and again when the GLZ
        // window stopped being zero and it changed to `autoGLZ`.
        let wanted = try XCTUnwrap(
            SpiceDisplayClient.compressionToRequest(
                givenServerCapabilities: capabilities(preferredCompression: true)
            )
        )
        XCTAssertEqual(try reader.bytes(Int(second.size)), [wanted.rawValue])
    }

    /// A server that never said it would listen is not asked. The client still
    /// introduces itself.
    func testAServerThatCannotBeAskedGetsOnlyTheInitMessage() async throws {
        let server = MemoryByteStream()
        let channel = SpiceDisplayChannel(stream: server)

        _ = try await channel.announce(serverCapabilities: capabilities(preferredCompression: false))

        var reader = SpiceWire.Reader(await server.written)
        let first = try SpiceWire.decodeDataHeader(Data(try reader.bytes(18)))
        XCTAssertEqual(first.type, SpiceDisplayClient.Message.initialise.rawValue)
        _ = try reader.bytes(Int(first.size))
        XCTAssertEqual(reader.remaining, 0, "rien d'autre ne doit partir")
    }

    /// Serials are the client's to keep and a server acknowledging by serial is
    /// entitled to a sequence with no holes in it.
    func testTheSerialAdvancesOnceForEachMessageActuallySent() async throws {
        let asked = SpiceDisplayChannel(stream: MemoryByteStream())
        let notAsked = SpiceDisplayChannel(stream: MemoryByteStream())

        let after = try await asked.announce(
            serverCapabilities: capabilities(preferredCompression: true)
        )
        let afterOne = try await notAsked.announce(
            serverCapabilities: capabilities(preferredCompression: false)
        )
        XCTAssertEqual(after, 3, "deux messages envoyés depuis 1")
        XCTAssertEqual(afterOne, 2, "un seul")
    }

    // MARK: - Drawing what arrives

    func testASurfaceIsCreatedAndThenDrawnOn() async throws {
        let server = MemoryByteStream(
            inbound: surfaceCreate(8, 8) + fill(0, 0, 4, 4, colour: 0x00FF_0000)
        )
        let channel = SpiceDisplayChannel(stream: server)
        var surfaces = SpiceSurfaces()
        var caches = SpiceDisplayCaches()
        var streams = SpiceStreams()

        let progress = try await channel.pump(into: &surfaces, caches: &caches, streams: &streams, serial: 1, limit: 2)

        XCTAssertEqual(progress.updates, [
            SpiceDisplayChannel.Update(
                surfaceID: 0,
                regions: [SpiceDisplayWire.Rect(top: 0, left: 0, bottom: 4, right: 4)]
            ),
        ])
        XCTAssertEqual(surfaces.surfaces[0]?.width, 8)
        // Blue, green, red, pad — the fill's red, at the top-left.
        XCTAssertEqual(Array(surfaces.surfaces[0]!.pixels[0..<4]), [0, 0, 0xFF, 0])
    }

    /// The four messages that need no codec, driven through the pump.
    ///
    /// The surface work is tested next door; what this pins is the routing —
    /// that these types reach a draw at all rather than being counted as
    /// ignored, which is what they were until now. A message with no `case` is
    /// silent, so only an assertion on `updates` notices.
    func testTheDrawsThatNeedNoCodecReachTheSurface() async throws {
        // Red across the top half, then scroll it down by four rows.
        let server = MemoryByteStream(
            inbound: surfaceCreate(8, 8)
                + fill(0, 0, 4, 8, colour: 0x00FF_0000)
                + copyBits(4, 0, 8, 8, from: SpiceDisplayWire.Point(x: 0, y: 0))
                + raster(SpiceDisplayWire.Message.drawWhiteness.rawValue, 0, 0, 2, 8)
                + raster(SpiceDisplayWire.Message.drawInvers.rawValue, 2, 0, 3, 8)
        )
        let channel = SpiceDisplayChannel(stream: server)
        var surfaces = SpiceSurfaces()
        var caches = SpiceDisplayCaches()
        var streams = SpiceStreams()

        let progress = try await channel.pump(into: &surfaces, caches: &caches, streams: &streams, serial: 1, limit: 5)

        XCTAssertEqual(progress.ignored, [:], "aucun de ces messages ne doit être compté ignoré")
        XCTAssertEqual(progress.updates.count, 4)

        func pixel(_ x: Int, _ y: Int) -> [UInt8] {
            let surface = surfaces.surfaces[0]!
            let at = (y * surface.width + x) * 4
            return Array(surface.pixels[at..<(at + 4)])
        }
        XCTAssertEqual(pixel(0, 5), [0, 0, 0xFF, 0], "le rouge a été descendu de quatre lignes")
        XCTAssertEqual(pixel(0, 1), [0xFF, 0xFF, 0xFF, 0], "blanc")
        // Row 2 was red, then inverted: 0x0000FF becomes 0xFFFF00.
        XCTAssertEqual(pixel(0, 2), [0xFF, 0xFF, 0, 0], "inversé")
    }

    /// `DRAW_BLEND` is `DRAW_COPY` under another number.
    ///
    /// Not "close enough to share a decoder": the reference wires them to the
    /// same function with the comment `// copy and blend are the same`, and the
    /// protocol gives blend copy's own C type. The test sends the identical
    /// body under both numbers and asserts the identical outcome — which is the
    /// claim, rather than that each one draws something.
    func testBlendIsCopyUnderAnotherNumber() async throws {
        func run(_ type: UInt16) async throws -> (SpiceDisplayChannel.Progress, [UInt8]) {
            let server = MemoryByteStream(
                inbound: surfaceCreate(4, 2) + drawFromBitmap(type, colour: 0x00FF_0000)
            )
            let channel = SpiceDisplayChannel(stream: server)
            var surfaces = SpiceSurfaces()
            var caches = SpiceDisplayCaches()
        var streams = SpiceStreams()
            let progress = try await channel.pump(
                into: &surfaces, caches: &caches, streams: &streams, serial: 1, limit: 2
            )
            return (progress, surfaces.surfaces[0]!.pixels)
        }

        let (copyProgress, copyPixels) = try await run(
            SpiceDisplayWire.Message.drawCopy.rawValue
        )
        let (blendProgress, blendPixels) = try await run(
            SpiceDisplayWire.Message.drawBlend.rawValue
        )
        XCTAssertEqual(copyProgress.ignored, [:])
        XCTAssertEqual(blendProgress.ignored, [:], "blend n'est pas un message ignoré")
        XCTAssertEqual(copyProgress.updates, blendProgress.updates)
        XCTAssertEqual(copyPixels, blendPixels)
        XCTAssertTrue(copyPixels.contains { $0 != 0 }, "sinon les deux ne dessinent rien")
    }

    /// `DRAW_OPAQUE` reaches a draw rather than being counted as ignored.
    func testOpaqueReachesTheSurface() async throws {
        let server = MemoryByteStream(
            inbound: surfaceCreate(4, 2)
                + drawFromBitmap(
                    SpiceDisplayWire.Message.drawOpaque.rawValue,
                    colour: 0x00FF_0000, brush: 0x0000_00FF
                )
        )
        let channel = SpiceDisplayChannel(stream: server)
        var surfaces = SpiceSurfaces()
        var caches = SpiceDisplayCaches()
        var streams = SpiceStreams()
        let progress = try await channel.pump(into: &surfaces, caches: &caches, streams: &streams, serial: 1, limit: 2)

        XCTAssertEqual(progress.ignored, [:])
        XCTAssertEqual(progress.updates.count, 1)
        // The image is blitted plainly and the brush is combined with a
        // descriptor of zero, which is a copy — so the brush wins outright.
        XCTAssertEqual(Array(surfaces.surfaces[0]!.pixels[0..<4]), [0xFF, 0, 0, 0])
    }

    /// `DRAW_TRANSPARENT` reaches a draw rather than being counted as ignored.
    ///
    /// Its wire shape is shorter than every other draw carrying an image — no
    /// rop, no scale mode, no mask — so this also pins that the pump hands it
    /// to a decoder that knows that.
    func testTransparentReachesTheSurface() async throws {
        let server = MemoryByteStream(
            inbound: surfaceCreate(4, 2) + transparentDraw(colour: 0x00FF_0000, key: 0x0000_00FF)
        )
        let channel = SpiceDisplayChannel(stream: server)
        var surfaces = SpiceSurfaces()
        var caches = SpiceDisplayCaches()
        var streams = SpiceStreams()
        let progress = try await channel.pump(into: &surfaces, caches: &caches, streams: &streams, serial: 1, limit: 2)

        XCTAssertEqual(progress.ignored, [:], "transparent n'est plus un message ignoré")
        XCTAssertEqual(progress.updates.count, 1)
        // The image is a solid red that does not match the blue key, so it is
        // copied whole.
        XCTAssertEqual(Array(surfaces.surfaces[0]!.pixels[0..<4]), [0, 0, 0xFF, 0])
    }

    /// `DRAW_ALPHA_BLEND` reaches a draw, and its two extra bytes are read in
    /// the right place — no other draw puts anything between the base and the
    /// image pointer.
    func testAlphaBlendReachesTheSurface() async throws {
        let server = MemoryByteStream(
            inbound: surfaceCreate(4, 2) + alphaBlendDraw(colour: 0xFFFF_FFFF, alpha: 0x80)
        )
        let channel = SpiceDisplayChannel(stream: server)
        var surfaces = SpiceSurfaces()
        var caches = SpiceDisplayCaches()
        var streams = SpiceStreams()
        let progress = try await channel.pump(into: &surfaces, caches: &caches, streams: &streams, serial: 1, limit: 2)

        XCTAssertEqual(progress.ignored, [:], "alpha blend n'est plus un message ignoré")
        XCTAssertEqual(progress.updates.count, 1)
        // An opaque white source at half alpha over a black surface: half white.
        XCTAssertEqual(Array(surfaces.surfaces[0]!.pixels[0..<3]), [0x80, 0x80, 0x80])
    }

    /// `DRAW_ROP3` reaches a draw rather than being counted as ignored.
    func testRop3ReachesTheSurface() async throws {
        let server = MemoryByteStream(
            inbound: surfaceCreate(4, 2) + rop3Draw(colour: 0x00FF_0000, opcode: 0xCC)
        )
        let channel = SpiceDisplayChannel(stream: server)
        var surfaces = SpiceSurfaces()
        var caches = SpiceDisplayCaches()
        var streams = SpiceStreams()
        let progress = try await channel.pump(into: &surfaces, caches: &caches, streams: &streams, serial: 1, limit: 2)

        XCTAssertEqual(progress.ignored, [:], "rop3 n'est plus un message ignoré")
        XCTAssertEqual(progress.updates.count, 1)
        // SRCCOPY: the image wins outright, whatever the brush says.
        XCTAssertEqual(Array(surfaces.surfaces[0]!.pixels[0..<4]), [0, 0, 0xFF, 0])
    }

    /// A run of glyphs reaches the surface through the pump.
    ///
    /// Its own tests exercise `SpiceSurfaces.text` directly, which says nothing
    /// about whether anything calls it — the gap that survived a sabotage on an
    /// earlier draw, and is now checked for every new one.
    func testTextReachesTheSurfaceThroughThePump() async throws {
        let fixedLength = 21 + 4 + 16 + 5 + 5 + 2 + 2
        var body = u32(0) + i32(0) + i32(0) + i32(16) + i32(16) + [0]   // base
        body += u32(UInt32(fixedLength))                                // pointeur de chaîne
        body += i32(0) + i32(0) + i32(0) + i32(0)                       // back_area vide
        body += [1] + u32(0x00FF_FFFF)                                  // brosse avant
        body += [1] + u32(0x0000_0080)                                  // brosse arrière
        body += [0x08, 0] + [0x08, 0]                                   // fore_mode, back_mode
        XCTAssertEqual(body.count, fixedLength)

        body += u16(1) + [SpiceDisplayWire.TextString.rasterA8]         // un glyphe, A8
        body += i32(3) + i32(4)                                         // render_pos
        body += i32(0) + i32(0)                                         // glyph_origin
        body += u16(1) + u16(1) + [0xFF]                                // 1×1, opaque

        let server = MemoryByteStream(
            inbound: surfaceCreate(16, 16)
                + message(SpiceDisplayWire.Message.drawText.rawValue, body)
        )
        let channel = SpiceDisplayChannel(stream: server)
        var surfaces = SpiceSurfaces()
        var caches = SpiceDisplayCaches()
        var streams = SpiceStreams()

        let progress = try await channel.pump(
            into: &surfaces, caches: &caches, streams: &streams, serial: 1, limit: 2
        )
        XCTAssertEqual(progress.ignored, [:], "le texte n'est plus un message ignoré")
        XCTAssertEqual(progress.updates.count, 1)

        let surface = surfaces.surfaces[0]!
        let at = (4 * surface.width + 3) * 4
        XCTAssertEqual(
            Array(surface.pixels[at..<(at + 4)]), [0xFF, 0xFF, 0xFF, 0],
            "le glyphe est passé du fil jusqu'aux pixels"
        )
    }

    /// A stroke reaches the surface through the pump.
    ///
    /// Its own tests exercise `SpiceSurfaces.stroke` directly, which says
    /// nothing about whether anything calls it — a gap that survived a sabotage
    /// on an earlier draw and is now checked for every new one.
    func testAStrokeReachesTheSurfaceThroughThePump() async throws {
        // A path behind a pointer, exactly as the wire carries it.
        let fixedLength = 21 + 4 + 1 + 5 + 2 + 2
        var body = u32(0) + i32(0) + i32(0) + i32(8) + i32(16) + [0]   // base
        body += u32(UInt32(fixedLength))                               // pointeur de chemin
        body += [0]                                                    // attributs : pleins
        body += [1] + u32(0x00FF_FFFF)                                 // brosse unie
        body += [0x08, 0] + [0, 0]                                     // fore_mode = PUT, back_mode
        XCTAssertEqual(body.count, fixedLength)
        body += u32(1)                                                 // un segment
        body += [SpiceDisplayWire.PathSegment.begin | SpiceDisplayWire.PathSegment.end]
        body += u32(2) + i32(2 << 4) + i32(3 << 4) + i32(6 << 4) + i32(3 << 4)

        let server = MemoryByteStream(
            inbound: surfaceCreate(16, 8)
                + message(SpiceDisplayWire.Message.drawStroke.rawValue, body)
        )
        let channel = SpiceDisplayChannel(stream: server)
        var surfaces = SpiceSurfaces()
        var caches = SpiceDisplayCaches()
        var streams = SpiceStreams()

        let progress = try await channel.pump(
            into: &surfaces, caches: &caches, streams: &streams, serial: 1, limit: 2
        )
        XCTAssertEqual(progress.ignored, [:], "le tracé n'est plus un message ignoré")
        XCTAssertEqual(progress.updates.count, 1)

        let surface = surfaces.surfaces[0]!
        let at = (3 * surface.width + 4) * 4
        XCTAssertEqual(
            Array(surface.pixels[at..<(at + 4)]), [0xFF, 0xFF, 0xFF, 0],
            "le trait est passé du fil jusqu'aux pixels"
        )
    }

    /// The five stream messages reach the registry rather than being counted as
    /// ignored, and a stream outlives the frames sent to it.
    ///
    /// The frame pixels need a JPEG decoder, which is absent on this runner —
    /// so what this asserts is the routing and the bookkeeping, which is all of
    /// it that is portable. `SpiceStreamsTests` covers the geometry.
    func testTheStreamMessagesReachTheRegistry() async throws {
        func streamCreate(id: UInt32, codec: UInt8 = 1) -> Data {
            var body = u32(0) + u32(id) + [0x01, codec]
            body += u32(0) + u32(0)                                    // stamp
            body += u32(4) + u32(2) + u32(4) + u32(2)                  // stream, source
            body += i32(0) + i32(0) + i32(2) + i32(4)                  // dest
            body += [0]                                                // clip
            return message(SpiceDisplayWire.Message.streamCreate.rawValue, body)
        }
        let server = MemoryByteStream(
            inbound: surfaceCreate(4, 2)
                + streamCreate(id: 1) + streamCreate(id: 2)
                + message(SpiceDisplayWire.Message.streamClip.rawValue,
                          u32(1) + [1] + u32(1) + i32(0) + i32(0) + i32(1) + i32(1))
                + message(SpiceDisplayWire.Message.streamData.rawValue,
                          u32(1) + u32(99) + u32(1) + [0xFF])
                + message(SpiceDisplayWire.Message.streamDestroy.rawValue, u32(2))
                + message(SpiceDisplayWire.Message.streamDestroyAll.rawValue, [])
        )
        let channel = SpiceDisplayChannel(stream: server)
        var surfaces = SpiceSurfaces()
        var caches = SpiceDisplayCaches()
        var streams = SpiceStreams()

        let progress = try await channel.pump(
            into: &surfaces, caches: &caches, streams: &streams, serial: 1, limit: 7
        )
        XCTAssertEqual(progress.ignored, [:], "aucun message de flux n'est ignoré")
        XCTAssertTrue(streams.streams.isEmpty, "DESTROY_ALL a tout enlevé")
    }

    /// A frame whose codec this client cannot decode leaves the screen alone
    /// and does not stop the pump. The stream is still registered — the server
    /// will keep sending frames for it, and each one must be a no-op rather
    /// than an error.
    func testAStreamInACodecThisCannotDecodeIsNotAnError() async throws {
        var body = u32(0) + u32(1) + [0x01, 3]                          // H.264
        body += u32(0) + u32(0)
        body += u32(4) + u32(2) + u32(4) + u32(2)
        body += i32(0) + i32(0) + i32(2) + i32(4)
        body += [0]
        let server = MemoryByteStream(
            inbound: surfaceCreate(4, 2)
                + message(SpiceDisplayWire.Message.streamCreate.rawValue, body)
                + message(SpiceDisplayWire.Message.streamData.rawValue,
                          u32(1) + u32(1) + u32(2) + [0xAB, 0xCD])
        )
        let channel = SpiceDisplayChannel(stream: server)
        var surfaces = SpiceSurfaces()
        var caches = SpiceDisplayCaches()
        var streams = SpiceStreams()

        let progress = try await channel.pump(
            into: &surfaces, caches: &caches, streams: &streams, serial: 1, limit: 3
        )
        XCTAssertEqual(streams.streams[1]?.codec, .h264, "le flux reste enregistré")
        XCTAssertEqual(progress.updates, [], "rien n'a été dessiné")
        XCTAssertTrue(
            surfaces.surfaces[0]!.pixels.allSatisfy { $0 == 0 }, "l'écran est intact"
        )
    }

    /// The sized form is read as the sized form, and not as the plain one with
    /// three fields it does not know about at the end.
    ///
    /// The discriminating input is a frame whose *width* is larger than the
    /// bytes that follow it. Read correctly, that width is a geometry and the
    /// short frame is fine. Read as a plain frame, the width lands where the
    /// byte count goes and the reader runs off the end of the message — so the
    /// pump throws, and the test can tell the two apart without decoding a
    /// pixel. A frame small enough to be a plausible byte count would not:
    /// both readings would succeed, and on a runner with no JPEG decoder both
    /// would then draw nothing.
    func testASizedFrameIsNotReadAsAPlainOne() async throws {
        var create = u32(0) + u32(1) + [0x01, 1]
        create += u32(0) + u32(0)
        create += u32(4) + u32(2) + u32(4) + u32(2)
        create += i32(0) + i32(0) + i32(2) + i32(4)
        create += [0]
        // id, time, then 1024 × 8 and a destination, then four bytes of frame.
        let sized = u32(1) + u32(7) + u32(1024) + u32(8)
            + i32(0) + i32(0) + i32(8) + i32(1024)
            + u32(4) + [0xFF, 0xD8, 0xFF, 0xD9]
        let server = MemoryByteStream(
            inbound: surfaceCreate(4, 2)
                + message(SpiceDisplayWire.Message.streamCreate.rawValue, create)
                + message(SpiceDisplayWire.Message.streamDataSized.rawValue, sized)
        )
        let channel = SpiceDisplayChannel(stream: server)
        var surfaces = SpiceSurfaces()
        var caches = SpiceDisplayCaches()
        var streams = SpiceStreams()

        let progress = try await channel.pump(
            into: &surfaces, caches: &caches, streams: &streams, serial: 1, limit: 3
        )
        XCTAssertEqual(progress.ignored, [:], "STREAM_DATA_SIZED n'est pas ignoré")
        XCTAssertEqual(
            streams.streams[1]?.frameWidth, 4,
            "l'image dimensionnée ne redimensionne pas le flux"
        )
    }

    // MARK: - Le report d'une image sur sa surface

    /// Prefills a surface, because its pixels are not writable from outside.
    private func paint(_ colour: UInt32, over surfaces: inout SpiceSurfaces) throws {
        let surface = surfaces.surfaces[0]!
        _ = try surfaces.fill(SpiceDisplayWire.Fill(
            base: SpiceDisplayWire.Base(
                surfaceID: 0,
                box: SpiceDisplayWire.Rect(
                    top: 0, left: 0,
                    bottom: Int32(surface.height), right: Int32(surface.width)
                ),
                clip: .none
            ),
            brush: .solid(colour), rop: 0x08,
            mask: SpiceDisplayWire.Mask(
                flags: 0, origin: SpiceDisplayWire.Point(x: 0, y: 0), bitmap: nil
            )
        ))
    }

    private func drawableSurface(_ width: UInt32 = 4, _ height: UInt32 = 2) throws
        -> SpiceSurfaces {
        var surfaces = SpiceSurfaces()
        try surfaces.create(SpiceDisplayWire.SurfaceCreate(
            surfaceID: 0, width: width, height: height, format: .xrgb32, flags: 0
        ))
        return surfaces
    }

    /// Pixels rather than a message, because `report` is the half of the frame
    /// path that a runner without a JPEG decoder can reach.
    private func placement(
        width: Int = 2, height: Int = 2, topDown: Bool = true,
        destination: SpiceDisplayWire.Rect? = nil,
        clip: SpiceDisplayWire.Clip = .none
    ) -> SpiceStreams.Placement {
        SpiceStreams.Placement(
            surfaceID: 0, codec: .mjpeg, topDown: topDown, clip: clip,
            width: width, height: height,
            destination: destination ?? SpiceDisplayWire.Rect(
                top: 0, left: 0, bottom: Int32(height), right: Int32(width)
            )
        )
    }

    /// `put_image` is `PIXMAN_OP_SRC`. A frame overwrites what was under it —
    /// including with black, which is what a video fading out sends. Any
    /// combining operation would leave the previous frame showing through, and
    /// on black it would be invisible in a screenshot but wrong in motion.
    func testAFrameOverwritesTheSurfaceRatherThanCombiningWithIt() throws {
        let channel = SpiceDisplayChannel(stream: MemoryByteStream(inbound: Data()))
        var surfaces = try drawableSurface()
        // A destination nothing can be confused with: an OR, an XOR and a copy
        // all differ on these bytes.
        try paint(0x0F0F0F0F, over: &surfaces)
        let frame = [UInt8](repeating: 0x33, count: 2 * 2 * 4)

        let updates = try channel.report(
            (pixels: frame, width: 2, height: 2), at: placement(), into: &surfaces
        )
        XCTAssertNotNil(updates)
        // The fourth byte stays 0: the surface is `xrgb32` and has no alpha.
        XCTAssertEqual(
            Array(surfaces.surfaces[0]!.pixels[0..<4]), [0x33, 0x33, 0x33, 0],
            "0x0F | 0x33 vaut 0x3F et 0x0F ^ 0x33 vaut 0x3C ; c'est un écrasement"
        )
    }

    /// A frame that decodes to a different size than the message announced is
    /// a message disagreeing with itself, and is dropped rather than placed at
    /// whatever size it turned out to be.
    func testAFrameThatIsNotTheAnnouncedSizeIsDropped() throws {
        let channel = SpiceDisplayChannel(stream: MemoryByteStream(inbound: Data()))
        var surfaces = try drawableSurface()
        try paint(0x0F0F0F0F, over: &surfaces)
        let before = surfaces.surfaces[0]!.pixels

        let updates = try channel.report(
            (pixels: [UInt8](repeating: 0x33, count: 1 * 1 * 4), width: 1, height: 1),
            at: placement(width: 2, height: 2), into: &surfaces
        )
        XCTAssertNil(updates, "rien n'est dessiné")
        XCTAssertEqual(surfaces.surfaces[0]!.pixels, before, "l'écran est intact")
    }

    /// The stream's own `TOP_DOWN` decides which way up the frame is read, and
    /// it is bit 0 of a flags byte of its own. A frame with different rows top
    /// and bottom is the only kind that can tell.
    func testTheStreamDecidesWhichWayUpItsFramesAre() throws {
        let channel = SpiceDisplayChannel(stream: MemoryByteStream(inbound: Data()))
        var surfaces = try drawableSurface()
        let frame: [UInt8] = [UInt8](repeating: 0x11, count: 2 * 4)
            + [UInt8](repeating: 0x22, count: 2 * 4)

        _ = try channel.report(
            (pixels: frame, width: 2, height: 2), at: placement(topDown: true),
            into: &surfaces
        )
        XCTAssertEqual(surfaces.surfaces[0]!.pixels[0], 0x11)

        _ = try channel.report(
            (pixels: frame, width: 2, height: 2), at: placement(topDown: false),
            into: &surfaces
        )
        XCTAssertEqual(surfaces.surfaces[0]!.pixels[0], 0x22, "lue de bas en haut")
    }

    /// The stream's clip reduces where its frames land — that is what
    /// `STREAM_CLIP` is for, and a window moving over a video is when it
    /// happens.
    func testTheStreamsClipReducesWhereItsFramesLand() throws {
        let channel = SpiceDisplayChannel(stream: MemoryByteStream(inbound: Data()))
        var surfaces = try drawableSurface()
        let frame = [UInt8](repeating: 0x33, count: 2 * 2 * 4)
        let clip = SpiceDisplayWire.Clip.rects(
            [SpiceDisplayWire.Rect(top: 0, left: 1, bottom: 2, right: 2)]
        )

        _ = try channel.report(
            (pixels: frame, width: 2, height: 2), at: placement(clip: clip),
            into: &surfaces
        )
        XCTAssertEqual(
            Array(surfaces.surfaces[0]!.pixels[0..<4]), [0, 0, 0, 0],
            "la première colonne est hors du clip"
        )
        XCTAssertEqual(Array(surfaces.surfaces[0]!.pixels[4..<8]), [0x33, 0x33, 0x33, 0])
    }

    func testASurfaceIsDestroyedWhenTheServerSaysSo() async throws {
        let server = MemoryByteStream(
            inbound: surfaceCreate(4, 4)
                + message(SpiceDisplayWire.Message.surfaceDestroy.rawValue, u32(0))
        )
        let channel = SpiceDisplayChannel(stream: server)
        var surfaces = SpiceSurfaces()
        var caches = SpiceDisplayCaches()
        var streams = SpiceStreams()

        _ = try await channel.pump(into: &surfaces, caches: &caches, streams: &streams, serial: 1, limit: 2)
        XCTAssertTrue(surfaces.surfaces.isEmpty)
    }

    /// A draw whose box lands entirely off the surface reports no update. An
    /// empty region list is not an update — a renderer told to redraw nothing
    /// redraws the whole screen for no reason.
    func testADrawThatTouchesNothingIsNotReportedAsAnUpdate() async throws {
        let server = MemoryByteStream(
            inbound: surfaceCreate(4, 4) + fill(50, 50, 60, 60, colour: 1)
        )
        let channel = SpiceDisplayChannel(stream: server)
        var surfaces = SpiceSurfaces()
        var caches = SpiceDisplayCaches()
        var streams = SpiceStreams()

        let progress = try await channel.pump(into: &surfaces, caches: &caches, streams: &streams, serial: 1, limit: 2)
        XCTAssertTrue(progress.updates.isEmpty)
        XCTAssertEqual(progress.undrawable, 0, "ce n'est pas un refus, c'est un rien")
    }

    // MARK: - What it will not do

    /// A ping is answered, not counted as ignored. A server that pings and
    /// hears nothing concludes the client is gone.
    func testAPingIsAnsweredRatherThanIgnored() async throws {
        let server = MemoryByteStream(
            inbound: message(SpiceWire.Message.ping, [1, 2, 3, 4])
        )
        let channel = SpiceDisplayChannel(stream: server)
        var surfaces = SpiceSurfaces()
        var caches = SpiceDisplayCaches()
        var streams = SpiceStreams()

        let progress = try await channel.pump(into: &surfaces, caches: &caches, streams: &streams, serial: 7, limit: 1)
        XCTAssertTrue(progress.ignored.isEmpty)

        var reader = SpiceWire.Reader(await server.written)
        let pong = try SpiceWire.decodeDataHeader(Data(try reader.bytes(18)))
        XCTAssertEqual(pong.type, SpiceWire.ClientMessage.pong)
        XCTAssertEqual(pong.serial, 7)
        XCTAssertEqual(try reader.bytes(Int(pong.size)), [1, 2, 3, 4], "le corps du ping revient")
    }

    /// A message this does not handle is counted, by type. A client that
    /// silently ignores half a protocol should at least be able to say how
    /// much of it, and this is the number that says what to build next.
    ///
    /// **The examples keep expiring**, which is the point of the counter
    /// working. This test named `quic` once, then `lz4`, then `streamCreate`;
    /// each stopped being unhandled and the test failed on a truncated payload
    /// rather than on its claim. What is left is the drawing that needs a
    /// rasteriser — strokes and text — so those are the examples now.
    /// **Both examples are now messages that will never be handled**, and it
    /// took four rewrites to get there.
    ///
    /// This test named `streamCreate`, then `drawStroke`, then `drawText`, and
    /// each time that message was implemented it stopped testing the counter
    /// and started testing a decoder that throws on a stub payload. The last
    /// rewrite even said "`DRAW_TEXT` is next in line to go" and used it
    /// anyway.
    ///
    /// The stream reports — `STREAM_ACTIVATE_REPORT` and `STREAM_REPORT`, by
    /// their raw numbers because there is no case for them — let a server tune
    /// its own bitrate. They draw nothing, so there is nothing for this client
    /// to implement, so they cannot expire the way a draw does.
    func testAMessageThisDoesNotHandleIsCountedByType() async throws {
        let unhandled = Self.permanentlyIgnored
        let alsoIgnored: UInt16 = 320   // STREAM_REPORT, pour la même raison
        let server = MemoryByteStream(
            inbound: message(unhandled, [0]) + message(unhandled, [0])
                + message(alsoIgnored, [0])
        )
        let channel = SpiceDisplayChannel(stream: server)
        var surfaces = SpiceSurfaces()
        var caches = SpiceDisplayCaches()
        var streams = SpiceStreams()

        let progress = try await channel.pump(into: &surfaces, caches: &caches, streams: &streams, serial: 1, limit: 3)
        XCTAssertEqual(progress.ignored[unhandled], 2)
        XCTAssertEqual(progress.ignored[alsoIgnored], 1)
    }

    /// An encoding wisq cannot decode leaves that part of the screen alone and
    /// is counted. It must not throw: disconnecting a phone because a server
    /// sent one JPEG is the wrong answer, and it is the answer you get by
    /// treating "not implemented" as "malformed".
    func testAnUndecodableImageLeavesTheScreenAloneRatherThanDroppingTheConnection() async throws {
        var body = u32(0)
        body += i32(0) + i32(0) + i32(4) + i32(4)      // box
        body += [0]                                     // no clip
        let imageOffset = UInt32(body.count + 4 + 16 + 2 + 1 + 13)
        body += u32(imageOffset)                        // src_bitmap
        body += i32(0) + i32(0) + i32(4) + i32(4)       // src_area
        body += [0, 0] + [0]                            // rop, scale mode
        body += [0] + i32(0) + i32(0) + u32(0)          // mask
        body += u32(0) + u32(0)                         // image id
        body += [105 /* JPEG */, 0]                     // an encoding not decoded here
        body += u32(4) + u32(4)
        body += u32(2) + [0xAB, 0xCD]

        let server = MemoryByteStream(
            inbound: surfaceCreate(8, 8)
                + message(SpiceDisplayWire.Message.drawCopy.rawValue, body)
        )
        let channel = SpiceDisplayChannel(stream: server)
        var surfaces = SpiceSurfaces()
        var caches = SpiceDisplayCaches()
        var streams = SpiceStreams()

        let progress = try await channel.pump(into: &surfaces, caches: &caches, streams: &streams, serial: 1, limit: 2)
        XCTAssertEqual(progress.undrawable, 1)
        XCTAssertTrue(progress.updates.isEmpty)
        XCTAssertTrue(surfaces.surfaces[0]!.pixels.allSatisfy { $0 == 0 }, "rien n'a été peint")
    }

    // MARK: - Le cache d'images

    /// A `DRAW_COPY` carrying a 2×2 uncompressed bitmap, with the descriptor's
    /// flags and type under the caller's control.
    private func copyOfImage(
        id: UInt64, type: UInt8, flags: UInt8, pixel: [UInt8], carriesBitmap: Bool = true
    ) -> Data {
        var body = u32(0)
        body += i32(0) + i32(0) + i32(2) + i32(2)       // box
        body += [0]                                      // no clip
        let imageOffset = UInt32(body.count + 4 + 16 + 2 + 1 + 13)
        body += u32(imageOffset)                         // src_bitmap
        body += i32(0) + i32(0) + i32(2) + i32(2)        // src_area
        body += [0, 0] + [0]                             // rop, scale mode
        body += [0] + i32(0) + i32(0) + u32(0)           // mask
        body += u64(id) + [type, flags]                  // descriptor
        body += u32(2) + u32(2)                          // width, height
        if carriesBitmap {
            body += [8 /* RGB32 */, 0]                   // bitmap format, flags
            body += u32(2) + u32(2) + u32(8)             // width, height, stride
            body += u32(0)                               // no palette
            body += pixel + pixel + pixel + pixel        // 2x2 of one colour
        }
        return message(SpiceDisplayWire.Message.drawCopy.rawValue, body)
    }

    /// **The whole point of the cache, driven through the pump.**
    ///
    /// The server sends a picture once with `CACHE_ME`, then names it. The
    /// second draw paints the same pixels having received none of them — which
    /// is the bandwidth this exists to save, and the thing that silently did
    /// not happen while the client declared a cache it did not keep.
    func testAnImageSentOnceIsDrawnTwice() async throws {
        let red: [UInt8] = [0, 0, 0xFF, 0]
        let server = MemoryByteStream(
            inbound: surfaceCreate(8, 8)
                + copyOfImage(id: 42, type: 0 /* bitmap */,
                              flags: SpiceDisplayWire.ImageFlag.cacheMe, pixel: red)
                + copyOfImage(id: 42, type: 103 /* FROM_CACHE */, flags: 0,
                              pixel: [], carriesBitmap: false)
        )
        let channel = SpiceDisplayChannel(stream: server)
        var surfaces = SpiceSurfaces()
        var caches = SpiceDisplayCaches()
        var streams = SpiceStreams()

        let progress = try await channel.pump(
            into: &surfaces, caches: &caches, streams: &streams, serial: 1, limit: 3
        )
        XCTAssertEqual(progress.undrawable, 0, "le nom se résout")
        XCTAssertEqual(progress.updates.count, 2, "deux dessins, une seule image sur le fil")
        XCTAssertEqual(caches.pixmaps.count, 1)
        XCTAssertEqual(caches.pixmaps.storedPixels, 4)
        XCTAssertEqual(Array(surfaces.surfaces[0]!.pixels[0..<4]), red)
    }

    /// **Without `CACHE_ME` nothing is kept**, so the name that follows resolves
    /// to nothing and the draw is skipped. The server sets that flag only when
    /// its own add succeeded, so honouring it exactly is what keeps the two
    /// sides describing the same table — and a client that cached everything
    /// would fill a phone with pictures nobody asks for twice.
    func testAnImageWithoutTheFlagIsNotKeptAndTheNameResolvesToNothing() async throws {
        let red: [UInt8] = [0, 0, 0xFF, 0]
        let server = MemoryByteStream(
            inbound: surfaceCreate(8, 8)
                + copyOfImage(id: 42, type: 0, flags: 0, pixel: red)
                + copyOfImage(id: 42, type: 103, flags: 0, pixel: [], carriesBitmap: false)
        )
        let channel = SpiceDisplayChannel(stream: server)
        var surfaces = SpiceSurfaces()
        var caches = SpiceDisplayCaches()
        var streams = SpiceStreams()

        let progress = try await channel.pump(
            into: &surfaces, caches: &caches, streams: &streams, serial: 1, limit: 3
        )
        XCTAssertEqual(caches.pixmaps.count, 0, "rien n'a demandé à être gardé")
        XCTAssertEqual(progress.undrawable, 1, "le second dessin ne trouve rien")
        XCTAssertEqual(progress.updates.count, 1)
    }

    /// **Invalidations arrive in the header, not in a message of their own.**
    ///
    /// wisq reads the eighteen-byte header, so `dcc->is_mini_header()` is false
    /// on the server and it takes `send_free_list_legacy`: the `INVAL_LIST` is
    /// written into a sub-marshaller and `set_header_sub_list` records where it
    /// sits inside whatever message was being sent anyway. A client that reads
    /// only the message type never sees one — which is exactly what wisq did,
    /// decoding the `subList` field and never looking at it.
    ///
    /// The invalidation rides on a *later* message than the one that cached the
    /// image, which is how it actually happens: the server evicts to make room
    /// for something else and names what it dropped. Sub-messages are handled
    /// before the message carrying them, as `spice_channel_recv_msg` does.
    func testAnInvalidationRidingInTheHeaderIsObeyed() async throws {
        let red: [UInt8] = [0, 0, 0xFF, 0]

        // Un second dessin, tout simple, auquel on accroche la liste.
        let plain = fill(0, 0, 2, 2, colour: 0x0000_FF00)
        var body = [UInt8](plain[SpiceWire.dataHeaderBytes...])
        let listAt = body.count
        body += u16(1)
        let offsetsAt = body.count
        body += u32(0)
        let subAt = body.count
        let invalidation = u16(1) + [SpiceDisplayWire.ResourceType.pixmap] + u64(42)
        body += u16(SpiceDisplayWire.Message.invalList.rawValue)
            + u32(UInt32(invalidation.count)) + invalidation
        body.replaceSubrange(offsetsAt..<(offsetsAt + 4), with: u32(UInt32(subAt)))

        let carrier = SpiceWire.encode(SpiceWire.DataHeader(
            serial: 1, type: SpiceDisplayWire.Message.drawFill.rawValue,
            size: UInt32(body.count), subList: UInt32(listAt)
        )) + Data(body)

        let server = MemoryByteStream(
            inbound: surfaceCreate(8, 8)
                + copyOfImage(id: 42, type: 0,
                              flags: SpiceDisplayWire.ImageFlag.cacheMe, pixel: red)
                + carrier
        )
        let channel = SpiceDisplayChannel(stream: server)
        var surfaces = SpiceSurfaces()
        var caches = SpiceDisplayCaches()
        var streams = SpiceStreams()

        // Après deux messages l'image est gardée ; le troisième la relâche.
        _ = try await channel.pump(
            into: &surfaces, caches: &caches, streams: &streams, serial: 1, limit: 2
        )
        XCTAssertEqual(caches.pixmaps.count, 1, "gardée sur ordre du serveur")

        _ = try await channel.pump(
            into: &surfaces, caches: &caches, streams: &streams, serial: 1, limit: 1
        )
        XCTAssertEqual(caches.pixmaps.count, 0, "relâchée sur ordre du serveur")
        XCTAssertEqual(caches.pixmaps.storedPixels, 0)
    }

    /// A message carrying an `INVAL_LIST` in its header, for a given resource.
    private func fillCarryingInvalidation(of id: UInt64, type: UInt8) -> Data {
        let plain = fill(0, 0, 2, 2, colour: 0x0000_FF00)
        var body = [UInt8](plain[SpiceWire.dataHeaderBytes...])
        let listAt = body.count
        body += u16(1)
        let offsetsAt = body.count
        body += u32(0)
        let subAt = body.count
        let invalidation = u16(1) + [type] + u64(id)
        body += u16(SpiceDisplayWire.Message.invalList.rawValue)
            + u32(UInt32(invalidation.count)) + invalidation
        body.replaceSubrange(offsetsAt..<(offsetsAt + 4), with: u32(UInt32(subAt)))
        return SpiceWire.encode(SpiceWire.DataHeader(
            serial: 1, type: SpiceDisplayWire.Message.drawFill.rawValue,
            size: UInt32(body.count), subList: UInt32(listAt)
        )) + Data(body)
    }

    /// **The list is typed, and only pixmaps are images.**
    ///
    /// A `ResourceID` carries a type beside its identifier, and today's server
    /// only ever fills it with `SPICE_RES_TYPE_PIXMAP` — `dcc_push_release` has
    /// a single caller and it passes that constant. Palettes are invalidated by
    /// their own messages, 107 and 108, not through this list.
    ///
    /// So with a conforming server the filter changes nothing, and dropping it
    /// survived the whole suite until this test existed. It stays because the
    /// protocol types the list and `SPICE_RESOURCE_TYPE_ENUM_END` says the enum
    /// is meant to grow: the identifiers come from different spaces, so the day
    /// a second type appears, an unfiltered client evicts a perfectly good
    /// picture whenever two of them happen to collide.
    func testAResourceThatIsNotAPixmapDoesNotEvictAnImage() async throws {
        let red: [UInt8] = [0, 0, 0xFF, 0]
        let server = MemoryByteStream(
            inbound: surfaceCreate(8, 8)
                + copyOfImage(id: 42, type: 0,
                              flags: SpiceDisplayWire.ImageFlag.cacheMe, pixel: red)
                // Le même identifiant, mais pas une image.
                + fillCarryingInvalidation(of: 42, type: 0 /* RES_TYPE_INVALID */)
                // Puis le bon type, pour montrer que le test peut voir la chute.
                + fillCarryingInvalidation(of: 42, type: SpiceDisplayWire.ResourceType.pixmap)
        )
        let channel = SpiceDisplayChannel(stream: server)
        var surfaces = SpiceSurfaces()
        var caches = SpiceDisplayCaches()
        var streams = SpiceStreams()

        _ = try await channel.pump(
            into: &surfaces, caches: &caches, streams: &streams, serial: 1, limit: 3
        )
        XCTAssertEqual(caches.pixmaps.count, 1, "un identifiant d'un autre type n'est pas l'image")

        _ = try await channel.pump(
            into: &surfaces, caches: &caches, streams: &streams, serial: 1, limit: 1
        )
        XCTAssertEqual(caches.pixmaps.count, 0, "le bon type la relâche bien")
    }

    /// A `DRAW_COPY` carrying a 2×2 eight-bit palettised bitmap. The colour
    /// table is either carried (with `PAL_CACHE_ME`) or named (`PAL_FROM_CACHE`).
    private func copyOfPalettised(
        id: UInt64, unique: UInt64, carriesTable: Bool, colour: UInt32 = 0x00FF_0000
    ) -> Data {
        var body = u32(0)
        body += i32(0) + i32(0) + i32(2) + i32(2)       // box
        body += [0]                                      // no clip
        let imageOffset = UInt32(body.count + 4 + 16 + 2 + 1 + 13)
        body += u32(imageOffset)                         // src_bitmap
        body += i32(0) + i32(0) + i32(2) + i32(2)        // src_area
        body += [0, 0] + [0]                             // rop, scale mode
        body += [0] + i32(0) + i32(0) + u32(0)           // mask
        body += u64(id) + [0 /* bitmap */, 0]            // descriptor
        body += u32(2) + u32(2)                          // width, height

        let flags: UInt8 = carriesTable
            ? SpiceDisplayWire.BitmapFlag.paletteCacheMe
            : SpiceDisplayWire.BitmapFlag.paletteFromCache
        body += [5 /* 8BIT */, flags]
        body += u32(2) + u32(2) + u32(2)                 // width, height, stride
        if carriesTable {
            // Le pointeur vise la fin des pixels ; la table y est écrite.
            let paletteAt = UInt32(body.count + 4 + 4)
            body += u32(paletteAt)
            body += [0, 0, 0, 0]                         // 2x2 index 0, stride 2
            body += u64(unique) + u16(1) + u32(colour)
        } else {
            body += u64(unique)                          // le nom de la table
            body += [0, 0, 0, 0]
        }
        return message(SpiceDisplayWire.Message.drawCopy.rawValue, body)
    }

    /// **The colour table travels once too**, and by a mechanism the client
    /// cannot decline: `CLIENT_PALETTE_CACHE_SIZE` is a server-side constant
    /// and nothing in `DISPLAY_INIT` negotiates it. Without a palette cache the
    /// second draw has no colours and paints nothing.
    func testAPaletteSentOnceColoursALaterImage() async throws {
        let server = MemoryByteStream(
            inbound: surfaceCreate(8, 8)
                + copyOfPalettised(id: 1, unique: 0x5151, carriesTable: true)
                + copyOfPalettised(id: 2, unique: 0x5151, carriesTable: false)
        )
        let channel = SpiceDisplayChannel(stream: server)
        var surfaces = SpiceSurfaces()
        var caches = SpiceDisplayCaches()
        var streams = SpiceStreams()

        let progress = try await channel.pump(
            into: &surfaces, caches: &caches, streams: &streams, serial: 1, limit: 3
        )
        XCTAssertEqual(caches.palettes.count, 1, "la table est retenue")
        XCTAssertEqual(progress.undrawable, 0, "le nom de table se résout")
        XCTAssertEqual(progress.updates.count, 2)
        // Rouge, depuis la table nommée par la seconde image.
        XCTAssertEqual(Array(surfaces.surfaces[0]!.pixels[0..<4]), [0, 0, 0xFF, 0])
    }

    /// And when the table has been invalidated, the name resolves to nothing
    /// and the draw is skipped rather than painted in whatever colours were
    /// last in memory.
    func testAnInvalidatedPaletteLeavesTheImageUndrawable() async throws {
        let server = MemoryByteStream(
            inbound: surfaceCreate(8, 8)
                + copyOfPalettised(id: 1, unique: 0x5151, carriesTable: true)
                + message(SpiceDisplayWire.Message.invalPalette.rawValue, u64(0x5151))
                + copyOfPalettised(id: 2, unique: 0x5151, carriesTable: false)
        )
        let channel = SpiceDisplayChannel(stream: server)
        var surfaces = SpiceSurfaces()
        var caches = SpiceDisplayCaches()
        var streams = SpiceStreams()

        let progress = try await channel.pump(
            into: &surfaces, caches: &caches, streams: &streams, serial: 1, limit: 4
        )
        XCTAssertEqual(caches.palettes.count, 0, "la table a été relâchée")
        XCTAssertEqual(progress.undrawable, 1, "le second dessin n'a plus de couleurs")
        XCTAssertEqual(progress.updates.count, 1)
    }

    /// **A name this client cannot resolve costs one draw, not the session.**
    ///
    /// This is the severity the palette cache changes, and it is worth stating
    /// on its own. `SpiceBitmap.pixels` throws `missingPalette` for a palettised
    /// format with no colours, and a thrown error stops the pump — so before
    /// there was a cache, *every* image naming a cached table dropped the
    /// connection. The server sends those without asking:
    /// `CLIENT_PALETTE_CACHE_SIZE` is its own constant and `DISPLAY_INIT` has no
    /// field for it.
    ///
    /// So an unresolvable name now goes where an undecodable codec goes —
    /// counted, screen left alone, connection kept — and the pump keeps running
    /// afterwards, which is what the third message here proves.
    func testAnUnresolvablePaletteCostsOneDrawRatherThanTheSession() async throws {
        let server = MemoryByteStream(
            inbound: surfaceCreate(8, 8)
                // Jamais vue : aucune table sous ce nom.
                + copyOfPalettised(id: 1, unique: 0x7777, carriesTable: false)
                + fill(0, 0, 2, 2, colour: 0x0000_FF00)
        )
        let channel = SpiceDisplayChannel(stream: server)
        var surfaces = SpiceSurfaces()
        var caches = SpiceDisplayCaches()
        var streams = SpiceStreams()

        let progress = try await channel.pump(
            into: &surfaces, caches: &caches, streams: &streams, serial: 1, limit: 3
        )
        XCTAssertEqual(progress.undrawable, 1)
        XCTAssertEqual(progress.updates.count, 1, "la pompe a survécu et a dessiné la suite")
        XCTAssertEqual(
            Array(surfaces.surfaces[0]!.pixels[0..<4]), [0, 0xFF, 0, 0],
            "le message d'après a bien été traité"
        )
    }

    /// A malformed message *is* fatal, and that is the distinction the previous
    /// test rests on. A surface format that cannot be laid out is not "wisq
    /// does not do this yet", it is a message that makes no sense.
    func testAMalformedMessageStopsThePumpRatherThanBeingCounted() async throws {
        let server = MemoryByteStream(
            inbound: message(
                SpiceDisplayWire.Message.surfaceCreate.rawValue,
                u32(0) + u32(8) + u32(8) + u32(77) + u32(0)
            )
        )
        let channel = SpiceDisplayChannel(stream: server)
        var surfaces = SpiceSurfaces()
        var caches = SpiceDisplayCaches()
        var streams = SpiceStreams()

        do {
            _ = try await channel.pump(into: &surfaces, caches: &caches, streams: &streams, serial: 1, limit: 1)
            XCTFail("un message malformé doit arrêter la pompe")
        } catch {
            XCTAssertEqual(error as? SpiceError, .invalidData)
        }
    }

    /// A size is an allocation instruction from the far end.
    func testAnAbsurdMessageSizeIsRefusedBeforeItIsRead() async throws {
        let header = SpiceWire.encode(SpiceWire.DataHeader(
            serial: 1, type: SpiceDisplayWire.Message.drawFill.rawValue, size: 0xFFFF_FFFF
        ))
        let server = MemoryByteStream(inbound: header)
        let channel = SpiceDisplayChannel(stream: server)
        var surfaces = SpiceSurfaces()
        var caches = SpiceDisplayCaches()
        var streams = SpiceStreams()

        do {
            _ = try await channel.pump(into: &surfaces, caches: &caches, streams: &streams, serial: 1, limit: 1)
            XCTFail("une taille absurde doit être refusée")
        } catch {
            XCTAssertEqual(error as? SpiceError, .invalidData)
        }
    }
    /// The serial has to survive between calls.
    ///
    /// The pump is a `struct` and the caller is what persists, so the next
    /// serial comes back in the result. A caller passing the same number in
    /// every time hands a server that acknowledges by serial a sequence full of
    /// holes — and the default is now one message per call, so this happens on
    /// every single message rather than once per batch.
    ///
    /// This test exists because a sabotage found it missing: deleting the line
    /// that sets `nextSerial` changed nothing, since nothing looked at it. The
    /// `defer` that also set it turned out to be dead code — a `defer` runs
    /// after the return value has been copied, so it cannot change what comes
    /// back. Both were fixed rather than one.
    func testTheNextSerialComesBackSoItCanSurviveBetweenCalls() async throws {
        let server = MemoryByteStream(
            inbound: message(SpiceWire.Message.ping, [1])
                + message(SpiceWire.Message.ping, [2])
        )
        let channel = SpiceDisplayChannel(stream: server)
        var surfaces = SpiceSurfaces()
        var caches = SpiceDisplayCaches()
        var streams = SpiceStreams()

        let first = try await channel.pump(into: &surfaces, caches: &caches, streams: &streams, serial: 10, limit: 1)
        XCTAssertEqual(first.nextSerial, 11, "un pong envoyé, donc un cran")

        let second = try await channel.pump(into: &surfaces, caches: &caches, streams: &streams, serial: first.nextSerial, limit: 1)
        XCTAssertEqual(second.nextSerial, 12)

        // And the wire agrees: two pongs, with consecutive serials.
        var reader = SpiceWire.Reader(await server.written)
        let one = try SpiceWire.decodeDataHeader(Data(try reader.bytes(18)))
        _ = try reader.bytes(Int(one.size))
        let two = try SpiceWire.decodeDataHeader(Data(try reader.bytes(18)))
        XCTAssertEqual(one.serial, 10)
        XCTAssertEqual(two.serial, 11, "pas de trou dans la suite")
    }

    /// A message that needs no reply does not burn a serial. Serials count what
    /// this client said, not what it heard.
    func testAMessageNeedingNoReplyDoesNotAdvanceTheSerial() async throws {
        let server = MemoryByteStream(
            inbound: message(Self.permanentlyIgnored, [0])
        )
        let channel = SpiceDisplayChannel(stream: server)
        var surfaces = SpiceSurfaces()
        var caches = SpiceDisplayCaches()
        var streams = SpiceStreams()

        let progress = try await channel.pump(into: &surfaces, caches: &caches, streams: &streams, serial: 5, limit: 1)
        XCTAssertEqual(progress.nextSerial, 5)
    }
}
