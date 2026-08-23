import XCTest
@testable import WisqRemote

final class DESTests: XCTestCase {
    /// The worked example from the FIPS 46-3 literature: if this passes, the
    /// permutation tables, the key schedule and the S-boxes are all correct.
    func testKnownVector() {
        let key: [UInt8] = [0x13, 0x34, 0x57, 0x79, 0x9B, 0xBC, 0xDF, 0xF1]
        let plaintext: [UInt8] = [0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF]
        let expected: [UInt8] = [0x85, 0xE8, 0x13, 0x54, 0x0F, 0x0A, 0xB4, 0x05]

        XCTAssertEqual(DES.encryptBlock(plaintext, key: key), expected)
    }

    func testAllZeroKeyAndBlock() {
        let zero = [UInt8](repeating: 0, count: 8)
        let expected: [UInt8] = [0x8C, 0xA6, 0x4D, 0xE9, 0xC1, 0xB1, 0x23, 0xA7]
        XCTAssertEqual(DES.encryptBlock(zero, key: zero), expected)
    }

    func testBitReversalMatchesTheVNCQuirk() {
        XCTAssertEqual(VNCAuth.reverseBits(0b1000_0000), 0b0000_0001)
        XCTAssertEqual(VNCAuth.reverseBits(0b0100_1100), 0b0011_0010)
        XCTAssertEqual(VNCAuth.reverseBits(0xFF), 0xFF)
    }

    func testChallengeResponseIsSixteenBytes() {
        let challenge = Data((0..<16).map { UInt8($0) })
        XCTAssertEqual(VNCAuth.response(challenge: challenge, password: "secret").count, 16)
    }

    func testPasswordLongerThanEightBytesIsTruncated() {
        let challenge = Data((0..<16).map { UInt8($0) })
        let short = VNCAuth.response(challenge: challenge, password: "12345678")
        let long = VNCAuth.response(challenge: challenge, password: "123456789abc")
        XCTAssertEqual(short, long)
    }
}
