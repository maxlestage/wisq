import Foundation
import WisqCore
import XCTest

@testable import WisqNet

#if canImport(CryptoKit)
import CryptoKit
#endif

/// The digest wisq's certificate pinning rests on, held to an outside answer.
///
/// Two files in this repository already name `WisqNet.SHA256` as the shape to
/// avoid — it returned empty `Data` without CryptoKit, so, as `SpiceLink` puts
/// it, "a digest built on it passes its tests by agreeing with itself about
/// nothing". This file is the other half of that sentence: every expected value
/// below comes from outside wisq, either from FIPS 180-4 itself or from
/// OpenSSL, and on Apple from CryptoKit standing next to the fallback on the
/// same bytes.
final class SHA256Tests: XCTestCase {
    private func hex(_ data: Data) -> String { Hex.encode(data) }

    // MARK: - The published vectors

    /// The three example messages from FIPS 180-4, digests included.
    func testThePublishedVectors() {
        XCTAssertEqual(
            hex(SHA256.pure(Data("abc".utf8))),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(
            hex(SHA256.pure(Data("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8))),
            "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
        XCTAssertEqual(
            hex(
                SHA256.pure(
                    Data(
                        ("abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmn"
                            + "hijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu").utf8))),
            "cf5b16a778af8380036ce59e7b0492370b249b11e8f07a51afac45037afee9d1")
    }

    /// The empty message, which is only interesting because of what this file
    /// used to return for *every* message on Linux.
    func testTheEmptyMessageHasADigestAndItIsNotNothing() {
        XCTAssertEqual(
            hex(SHA256.pure(Data())),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    /// Every length either side of the two places padding decides something: 55
    /// bytes is the last that fits its length word in the same block, 56 forces
    /// a second one, and 64 is a whole block with nothing left over.
    ///
    /// This is where a hand-written SHA-256 goes wrong, and it goes wrong
    /// *quietly*: append the length after growing the buffer instead of before
    /// and short messages stay right while everything past 55 bytes silently
    /// is not.
    func testTheLengthsWherePaddingChangesItsMind() {
        let expected: [Int: String] = [
            54: "a3f01b6939256127582ac8ae9fb47a382a244680806a3f613a118851c1ca1d47",
            55: "9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318",
            56: "b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a",
            57: "f13b2d724659eb3bf47f2dd6af1accc87b81f09f59f2b75e5c0bed6589dfe8c6",
            63: "7d3e74a05d7db15bce4ad9ec0658ea98e3f06eeecf16b4c6fff2da457ddc2f34",
            64: "ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb",
            65: "635361c48bb9eab14198e76ea8ab7f1a41685d6ad62aa9146d301d4f17eb0ae0",
            119: "31eba51c313a5c08226adf18d4a359cfdfd8d2e816b13f4af952f7ea6584dcfb",
            120: "2f3d335432c70b580af0e8e1b3674a7c020d683aa5f73aaaedfdc55af904c21c",
            127: "c57e9278af78fa3cab38667bef4ce29d783787a2f731d4e12200270f0c32320a",
            128: "6836cf13bac400e9105071cd6af47084dfacad4e5e302c94bfed24e013afb73e",
            129: "c12cb024a2e5551cca0e08fce8f1c5e314555cc3fef6329ee994a3db752166ae",
            1000: "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3",
        ]
        for (count, digest) in expected.sorted(by: { $0.key < $1.key }) {
            XCTAssertEqual(
                hex(SHA256.pure(Data(repeating: UInt8(ascii: "a"), count: count))), digest,
                "\(count) octets")
        }
    }

    /// Bytes rather than text, so the schedule sees every value a byte can take
    /// and not just printable ASCII.
    func testEveryByteValue() {
        XCTAssertEqual(
            hex(SHA256.pure(Data(0...255))),
            "40aff2e9d2d8922e47afd4648e6967497158785fbd1da870e7110266bf944880")
    }

    // MARK: - The hole that was here

    /// The regression, stated as itself: a digest is thirty-two bytes on every
    /// platform this compiles for. It was zero wherever CryptoKit was absent,
    /// and a caller comparing it to a pinned fingerprint got "not equal" for a
    /// reason that had nothing to do with the certificate.
    func testADigestIsThirtyTwoBytesEverywhere() {
        for message in [Data(), Data("abc".utf8), Data(repeating: 9, count: 200)] {
            XCTAssertEqual(SHA256.digest(message).count, 32)
        }
    }

    /// The control this file would be worthless without: the probe can tell two
    /// things apart. A digest function stuck on any constant — empty `Data`
    /// included — would satisfy "thirty-two bytes" and every equality above
    /// that compared it to itself.
    func testDifferentMessagesGiveDifferentDigests() {
        let digests = Set(
            [Data(), Data("abc".utf8), Data("abd".utf8), Data(repeating: 0, count: 64)]
                .map { SHA256.digest($0) })
        XCTAssertEqual(digests.count, 4)
    }

    // MARK: - The two implementations, on the same bytes

    #if canImport(CryptoKit)
    /// Where both exist, they must agree — otherwise the fallback is a second
    /// opinion rather than the same function, and the platform that uses it
    /// would pin against a different certificate than the platform that does
    /// not.
    func testTheFallbackAgreesWithCryptoKit() {
        for count in [0, 1, 55, 56, 63, 64, 65, 191, 192, 1000] {
            let message = Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
            XCTAssertEqual(
                SHA256.pure(message), Data(CryptoKit.SHA256.hash(data: message)),
                "\(count) octets")
        }
    }
    #endif

    // MARK: - The string the link is written in

    /// `fingerprintString` rendered `AA:BB:CC…` and had no callers, which is how
    /// it stayed wrong: the first one would have produced a string this project's
    /// own parser refuses. The agent writes `&fp=` with `{byte:02x}`, so this is
    /// the format, and `crates/wisq-agent/src/tls.rs` pins the Rust side to the
    /// same digest of the same input.
    func testTheFingerprintStringIsTheFormTheLinkCarries() {
        let rendered = SHA256.fingerprintString(Data("abc".utf8))
        XCTAssertEqual(
            rendered, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertFalse(rendered.contains(":"), "un séparateur qu'aucun lecteur du projet n'attend")
        XCTAssertEqual(rendered, rendered.lowercased())
    }

    /// And the string survives the trip: what this renders is what
    /// `AgentPairing` accepts as a fingerprint, at the length it demands.
    func testWhatItRendersIsWhatThePairingLinkAccepts() throws {
        let fingerprint = SHA256.digest(Data("un certificat".utf8))
        let payload = AgentPairing.Payload(
            host: "nas.local", certificateFingerprint: fingerprint)
        let url = try XCTUnwrap(AgentPairing.url(for: payload))
        XCTAssertTrue(
            url.absoluteString.hasSuffix("&fp=" + SHA256.fingerprintString(Data("un certificat".utf8))))
        XCTAssertEqual(try AgentPairing.parse(url).certificateFingerprint, fingerprint)
    }
}
