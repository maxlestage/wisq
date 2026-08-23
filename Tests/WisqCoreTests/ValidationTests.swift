import XCTest
@testable import WisqCore

final class ValidationTests: XCTestCase {
    func testSplitsHostAndPort() {
        XCTAssertEqual(Validation.splitHostPort("192.168.1.10:5901").host, "192.168.1.10")
        XCTAssertEqual(Validation.splitHostPort("192.168.1.10:5901").port, 5901)
    }

    func testBareHostHasNoPort() {
        let result = Validation.splitHostPort("nas.local")
        XCTAssertEqual(result.host, "nas.local")
        XCTAssertNil(result.port)
    }

    func testBracketedIPv6WithPort() {
        let result = Validation.splitHostPort("[fe80::1]:5900")
        XCTAssertEqual(result.host, "fe80::1")
        XCTAssertEqual(result.port, 5900)
    }

    func testBareIPv6IsNotSplitOnItsColons() {
        let result = Validation.splitHostPort("fe80::1")
        XCTAssertEqual(result.host, "fe80::1")
        XCTAssertNil(result.port)
    }

    func testRejectsEmptyAndPathLikeHosts() {
        XCTAssertThrowsError(try Validation.normalizedHost("   "))
        XCTAssertThrowsError(try Validation.normalizedHost("http://host/x"))
    }

    func testRejectsOutOfRangePorts() {
        XCTAssertThrowsError(try Validation.validatedPort(0))
        XCTAssertThrowsError(try Validation.validatedPort(70000))
        XCTAssertEqual(try Validation.validatedPort(5900), 5900)
    }
}
