import XCTest
@testable import WisqCore

/// What a connection actually checks, as opposed to what it was asked to check.
final class ResolvedTransportSecurityTests: XCTestCase {
    private let fingerprint = Data(repeating: 0xAB, count: 32)

    func testPlainStaysPlain() {
        XCTAssertEqual(ResolvedTransportSecurity.resolve(.none, fingerprint: nil), .plain)
    }

    func testPlainIgnoresAFingerprintItWasNotAskedFor() {
        XCTAssertEqual(ResolvedTransportSecurity.resolve(.none, fingerprint: fingerprint), .plain)
    }

    func testOrdinaryTLSIsValidatedByTheSystem() {
        XCTAssertEqual(ResolvedTransportSecurity.resolve(.tls, fingerprint: nil), .systemValidated)
    }

    func testAPinWithSomethingToPinToIsAPin() {
        XCTAssertEqual(
            ResolvedTransportSecurity.resolve(.tlsPinned, fingerprint: fingerprint),
            .pinned(fingerprint))
    }

    /// The whole point. Every machine connection lands here today, because no
    /// saved machine can carry a fingerprint.
    func testAPinWithNothingToPinToFallsBackToFullValidationAndNotToTrustingAnything() {
        XCTAssertEqual(
            ResolvedTransportSecurity.resolve(.tlsPinned, fingerprint: nil),
            .systemValidated)
    }

    /// An empty `Data` is not a fingerprint. It would compare equal to nothing
    /// a server can present, so it is a pin that always fails rather than a pin;
    /// it reaches here from a decoded field that was written as empty.
    func testAnEmptyFingerprintIsNotAFingerprint() {
        XCTAssertEqual(
            ResolvedTransportSecurity.resolve(.tlsPinned, fingerprint: Data()),
            .systemValidated)
    }

    /// The certificate is checked in every mode but plain — the property a
    /// caller would reach for to decide whether to warn.
    func testOnlyPlainSkipsTheCertificateEntirely() {
        XCTAssertFalse(ResolvedTransportSecurity.plain.validatesCertificate)
        XCTAssertTrue(ResolvedTransportSecurity.systemValidated.validatesCertificate)
        XCTAssertTrue(ResolvedTransportSecurity.pinned(fingerprint).validatesCertificate)
    }

    /// Two different pins are two different things: the case has to carry its
    /// fingerprint, not merely remember that there was one.
    func testAPinIsNotEqualToADifferentPin() {
        XCTAssertNotEqual(
            ResolvedTransportSecurity.pinned(fingerprint),
            ResolvedTransportSecurity.pinned(Data(repeating: 0xCD, count: 32)))
    }
}
