import XCTest

@testable import WisqCore

/// The host check every other way of making a machine already applied.
///
/// The editor runs `Validation.normalizedHost` on what the user typed,
/// `AgentPairing` on what a QR carried, `AgentImportView` on a typed address.
/// The connection-file path did not — the one whose input is the least
/// trustworthy of the four, since these files arrive from Mail, from AirDrop,
/// from a share sheet, chosen by whoever sent them.
final class ImportHostValidationTests: XCTestCase {
    private func imported(_ text: String) throws -> ConnectionImport.Imported {
        try ConnectionImport.machine(fromContentsOf: Data(text.utf8))
    }

    private func rdp(host: String) -> String {
        "full address:s:\(host)\nscreen mode id:i:2"
    }

    private func vv(host: String) -> String {
        "[virt-viewer]\ntype=spice\nhost=\(host)\nport=5900"
    }

    // MARK: - Refused, and refused where the file is opened

    func testAnRDPHostWithAPathIsRefused() {
        XCTAssertThrowsError(try imported(rdp(host: "exemple.net/../autre"))) {
            XCTAssertEqual($0 as? WisqError, .invalidHost("exemple.net/../autre"))
        }
    }

    func testAnRDPHostWithASpaceIsRefused() {
        XCTAssertThrowsError(try imported(rdp(host: "bureau interne"))) {
            XCTAssertEqual($0 as? WisqError, .invalidHost("bureau interne"))
        }
    }

    func testAVirtViewerHostWithASpaceIsRefused() {
        XCTAssertThrowsError(try imported(vv(host: "hôte interne"))) {
            XCTAssertEqual($0 as? WisqError, .invalidHost("hôte interne"))
        }
    }

    /// The reason for moving the check here rather than leaving it at connect
    /// time: what the person is shown names the address, on the screen where
    /// they can still choose another file.
    func testTheRefusalNamesTheAddress() {
        let message = ConnectionImport.message(for: WisqError.invalidHost("exemple.net/../autre"))
        XCTAssertTrue(
            message.contains("exemple.net/../autre"),
            "le message montré ne nomme pas l'adresse : \(message)")
    }

    // MARK: - The other edge: what must still come through

    func testAnOrdinaryRDPHostStillImports() throws {
        let machine = try imported("full address:s:bureau.exemple.net:3390").machine
        XCTAssertEqual(machine.host, "bureau.exemple.net")
        XCTAssertEqual(machine.port, 3390)
    }

    func testAnOrdinaryVirtViewerHostStillImports() throws {
        XCTAssertEqual(try imported(vv(host: "console.exemple.net")).machine.host, "console.exemple.net")
    }

    /// A bracketed IPv6 literal survives both the parser and the check. Brackets
    /// are stripped, not treated as the punctuation a bare host may not contain.
    func testABracketedIPv6AddressStillImports() throws {
        let machine = try imported("full address:s:[2001:db8::1]:3390").machine
        XCTAssertEqual(machine.host, "2001:db8::1")
        XCTAssertEqual(machine.port, 3390)
    }

    // MARK: - Normalised, not merely checked

    /// `normalizedHost` returns a value, and that value is what gets saved.
    ///
    /// A sabotage that kept the check and discarded its result survived every
    /// other test here, because the two parsers happen to hand over hosts that
    /// are already clean. These two do not: a `.vv` writes whatever is after
    /// `host=`, brackets included, and `.rdp` keeps the spaces between its
    /// second colon and the value. Without them, a machine could be saved with
    /// a host no other path would ever produce.
    func testAVirtViewerBracketedAddressIsSavedWithoutItsBrackets() throws {
        XCTAssertEqual(try imported(vv(host: "[2001:db8::1]")).machine.host, "2001:db8::1")
    }

    func testAnRDPAddressKeepsNoLeadingSpace() throws {
        XCTAssertEqual(
            try imported("full address:s:   bureau.exemple.net").machine.host,
            "bureau.exemple.net")
    }

    /// A `.local` name is what a machine on the same Wi-Fi is actually called,
    /// and it must not be mistaken for something malformed.
    func testABonjourNameStillImports() throws {
        XCTAssertEqual(try imported(rdp(host: "bureau.local")).machine.host, "bureau.local")
    }
}
