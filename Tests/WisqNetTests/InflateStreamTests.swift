import XCTest
@testable import WisqNet

final class InflateStreamTests: XCTestCase {
    /// Two rectangles' worth of data from one server-side deflate stream, each
    /// terminated by a sync flush — exactly how an RFB server emits them.
    private static let firstChunk = Data([
        0x78, 0x9C, 0xCA, 0x49, 0x2D, 0x56, 0x48, 0xCE, 0xC8, 0x4C, 0xCD, 0x2B, 0x56, 0x48,
        0x4C, 0xCA, 0x07, 0xD2, 0x25, 0x3A, 0x0A, 0x00, 0x00, 0x00, 0x00, 0xFF, 0xFF,
    ])
    private static let secondChunk = Data([
        0xCA, 0xC1, 0x26, 0x96, 0xA8, 0x90, 0x9C, 0x58, 0x94, 0x58, 0x96, 0x98, 0x97, 0xAA,
        0x50, 0x90, 0x58, 0x5C, 0x9C, 0x0A, 0x00, 0x00, 0x00, 0xFF, 0xFF,
    ])

    func testInflatesASingleChunk() throws {
        let inflater = try InflateStream()
        let output = try inflater.inflate(Self.firstChunk)
        XCTAssertEqual(String(data: output, encoding: .utf8), "les chiens aboient, ")
    }

    /// The dictionary has to carry across rectangles — that is where RFB's
    /// compression ratio comes from, and restarting per rectangle would lose it.
    func testDictionaryPersistsAcrossChunks() throws {
        let inflater = try InflateStream()
        _ = try inflater.inflate(Self.firstChunk)
        let output = try inflater.inflate(Self.secondChunk)

        XCTAssertEqual(String(data: output, encoding: .utf8), "les chiens aboient, la caravane passe")
        // 36 bytes of text in 25 bytes of stream: the second chunk is only that
        // small because it references the first.
        XCTAssertLessThan(Self.secondChunk.count, output.count)
    }

    func testResetDropsTheDictionary() throws {
        let inflater = try InflateStream()
        _ = try inflater.inflate(Self.firstChunk)
        try inflater.reset()
        // Without the first chunk's header and dictionary, the second is garbage.
        XCTAssertThrowsError(try inflater.inflate(Self.secondChunk))
    }

    func testEmptyInputIsNotAnError() throws {
        let inflater = try InflateStream()
        XCTAssertEqual(try inflater.inflate(Data()), Data())
    }

    func testCorruptDataThrows() throws {
        let inflater = try InflateStream()
        XCTAssertThrowsError(try inflater.inflate(Data([0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x11])))
    }
}
