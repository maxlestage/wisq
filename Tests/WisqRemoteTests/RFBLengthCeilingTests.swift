import Foundation
import WisqCore
import WisqNet
import XCTest

@testable import WisqRemote

/// Nothing bounded the `UInt32` lengths an RFB server sends.
///
/// These tests assert on the **size the code asked for**, not on the fact that
/// it threw. The distinction is the whole point: on a real socket an absurd
/// length does not throw, it waits, accumulating whatever the server dribbles.
/// Before the ceilings, a rectangle naming `UInt32.max` made the decoder ask
/// for 4 294 967 295 bytes in a single read; after them the request never
/// happens at all.
final class RFBLengthCeilingTests: XCTestCase {
    private let absurd = UInt32.max

    // MARK: - Wire helpers

    private func uint32(_ value: UInt32) -> Data {
        var data = Data()
        for shift in [24, 16, 8, 0] { data.append(UInt8((value >> UInt32(shift)) & 0xFF)) }
        return data
    }

    private func uint16(_ value: UInt16) -> Data {
        Data([UInt8(value >> 8), UInt8(value & 0xFF)])
    }

    private func rectangleHeader(width: UInt16, height: UInt16, encoding: Int32) -> Data {
        var data = uint16(0) + uint16(0) + uint16(width) + uint16(height)
        data.append(uint32(UInt32(bitPattern: encoding)))
        return data
    }

    /// Drives one rectangle through the decoder and reports the largest single
    /// read it asked for.
    private func largestReadDecoding(
        width: UInt16 = 16, height: UInt16 = 16, encoding: Int32, length: UInt32,
        payload: Data = Data()
    ) async throws -> Int {
        var wire = rectangleHeader(width: width, height: height, encoding: encoding)
        wire.append(uint32(length))
        wire.append(payload)
        let stream = RecordingByteStream(inbound: wire)
        let decoder = RFBDecoder(
            stream: stream,
            framebuffer: Framebuffer(width: 64, height: 64),
            streams: try RFBStreams()
        )
        _ = try? await decoder.decodeRectangle()
        return await stream.largestRequest
    }

    // MARK: - The decoder's three lengths

    func testAnAbsurdDesktopNameIsNeverRead() async throws {
        let largest = try await largestReadDecoding(encoding: -307, length: absurd)
        XCTAssertLessThanOrEqual(
            largest, RFBLimits.maximumTextBytes,
            "le décodeur a réclamé \(largest) octets pour un nom de bureau")
    }

    func testAnAbsurdZlibBlockIsNeverRead() async throws {
        let largest = try await largestReadDecoding(encoding: 6, length: absurd)
        XCTAssertLessThanOrEqual(
            largest, RFBLimits.maximumCompressedBytes(for: Rect(x: 0, y: 0, width: 16, height: 16)),
            "le décodeur a réclamé \(largest) octets pour un bloc zlib")
    }

    func testAnAbsurdZRLEBlockIsNeverRead() async throws {
        let largest = try await largestReadDecoding(encoding: 16, length: absurd)
        XCTAssertLessThanOrEqual(
            largest, RFBLimits.maximumCompressedBytes(for: Rect(x: 0, y: 0, width: 16, height: 16)),
            "le décodeur a réclamé \(largest) octets pour un bloc ZRLE")
    }

    // MARK: - The other edge: what must NOT be refused

    /// Half the work of a ceiling is the traffic it lets through. A name of a
    /// normal length has to be read in full, not clipped or rejected.
    func testANormalDesktopNameIsStillRead() async throws {
        let name = Data("un-bureau-parfaitement-ordinaire".utf8)
        let largest = try await largestReadDecoding(
            encoding: -307, length: UInt32(name.count), payload: name)
        XCTAssertEqual(largest, name.count)
    }

    /// A rectangle's compressed block is bounded by the rectangle, so a large
    /// rectangle must be allowed a large block. A ceiling that ignored the
    /// geometry would refuse this.
    func testABlockThatFitsALargeRectangleIsAccepted() async throws {
        let rect = Rect(x: 0, y: 0, width: 1024, height: 768)
        let ceiling = RFBLimits.maximumCompressedBytes(for: rect)
        XCTAssertGreaterThan(ceiling, 1024 * 768 * 4)
        let largest = try await largestReadDecoding(
            width: 1024, height: 768, encoding: 6, length: UInt32(1024 * 768 * 4))
        XCTAssertEqual(
            largest, 1024 * 768 * 4,
            "un bloc de la taille de son rectangle doit être lu, pas refusé")
    }

    /// And the ceiling has to move with the rectangle rather than being one
    /// number for every size — otherwise it is either useless on small
    /// rectangles or wrong on large ones.
    func testTheCeilingFollowsTheRectangle() {
        let small = RFBLimits.maximumCompressedBytes(for: Rect(x: 0, y: 0, width: 8, height: 8))
        let large = RFBLimits.maximumCompressedBytes(for: Rect(x: 0, y: 0, width: 4096, height: 4096))
        XCTAssertLessThan(small, large)
    }

    // MARK: - The session's four lengths

    private func handshake(
        security: UInt8 = 1, result: UInt32 = 0, nameLength: UInt32 = 4,
        name: Data = Data("wisq".utf8)
    ) -> Data {
        var data = Data("RFB 003.008\n".utf8)
        data.append(contentsOf: [1, security])
        data.append(uint32(result))
        data.append(uint16(640) + uint16(480))
        data.append(PixelFormat.bgra32.encoded)
        data.append(uint32(nameLength))
        data.append(name)
        return data
    }

    private func largestReadStarting(_ script: Data) async throws -> Int {
        let stream = RecordingByteStream(inbound: script)
        let session = VNCSession(
            configuration: SessionConfiguration(host: "10.0.0.5", port: 5900),
            streamProvider: { _ in stream }
        )
        await session.start()
        for await event in session.events {
            if case .disconnected = event { break }
            if case .ready = event { break }
        }
        await session.stop()
        return await stream.largestRequest
    }

    /// The one an attacker reaches first: before any password is offered, a
    /// listener can answer "refused" and name a four-gigabyte reason.
    func testAnAbsurdRefusalReasonIsNeverRead() async throws {
        var script = Data("RFB 003.008\n".utf8)
        script.append(contentsOf: [0])
        script.append(uint32(absurd))
        let largest = try await largestReadStarting(script)
        XCTAssertLessThanOrEqual(
            largest, RFBLimits.maximumTextBytes,
            "la session a réclamé \(largest) octets avant toute authentification")
    }

    func testAnAbsurdAuthenticationFailureReasonIsNeverRead() async throws {
        var script = Data("RFB 003.008\n".utf8)
        script.append(contentsOf: [1, RFB.SecurityType.none.rawValue])
        script.append(uint32(1))
        script.append(uint32(absurd))
        let largest = try await largestReadStarting(script)
        XCTAssertLessThanOrEqual(largest, RFBLimits.maximumTextBytes)
    }

    func testAnAbsurdServerInitNameIsNeverRead() async throws {
        let largest = try await largestReadStarting(handshake(nameLength: absurd, name: Data()))
        XCTAssertLessThanOrEqual(
            largest, RFBLimits.maximumTextBytes,
            "la session a réclamé \(largest) octets pour le nom du bureau")
    }

    func testAnAbsurdClipboardIsNeverRead() async throws {
        var script = handshake()
        script.append(contentsOf: [3, 0, 0, 0])
        script.append(uint32(absurd))
        let largest = try await largestReadStarting(script)
        XCTAssertLessThanOrEqual(
            largest, RFBLimits.maximumClipboardBytes,
            "la session a réclamé \(largest) octets de presse-papiers")
    }

    /// The clipboard's ceiling is deliberately higher than a name's: a paste is
    /// allowed to be a document. A ceiling that treated them alike would refuse
    /// traffic the user asked for.
    func testTheClipboardIsAllowedMoreThanAName() {
        XCTAssertGreaterThan(RFBLimits.maximumClipboardBytes, RFBLimits.maximumTextBytes)
    }
}
