import XCTest
@testable import WisqRemote

/// The decode loop, against whole images.
///
/// This is the one part of QUIC with no exact partial check available. The
/// header, the family tables, the bit reader and the model could each be
/// compared against the reference number for number; a decode loop can only be
/// compared on what it produces. So it is compared on all of it: every fixture,
/// every byte, against what SPICE's own decoder made of the same stream.
final class SpiceQUICDecodeTests: XCTestCase {
    func testEveryStreamDecodesToWhatTheReferenceDecoderProduced() throws {
        for fixture in SpiceQUICFixtures.all {
            let stream = SpiceQUICFixtures.bytes(fixture.stream)
            let expected = SpiceQUICFixtures.bytes(fixture.decoded)

            let decoded: (pixels: [UInt8], width: Int, height: Int)
            do {
                decoded = try SpiceQUIC.decode(stream)
            } catch {
                XCTFail("\(fixture.name) : \(error)")
                continue
            }

            XCTAssertEqual(decoded.width, fixture.width, fixture.name)
            XCTAssertEqual(decoded.height, fixture.height, fixture.name)

            // Gray comes out of the reference as one byte per pixel; this
            // decoder always produces BGRA, so the comparison is per channel.
            //
            // The fourth byte is compared only for `rgba`, the one type that
            // carries alpha. For the others the reference leaves that byte at
            // zero — an invisible picture — and this decoder deliberately
            // writes 0xFF instead, so it is checked against 0xFF rather than
            // against the reference.
            let bytesPerReferencePixel = expected.count / (fixture.width * fixture.height)
            let channelsCompared = fixture.type == .rgba ? 4 : 3
            var mismatch: String?
            for pixel in 0..<(fixture.width * fixture.height) where mismatch == nil {
                if bytesPerReferencePixel == 1 {
                    let want = expected[pixel]
                    for channel in 0..<3 where decoded.pixels[pixel * 4 + channel] != want {
                        mismatch = "pixel \(pixel) canal \(channel): "
                            + "\(decoded.pixels[pixel * 4 + channel]) au lieu de \(want)"
                    }
                } else {
                    for channel in 0..<channelsCompared
                    where decoded.pixels[pixel * 4 + channel] != expected[pixel * 4 + channel] {
                        mismatch = "pixel \(pixel) canal \(channel): "
                            + "\(decoded.pixels[pixel * 4 + channel]) "
                            + "au lieu de \(expected[pixel * 4 + channel])"
                    }
                }
                if fixture.type != .rgba, decoded.pixels[pixel * 4 + 3] != 0xFF {
                    mismatch = "pixel \(pixel) alpha : "
                        + "\(decoded.pixels[pixel * 4 + 3]) au lieu de 255"
                }
            }
            XCTAssertNil(mismatch, "\(fixture.name) (\(fixture.note)) : \(mismatch ?? "")")
        }
    }
}
