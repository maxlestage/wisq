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
        XCTAssertEqual(try reader.bytes(Int(second.size)), [SpiceDisplayClient.Compression.lz.rawValue])
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

        let progress = try await channel.pump(into: &surfaces, serial: 1, limit: 2)

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

    func testASurfaceIsDestroyedWhenTheServerSaysSo() async throws {
        let server = MemoryByteStream(
            inbound: surfaceCreate(4, 4)
                + message(SpiceDisplayWire.Message.surfaceDestroy.rawValue, u32(0))
        )
        let channel = SpiceDisplayChannel(stream: server)
        var surfaces = SpiceSurfaces()

        _ = try await channel.pump(into: &surfaces, serial: 1, limit: 2)
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

        let progress = try await channel.pump(into: &surfaces, serial: 1, limit: 2)
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

        let progress = try await channel.pump(into: &surfaces, serial: 7, limit: 1)
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

        let progress = try await channel.pump(into: &surfaces, serial: 1, limit: 3)
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

        let progress = try await channel.pump(into: &surfaces, serial: 1, limit: 2)
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

        do {
            _ = try await channel.pump(into: &surfaces, serial: 1, limit: 1)
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

        do {
            _ = try await channel.pump(into: &surfaces, serial: 1, limit: 1)
            XCTFail("une taille absurde doit être refusée")
        } catch {
            XCTAssertEqual(error as? SpiceError, .invalidData)
        }
    }
}
