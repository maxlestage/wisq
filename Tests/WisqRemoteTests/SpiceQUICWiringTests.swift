import XCTest
@testable import WisqRemote

/// `.quic` on the display channel's own entry point.
///
/// The codec being right is one thing and the message path reaching it is
/// another. `lzPalette` was finished and unreachable for a while — the decoder
/// existed, `pixels(of:)` fell through to `default` and returned nil, and every
/// codec test passed. These tests are about the second half.
final class SpiceQUICWiringTests: XCTestCase {
    func testEveryFixtureReachesTheDecoderThroughTheDisplayChannel() throws {
        for fixture in SpiceQUICFixtures.all {
            let image = quicImage(fixture)
            guard let decoded = try SpiceDisplayWire.pixels(of: image) else {
                XCTFail("\(fixture.name) : rien dessiné, donc rien de branché")
                continue
            }
            XCTAssertEqual(decoded.width, fixture.width, fixture.name)
            XCTAssertEqual(decoded.height, fixture.height, fixture.name)
            XCTAssertEqual(
                decoded.pixels.count, fixture.width * fixture.height * 4, fixture.name
            )
            XCTAssertEqual(
                decoded.pixels, try SpiceQUIC.decode(SpiceQUICFixtures.bytes(fixture.stream)).pixels,
                "\(fixture.name) : le chemin du canal doit donner exactement ce que le codec donne"
            )
        }
    }

    /// `gray` is drawn here where `canvas_get_quic` refuses it.
    ///
    /// A deliberate difference, and one worth pinning: the reference's refusal
    /// comes from its pixman path having no gray format, not from the protocol.
    /// If this ever starts returning nil it is a regression, not a correction.
    func testAGrayStreamIsDrawnRatherThanDroppedAsTheReferenceDropsIt() throws {
        let gray = try XCTUnwrap(SpiceQUICFixtures.all.first { $0.type == .gray })
        let decoded = try XCTUnwrap(
            try SpiceDisplayWire.pixels(of: quicImage(gray)),
            "le décodeur sait le faire, donc il le fait"
        )
        XCTAssertEqual(decoded.width, gray.width)
        XCTAssertEqual(decoded.height, gray.height)
    }

    /// The message says a size and the stream says a size, and the reference
    /// asserts they agree before it allocates. Two halves describing different
    /// pictures is not a picture.
    func testASizeThatContradictsTheMessageIsNotDrawn() throws {
        let fixture = SpiceQUICFixtures.all[0]
        var image = quicImage(fixture)
        image = SpiceDisplayWire.Image(
            descriptor: SpiceDisplayWire.ImageDescriptor(
                id: 1, type: .quic, flags: 0,
                width: UInt32(fixture.width + 1), height: UInt32(fixture.height)
            ),
            bitmap: nil, payload: SpiceQUICFixtures.bytes(fixture.stream)
        )
        XCTAssertNil(try SpiceDisplayWire.pixels(of: image), "les deux moitiés se contredisent")
    }

    /// **QUIC carries no orientation.** Its header stops at type, width and
    /// height, and `canvas_get_quic` consults no flag and reverses nothing.
    ///
    /// The bitmap flag word sits right beside it in the message, and a reader
    /// who reaches for it there gets every QUIC image upside down. Setting
    /// `TOP_DOWN` — bit 2 — must change nothing at all.
    func testTheBitmapFlagsBesideItDoNotTurnTheImageOver() throws {
        let fixture = SpiceQUICFixtures.all[1]
        let payload = SpiceQUICFixtures.bytes(fixture.stream)
        var decoded: [[UInt8]] = []
        for flags: UInt8 in [0, 0x04] {
            let image = SpiceDisplayWire.Image(
                descriptor: SpiceDisplayWire.ImageDescriptor(
                    id: 1, type: .quic, flags: flags,
                    width: UInt32(fixture.width), height: UInt32(fixture.height)
                ),
                bitmap: nil, payload: payload
            )
            decoded.append(try XCTUnwrap(try SpiceDisplayWire.pixels(of: image)).pixels)
        }
        XCTAssertEqual(decoded[0], decoded[1], "aucun drapeau extérieur ne retourne du QUIC")
    }

    /// A payload that is not QUIC at all throws rather than drawing something.
    func testAPayloadThatIsNotQUICIsRefused() {
        let image = SpiceDisplayWire.Image(
            descriptor: SpiceDisplayWire.ImageDescriptor(
                id: 1, type: .quic, flags: 0, width: 8, height: 6
            ),
            bitmap: nil, payload: [UInt8](repeating: 0x41, count: 64)
        )
        XCTAssertThrowsError(try SpiceDisplayWire.pixels(of: image))
    }

    private func quicImage(_ fixture: SpiceQUICFixtures.Case) -> SpiceDisplayWire.Image {
        SpiceDisplayWire.Image(
            descriptor: SpiceDisplayWire.ImageDescriptor(
                id: 1, type: .quic, flags: 0,
                width: UInt32(fixture.width), height: UInt32(fixture.height)
            ),
            bitmap: nil, payload: SpiceQUICFixtures.bytes(fixture.stream)
        )
    }
}
