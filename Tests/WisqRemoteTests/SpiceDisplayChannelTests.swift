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
    private func u32(_ value: UInt32) -> [UInt8] { (0..<4).map { UInt8(value >> (8 * $0) & 0xFF) } }
    private func i32(_ value: Int32) -> [UInt8] { u32(UInt32(bitPattern: value)) }

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
        // drift apart — they already did once, when QUIC became decodable and
        // the request changed from `lz` to `autoLZ`.
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
        var glz = SpiceGLZ.Window()

        let progress = try await channel.pump(into: &surfaces, glz: &glz, serial: 1, limit: 2)

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
        var glz = SpiceGLZ.Window()

        let progress = try await channel.pump(into: &surfaces, glz: &glz, serial: 1, limit: 5)

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
            var glz = SpiceGLZ.Window()
            let progress = try await channel.pump(
                into: &surfaces, glz: &glz, serial: 1, limit: 2
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
        var glz = SpiceGLZ.Window()
        let progress = try await channel.pump(into: &surfaces, glz: &glz, serial: 1, limit: 2)

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
        var glz = SpiceGLZ.Window()
        let progress = try await channel.pump(into: &surfaces, glz: &glz, serial: 1, limit: 2)

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
        var glz = SpiceGLZ.Window()
        let progress = try await channel.pump(into: &surfaces, glz: &glz, serial: 1, limit: 2)

        XCTAssertEqual(progress.ignored, [:], "alpha blend n'est plus un message ignoré")
        XCTAssertEqual(progress.updates.count, 1)
        // An opaque white source at half alpha over a black surface: half white.
        XCTAssertEqual(Array(surfaces.surfaces[0]!.pixels[0..<3]), [0x80, 0x80, 0x80])
    }

    func testASurfaceIsDestroyedWhenTheServerSaysSo() async throws {
        let server = MemoryByteStream(
            inbound: surfaceCreate(4, 4)
                + message(SpiceDisplayWire.Message.surfaceDestroy.rawValue, u32(0))
        )
        let channel = SpiceDisplayChannel(stream: server)
        var surfaces = SpiceSurfaces()
        var glz = SpiceGLZ.Window()

        _ = try await channel.pump(into: &surfaces, glz: &glz, serial: 1, limit: 2)
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
        var glz = SpiceGLZ.Window()

        let progress = try await channel.pump(into: &surfaces, glz: &glz, serial: 1, limit: 2)
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
        var glz = SpiceGLZ.Window()

        let progress = try await channel.pump(into: &surfaces, glz: &glz, serial: 7, limit: 1)
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
    func testAMessageThisDoesNotHandleIsCountedByType() async throws {
        let unhandled = SpiceDisplayWire.Message.drawText.rawValue
        let server = MemoryByteStream(
            inbound: message(unhandled, [0]) + message(unhandled, [0])
                + message(SpiceDisplayWire.Message.streamCreate.rawValue, [0])
        )
        let channel = SpiceDisplayChannel(stream: server)
        var surfaces = SpiceSurfaces()
        var glz = SpiceGLZ.Window()

        let progress = try await channel.pump(into: &surfaces, glz: &glz, serial: 1, limit: 3)
        XCTAssertEqual(progress.ignored[unhandled], 2)
        XCTAssertEqual(progress.ignored[SpiceDisplayWire.Message.streamCreate.rawValue], 1)
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
        var glz = SpiceGLZ.Window()

        let progress = try await channel.pump(into: &surfaces, glz: &glz, serial: 1, limit: 2)
        XCTAssertEqual(progress.undrawable, 1)
        XCTAssertTrue(progress.updates.isEmpty)
        XCTAssertTrue(surfaces.surfaces[0]!.pixels.allSatisfy { $0 == 0 }, "rien n'a été peint")
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
        var glz = SpiceGLZ.Window()

        do {
            _ = try await channel.pump(into: &surfaces, glz: &glz, serial: 1, limit: 1)
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
        var glz = SpiceGLZ.Window()

        do {
            _ = try await channel.pump(into: &surfaces, glz: &glz, serial: 1, limit: 1)
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
        var glz = SpiceGLZ.Window()

        let first = try await channel.pump(into: &surfaces, glz: &glz, serial: 10, limit: 1)
        XCTAssertEqual(first.nextSerial, 11, "un pong envoyé, donc un cran")

        let second = try await channel.pump(into: &surfaces, glz: &glz, serial: first.nextSerial, limit: 1)
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
            inbound: message(SpiceDisplayWire.Message.drawText.rawValue, [0])
        )
        let channel = SpiceDisplayChannel(stream: server)
        var surfaces = SpiceSurfaces()
        var glz = SpiceGLZ.Window()

        let progress = try await channel.pump(into: &surfaces, glz: &glz, serial: 5, limit: 1)
        XCTAssertEqual(progress.nextSerial, 5)
    }
}
