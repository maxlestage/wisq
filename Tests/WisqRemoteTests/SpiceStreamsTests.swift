import XCTest
@testable import WisqRemote

/// The streams a server opens on the display channel.
///
/// A SPICE server watches for a rectangle that keeps changing and, past a
/// threshold, stops sending it as draws and starts sending it as video. On a
/// desktop playing anything, that is where most of the pixels go — so ignoring
/// streams shows a frozen rectangle exactly where the motion is.
///
/// Everything here is registry and geometry, which is why it is all testable on
/// a runner with no video decoder at all. The frame *pixels* are `JPEGDecoder`'s
/// business and are absent on Linux, exactly as they are for a `.jpeg` image.
final class SpiceStreamsTests: XCTestCase {
    private func rect(_ top: Int32, _ left: Int32, _ bottom: Int32, _ right: Int32)
        -> SpiceDisplayWire.Rect {
        SpiceDisplayWire.Rect(top: top, left: left, bottom: bottom, right: right)
    }

    private func create(
        id: UInt32 = 1, surface: UInt32 = 0, codec: SpiceDisplayWire.VideoCodec = .mjpeg,
        flags: UInt8 = 0x01, stream: (UInt32, UInt32) = (32, 24),
        source: (UInt32, UInt32) = (64, 48), destination: SpiceDisplayWire.Rect? = nil
    ) -> SpiceDisplayWire.StreamCreate {
        SpiceDisplayWire.StreamCreate(
            surfaceID: surface, id: id, flags: flags, codec: codec, stamp: 7,
            streamWidth: stream.0, streamHeight: stream.1,
            sourceWidth: source.0, sourceHeight: source.1,
            destination: destination ?? rect(0, 0, 48, 64), clip: .none
        )
    }

    private func data(
        id: UInt32 = 1, sized: SpiceDisplayWire.StreamData.Sized? = nil
    ) -> SpiceDisplayWire.StreamData {
        SpiceDisplayWire.StreamData(
            id: id, multimediaTime: 1234, sized: sized, frame: [1, 2, 3]
        )
    }

    // MARK: - The registry

    func testAStreamIsRememberedAndThenForgotten() throws {
        var streams = SpiceStreams()
        try streams.create(create())
        XCTAssertEqual(streams.streams[1]?.codec, .mjpeg)
        XCTAssertEqual(streams.streams[1]?.frameWidth, 32)
        XCTAssertEqual(streams.streams[1]?.surfaceID, 0)

        streams.destroy(1)
        XCTAssertNil(streams.streams[1])
    }

    /// **Destroying a stream that does not exist is not an error.**
    ///
    /// The server sends `STREAM_DESTROY_ALL` on a reset. A client that had
    /// dropped a create it could not honour would otherwise refuse the tidy-up
    /// and drop the connection over it — which is the whole screen going away
    /// because of a stream it was already ignoring.
    func testDestroyingAStreamThatWasNeverOpenedIsHarmless() {
        var streams = SpiceStreams()
        streams.destroy(9)
        streams.destroyAll()
        XCTAssertTrue(streams.streams.isEmpty)
    }

    func testTwoStreamsWithTheSameIdIsRefused() throws {
        var streams = SpiceStreams()
        try streams.create(create(id: 3))
        XCTAssertThrowsError(try streams.create(create(id: 3))) { error in
            XCTAssertEqual(error as? SpiceStreams.Failure, .streamAlreadyExists(3))
        }
    }

    func testAFrameSizeNoPhoneCouldHoldIsRefusedBeforeAnythingIsAllocated() {
        var streams = SpiceStreams()
        for size in [(UInt32(0), UInt32(24)), (32, 0), (0xFFFF, 0xFFFF)] {
            XCTAssertThrowsError(
                try streams.create(create(stream: size)), "\(size)"
            ) { error in
                XCTAssertEqual(
                    error as? SpiceStreams.Failure,
                    .unreasonableSize(width: size.0, height: size.1), "\(size)"
                )
            }
        }
    }

    /// `STREAM_CLIP` — the visible part changing without the stream restarting,
    /// which is what happens when a window moves over the video.
    func testTheClipCanChangeWithoutTheStreamRestarting() throws {
        var streams = SpiceStreams()
        try streams.create(create())
        XCTAssertEqual(streams.streams[1]?.clip, SpiceDisplayWire.Clip.none)

        try streams.clip(1, to: .rects([rect(0, 0, 10, 10)]))
        XCTAssertEqual(streams.streams[1]?.clip, .rects([rect(0, 0, 10, 10)]))
        // And the rest of the stream is untouched.
        XCTAssertEqual(streams.streams[1]?.frameWidth, 32)
        XCTAssertEqual(streams.streams[1]?.destination, rect(0, 0, 48, 64))
    }

    func testClippingAStreamThatDoesNotExistIsRefused() {
        var streams = SpiceStreams()
        XCTAssertThrowsError(try streams.clip(4, to: .none)) { error in
            XCTAssertEqual(error as? SpiceStreams.Failure, .unknownStream(4))
        }
    }

    // MARK: - Where a frame goes

    /// **The two pairs of dimensions are not the same pair.**
    ///
    /// `stream_width`/`stream_height` is the size of the frames on the wire;
    /// `src_width`/`src_height` is the size of the region on the server's
    /// screen. They differ whenever the server scales before encoding, which it
    /// does routinely — so using the source pair puts the video in the right
    /// place at the wrong size, which looks like a decoder bug.
    func testAFrameIsTheStreamSizeAndNotTheSourceSize() throws {
        var streams = SpiceStreams()
        try streams.create(create(stream: (32, 24), source: (64, 48)))
        let placement = try streams.placement(for: data())
        XCTAssertEqual(placement.width, 32)
        XCTAssertEqual(placement.height, 24)
        XCTAssertEqual(placement.destination, rect(0, 0, 48, 64))
    }

    /// **A sized frame does not resize the stream.**
    ///
    /// `STREAM_DATA_SIZED` carries its own width, height and destination. The
    /// reference reads them into the frame it is about to draw and never
    /// touches the stream — so the next plain frame goes back to the original
    /// geometry. Storing them would show as the video jumping size whenever a
    /// sized frame arrived.
    func testASizedFrameAppliesToItselfAndNotToTheStream() throws {
        var streams = SpiceStreams()
        try streams.create(create(stream: (32, 24), destination: rect(0, 0, 24, 32)))

        let sized = SpiceDisplayWire.StreamData.Sized(
            width: 16, height: 12, destination: rect(4, 4, 16, 20)
        )
        let one = try streams.placement(for: data(sized: sized))
        XCTAssertEqual(one.width, 16)
        XCTAssertEqual(one.height, 12)
        XCTAssertEqual(one.destination, rect(4, 4, 16, 20))

        // The stream itself is unchanged, and the next plain frame proves it.
        XCTAssertEqual(streams.streams[1]?.frameWidth, 32)
        let next = try streams.placement(for: data())
        XCTAssertEqual(next.width, 32)
        XCTAssertEqual(next.height, 24)
        XCTAssertEqual(next.destination, rect(0, 0, 24, 32))
    }

    func testASizedFrameWithAnAbsurdSizeIsRefused() throws {
        var streams = SpiceStreams()
        try streams.create(create())
        let sized = SpiceDisplayWire.StreamData.Sized(
            width: 0xFFFF, height: 0xFFFF, destination: rect(0, 0, 1, 1)
        )
        XCTAssertThrowsError(try streams.placement(for: data(sized: sized))) { error in
            XCTAssertEqual(
                error as? SpiceStreams.Failure,
                .unreasonableSize(width: 0xFFFF, height: 0xFFFF)
            )
        }
    }

    func testAFrameForAStreamThatDoesNotExistIsRefused() {
        let streams = SpiceStreams()
        XCTAssertThrowsError(try streams.placement(for: data(id: 8))) { error in
            XCTAssertEqual(error as? SpiceStreams.Failure, .unknownStream(8))
        }
    }

    /// The stream's `TOP_DOWN` is **bit 0 of its own flags byte** — a third
    /// flags byte with its own bit for the same idea. A bitmap's is bit 2, and
    /// a `jpegAlpha`'s is bit 0 of a different byte again.
    func testTheStreamFlagsTopDownIsBitZero() throws {
        var streams = SpiceStreams()
        try streams.create(create(id: 1, flags: 0x01))
        try streams.create(create(id: 2, flags: 0x00))
        try streams.create(create(id: 3, flags: 0x04))
        XCTAssertEqual(streams.streams[1]?.topDown, true)
        XCTAssertEqual(streams.streams[2]?.topDown, false)
        XCTAssertEqual(streams.streams[3]?.topDown, false, "0x04 est le bit d'un bitmap")
    }

    // MARK: - The wire

    func testStreamCreateReadsBothPairsOfDimensionsInOrder() throws {
        func u32(_ value: UInt32) -> [UInt8] { (0..<4).map { UInt8(value >> (8 * $0) & 0xFF) } }
        var payload: [UInt8] = []
        payload += u32(2)                                     // surface
        payload += u32(7)                                     // stream id
        payload += [0x01, 0x01]                               // flags, codec: MJPEG
        payload += u32(0xDEAD_BEEF) + u32(0)                  // stamp, 64 bits
        payload += u32(320) + u32(240)                        // stream size
        payload += u32(640) + u32(480)                        // source size
        payload += u32(10) + u32(20) + u32(250) + u32(660)    // dest: top left bottom right
        payload += [0]                                        // clip: none

        let decoded = try SpiceDisplayWire.streamCreate(payload)
        XCTAssertEqual(decoded.surfaceID, 2)
        XCTAssertEqual(decoded.id, 7)
        XCTAssertEqual(decoded.codec, .mjpeg)
        XCTAssertTrue(decoded.topDown)
        XCTAssertEqual(decoded.stamp, 0xDEAD_BEEF)
        XCTAssertEqual(decoded.streamWidth, 320)
        XCTAssertEqual(decoded.streamHeight, 240)
        XCTAssertEqual(decoded.sourceWidth, 640)
        XCTAssertEqual(decoded.sourceHeight, 480)
        XCTAssertEqual(decoded.destination, rect(10, 20, 250, 660))
    }

    func testACodecThisClientDoesNotKnowAtAllIsRefused() {
        func u32(_ value: UInt32) -> [UInt8] { (0..<4).map { UInt8(value >> (8 * $0) & 0xFF) } }
        var payload: [UInt8] = []
        payload += u32(0) + u32(1) + [0x00, 0x63]              // codec 99
        payload += u32(0) + u32(0) + u32(8) + u32(8) + u32(8) + u32(8)
        payload += u32(0) + u32(0) + u32(8) + u32(8) + [0]
        XCTAssertThrowsError(try SpiceDisplayWire.streamCreate(payload))
    }

    /// **The sized form inserts three fields between the header and the
    /// length.** Read with the plain shape, the width becomes the frame length.
    func testTheSizedFormIsNotThePlainFormWithExtraFieldsAtTheEnd() throws {
        func u32(_ value: UInt32) -> [UInt8] { (0..<4).map { UInt8(value >> (8 * $0) & 0xFF) } }
        var payload: [UInt8] = []
        payload += u32(5)                                     // stream id
        payload += u32(99)                                    // multimedia time
        payload += u32(16) + u32(12)                          // width, height
        payload += u32(1) + u32(2) + u32(13) + u32(18)        // dest
        payload += u32(3)                                     // data size
        payload += [0xAA, 0xBB, 0xCC]

        let sized = try SpiceDisplayWire.streamData(payload, sized: true)
        XCTAssertEqual(sized.id, 5)
        XCTAssertEqual(sized.multimediaTime, 99)
        XCTAssertEqual(sized.sized?.width, 16)
        XCTAssertEqual(sized.sized?.height, 12)
        XCTAssertEqual(sized.sized?.destination, rect(1, 2, 13, 18))
        XCTAssertEqual(sized.frame, [0xAA, 0xBB, 0xCC])

        // The same bytes read as a plain frame take the width for the length
        // and hand back sixteen bytes that are not the frame.
        let plain = try SpiceDisplayWire.streamData(payload, sized: false)
        XCTAssertNil(plain.sized)
        XCTAssertEqual(plain.frame.count, 16, "seize octets qui ne sont pas l'image")
        XCTAssertNotEqual(plain.frame, sized.frame)
    }

    func testAPlainFrameIsHeaderLengthAndBytes() throws {
        func u32(_ value: UInt32) -> [UInt8] { (0..<4).map { UInt8(value >> (8 * $0) & 0xFF) } }
        let payload = u32(4) + u32(77) + u32(2) + [0x10, 0x20]
        let decoded = try SpiceDisplayWire.streamData(payload, sized: false)
        XCTAssertEqual(decoded.id, 4)
        XCTAssertEqual(decoded.multimediaTime, 77)
        XCTAssertNil(decoded.sized)
        XCTAssertEqual(decoded.frame, [0x10, 0x20])
        XCTAssertThrowsError(try SpiceDisplayWire.streamData(Array(payload.dropLast()), sized: false))
    }

    /// **Only MJPEG is decoded**, and the other four are named rather than
    /// lumped into "unknown" — "the server chose H.264" is an explanation a
    /// user could act on, where "unsupported stream" is not.
    ///
    /// Asserted on the *property* rather than on `frame(_:codec:)`, because a
    /// sabotage showed the function's own check to be unobservable: a VP8 frame
    /// is not valid JPEG, so feeding it to the decoder returns `nil` exactly as
    /// refusing it does. That is a real equivalence, not a missing test, and
    /// the check stays for a different reason — it keeps arbitrary stream bytes
    /// away from the platform's image decoder. Pulled out here, the *decision*
    /// is a value, and all five codecs can be checked without decoding
    /// anything.
    func testOnlyMJPEGIsDecodedAndTheOtherFourAreNamed() {
        XCTAssertEqual(SpiceDisplayWire.VideoCodec.allCases.count, 5)
        for codec in SpiceDisplayWire.VideoCodec.allCases {
            XCTAssertEqual(codec.isDecoded, codec == .mjpeg, "\(codec)")
        }
        for codec in [SpiceDisplayWire.VideoCodec.vp8, .h264, .vp9, .h265] {
            XCTAssertNil(try? SpiceDisplayWire.frame(data(), codec: codec), "\(codec)")
        }
        XCTAssertNoThrow(try SpiceDisplayWire.frame(data(), codec: .mjpeg))
    }
}
