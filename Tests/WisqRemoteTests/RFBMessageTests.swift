import XCTest
import WisqCore
@testable import WisqRemote

final class RFBMessageTests: XCTestCase {
    func testPointerMessageLayout() {
        let data = VNCSession.pointerMessage(x: 300, y: 200, buttons: [.left])
        XCTAssertEqual([UInt8](data), [5, 0b0000_0001, 0x01, 0x2C, 0x00, 0xC8])
    }

    func testKeyMessageLayout() {
        let data = VNCSession.keyMessage(keysym: 0xFF0D, down: true)
        XCTAssertEqual([UInt8](data), [4, 1, 0, 0, 0x00, 0x00, 0xFF, 0x0D])
    }

    func testUpdateRequestLayout() {
        let data = VNCSession.updateRequestMessage(
            incremental: true,
            rect: Rect(x: 0, y: 0, width: 1024, height: 768)
        )
        XCTAssertEqual([UInt8](data), [3, 1, 0, 0, 0, 0, 0x04, 0x00, 0x03, 0x00])
    }

    func testPixelFormatIsBGRA32() {
        let bytes = [UInt8](PixelFormat.bgra32.encoded)
        XCTAssertEqual(bytes.count, 16)
        XCTAssertEqual(bytes[0], 32)     // bits per pixel
        XCTAssertEqual(bytes[1], 24)     // depth
        XCTAssertEqual(bytes[2], 0)      // little endian
        XCTAssertEqual(bytes[3], 1)      // true colour
        XCTAssertEqual(bytes[10], 16)    // red shift
        XCTAssertEqual(bytes[12], 0)     // blue shift
    }

    func testPixelFormatDecodeIsTheInverseOfEncode() throws {
        let decoded = try PixelFormat.decode(PixelFormat.bgra32.encoded)
        XCTAssertEqual(decoded, .bgra32)
    }

    /// Guard rail: a rectangle in an unknown encoding has no length prefix, so
    /// advertising one we cannot decode strands the stream with no way back.
    /// This list must grow every time a decoder does.
    func testAdvertisedEncodingsAreAllDecodable() {
        let decodable: Set<Int32> = [
            RFB.Encoding.raw.rawValue,
            RFB.Encoding.copyRect.rawValue,
            RFB.Encoding.rre.rawValue,
            RFB.Encoding.hextile.rawValue,
            RFB.Encoding.zlib.rawValue,
            RFB.Encoding.tight.rawValue,
            RFB.Encoding.zrle.rawValue,
            RFB.Encoding.cursor.rawValue,
            RFB.Encoding.continuousUpdates.rawValue,
            RFB.Encoding.desktopSize.rawValue,
            RFB.Encoding.extendedDesktopSize.rawValue,
            RFB.Encoding.desktopName.rawValue,
            RFB.Encoding.lastRect.rawValue,
        ]
        // Advertising something we cannot decode would strand the stream mid-rectangle.
        //
        // The two settings ranges are exempt, and only those two. A value in
        // them is a request — how lossy, how hard to compress — and never comes
        // back as a rectangle, so there is nothing to decode. Written as ranges
        // rather than added to the set above so that a *new* pseudo-encoding
        // still has to be justified rather than quietly slipping through.
        func isSettingRatherThanRectangle(_ encoding: Int32) -> Bool {
            (RFB.qualityLevel...(RFB.qualityLevel + 9)).contains(encoding)
                || (RFB.compressLevel...(RFB.compressLevel + 9)).contains(encoding)
        }
        for lowBandwidth in [false, true] {
            for quality in [nil, 6] as [Int?] {
                for encoding in RFB.preferredEncodings(
                    lowBandwidth: lowBandwidth, jpegQuality: quality
                ) {
                    XCTAssertTrue(
                        decodable.contains(encoding) || isSettingRatherThanRectangle(encoding),
                        "encodage annoncé mais non décodable : \(encoding)"
                    )
                }
            }
        }
    }

    // MARK: - Le niveau de compression

    /// A slow link asks for more effort than the server's default; a fast one
    /// asks for nothing and lets the server keep it.
    func testOnlyASlowLinkAsksForACompressionLevel() {
        let slow = RFB.preferredEncodings(lowBandwidth: true)
        let fast = RFB.preferredEncodings(lowBandwidth: false)
        let range = RFB.compressLevel...(RFB.compressLevel + 9)

        XCTAssertEqual(
            slow.filter { range.contains($0) }, [RFB.compressLevel + 6],
            "un lien lent demande le niveau 6"
        )
        XCTAssertTrue(
            fast.filter { range.contains($0) }.isEmpty,
            "un lien rapide laisse au serveur son propre défaut"
        )
    }

    /// **Never zero and never one**, whatever else changes.
    ///
    /// `VNCSConnectionST::getComparerState` reads a level below two as "this
    /// client wants CPU over bandwidth" and turns off the comparing update
    /// tracker — the server stops checking whether a region actually changed
    /// before sending it. Asking for less compression would fetch more data.
    /// The number above is a judgement; this is not.
    func testTheLevelAskedForNeverTurnsOffTheServersChangeDetection() {
        for lowBandwidth in [false, true] {
            for quality in [nil, 0, 9] as [Int?] {
                let advertised = RFB.preferredEncodings(
                    lowBandwidth: lowBandwidth, jpegQuality: quality
                )
                for level in [0, 1] {
                    XCTAssertFalse(
                        advertised.contains(RFB.compressLevel + Int32(level)),
                        "niveau \(level) annoncé : le serveur cesserait de comparer"
                    )
                }
            }
        }
    }

    /// One level, or the server picks between them by an order nothing here
    /// states. `ClientParams::setEncodings` walks the list **backwards**, so
    /// two compression levels would silently mean the earlier one — a rule this
    /// client should not be relying on.
    func testAtMostOneOfEachSettingIsAdvertised() {
        for lowBandwidth in [false, true] {
            for quality in [nil, 3] as [Int?] {
                let advertised = RFB.preferredEncodings(
                    lowBandwidth: lowBandwidth, jpegQuality: quality
                )
                XCTAssertLessThanOrEqual(
                    advertised.filter {
                        (RFB.compressLevel...(RFB.compressLevel + 9)).contains($0)
                    }.count, 1
                )
                XCTAssertLessThanOrEqual(
                    advertised.filter {
                        (RFB.qualityLevel...(RFB.qualityLevel + 9)).contains($0)
                    }.count, 1
                )
                XCTAssertEqual(
                    advertised.count, Set(advertised).count,
                    "un encodage annoncé deux fois"
                )
            }
        }
    }

    /// The four numbers that come from outside this repository, written out.
    ///
    /// Every other test here is expressed relative to `compressLevel` and
    /// `qualityLevel` — `compressLevel + 6`, "inside the quality range" — which
    /// means a wrong base moves the expectations with it and nothing notices.
    /// Sabotage said so plainly: shifting either base by one left the whole
    /// suite green. The quality base looked pinned by `JPEGTests`, but that
    /// test skips wherever there is no JPEG decoder, which is every Linux
    /// runner here.
    ///
    /// So the bases are asserted as literals, against the reference:
    /// `pseudoEncodingQualityLevel0 = -32` and `QualityLevel9 = -23`,
    /// `pseudoEncodingCompressLevel0 = -256` and `CompressLevel9 = -247`, in
    /// TigerVNC's `common/rfb/encodings.h`. Both ends of each range, because
    /// the reference states both — so a base that slipped and a range that is
    /// the wrong width fail separately rather than cancelling out.
    func testTheTwoBasesAreTheReferencesAndNotThisFilesArithmetic() {
        XCTAssertEqual(RFB.qualityLevel, -32)
        XCTAssertEqual(RFB.qualityLevel + 9, -23)
        XCTAssertEqual(RFB.compressLevel, -256)
        XCTAssertEqual(RFB.compressLevel + 9, -247)
        XCTAssertEqual(RFB.compressLevel + Int32(RFB.slowLinkCompression), -250)
    }

    /// The two ranges do not overlap each other, nor any encoding this build
    /// advertises as a rectangle codec. They are ten apart in the reference and
    /// two hundred apart from each other; a transcription slip in either base
    /// would land one range on top of something real.
    func testTheTwoSettingRangesCollideWithNothing() {
        let quality = Set((RFB.qualityLevel...(RFB.qualityLevel + 9)))
        let compress = Set((RFB.compressLevel...(RFB.compressLevel + 9)))
        XCTAssertTrue(quality.isDisjoint(with: compress))
        for encoding in RFB.Encoding.allCases {
            XCTAssertFalse(quality.contains(encoding.rawValue), "\(encoding)")
            XCTAssertFalse(compress.contains(encoding.rawValue), "\(encoding)")
        }
    }

    func testCutTextEncodesLatin1() {
        let data = VNCSession.cutTextMessage("café")
        XCTAssertEqual(data[0], 6)
        let length = UInt32(data[4]) << 24 | UInt32(data[5]) << 16 | UInt32(data[6]) << 8 | UInt32(data[7])
        XCTAssertEqual(length, 4)
        XCTAssertEqual(data[data.count - 1], 0xE9)   // é in latin-1
    }

    func testCutTextKeepsWhatItCanWhenTheTextIsNotLatin1() {
        // The spec is latin-1 only. Losing one emoji must not drop the whole paste.
        XCTAssertEqual(VNCSession.latin1Payload("café 🚀"), Data([0x63, 0x61, 0x66, 0xE9, 0x20, 0x3F]))
    }

    func testCutTextStripsCarriageReturns() {
        // RFB mandates LF-only line endings; a CR left in place confuses guests.
        XCTAssertEqual(VNCSession.latin1Payload("a\r\nb"), Data([0x61, 0x0A, 0x62]))
    }
}
