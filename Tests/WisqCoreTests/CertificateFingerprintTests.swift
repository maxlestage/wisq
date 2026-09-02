import Foundation
import XCTest

@testable import WisqCore

/// The fingerprint as people paste it. Every spelling a terminal or a browser
/// produces is read; the one thing refused is a digest that is not thirty-two
/// bytes, because that is not a fingerprint in another coat.
final class CertificateFingerprintTests: XCTestCase {
    private let bytes = Data((0..<32).map { UInt8($0 * 7 + 3) })

    private var colons: String { bytes.map { String(format: "%02X", $0) }.joined(separator: ":") }
    private var bare: String { bytes.map { String(format: "%02x", $0) }.joined() }

    func testOpensslsOwnLineIsRead() {
        XCTAssertEqual(CertificateFingerprint.parse("sha256 Fingerprint=" + colons), bytes)
        XCTAssertEqual(CertificateFingerprint.parse("SHA256 Fingerprint=" + colons + "\n"), bytes)
    }

    func testColonsCaseAndWhitespaceAreTypography() {
        XCTAssertEqual(CertificateFingerprint.parse(colons), bytes)
        XCTAssertEqual(CertificateFingerprint.parse(colons.lowercased()), bytes)
        XCTAssertEqual(CertificateFingerprint.parse(bare), bytes, "la forme du lien d'appairage")
        XCTAssertEqual(CertificateFingerprint.parse("  " + bare.uppercased() + "  "), bytes)
        // A browser's copy, wrapped by a mail client.
        let wrapped = String(colons.prefix(47)) + "\n" + String(colons.dropFirst(47))
        XCTAssertEqual(CertificateFingerprint.parse(wrapped), bytes)
    }

    /// Thirty-one bytes, thirty-three bytes, a MD5 or a SHA-1: none of them is
    /// what the transport compares, and accepting one would be a pin that
    /// can never match.
    func testTheWrongLengthIsNotAFingerprint() {
        XCTAssertNil(CertificateFingerprint.parse(String(bare.dropLast(2))))
        XCTAssertNil(CertificateFingerprint.parse(bare + "ab"))
        XCTAssertNil(CertificateFingerprint.parse("d41d8cd98f00b204e9800998ecf8427e"), "un MD5")
        XCTAssertNil(CertificateFingerprint.parse(""))
    }

    func testNonHexIsRefused() {
        XCTAssertNil(CertificateFingerprint.parse(String(bare.dropLast(2)) + "zz"))
        XCTAssertNil(CertificateFingerprint.parse("sha256 Fingerprint="))
    }

    /// The shown form is what a person compares against a browser, and it
    /// reads back to the same bytes.
    func testTheShownFormRoundTrips() {
        XCTAssertEqual(CertificateFingerprint.format(bytes), colons)
        XCTAssertEqual(CertificateFingerprint.parse(CertificateFingerprint.format(bytes)), bytes)
    }
}
