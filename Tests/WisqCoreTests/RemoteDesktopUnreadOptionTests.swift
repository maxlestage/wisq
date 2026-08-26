import XCTest

@testable import WisqCore

/// An `.rdp` was refused whole because of a field nobody reads.
///
/// `VirtViewerFile` states the rule for `.vv`: unknown keys ignored, malformed
/// *what we read* refused — "failing on the first one would reject perfectly
/// good files for saying something extra". This parser stated the strict half
/// and applied it to every `i` line, including the forty Windows and an RD
/// Gateway write for features wisq does not have.
final class RemoteDesktopUnreadOptionTests: XCTestCase {
    /// Shaped like what a gateway actually writes. `gatewaycredentialssource`
    /// with an empty value is legal in those files and is the line that used to
    /// throw.
    private let fromAGateway = """
        full address:s:bureau.exemple.net:3390
        username:s:ana
        screen mode id:i:2
        desktopwidth:i:1920
        desktopheight:i:1080
        audiomode:i:0
        redirectclipboard:i:1
        gatewaycredentialssource:i:
        promptcredentialonce:i:0
        """

    func testAGatewayFileIsReadDespiteAnOptionWisqNeverLooksAt() throws {
        let connection = try RemoteDesktopFile.parse(fromAGateway)
        XCTAssertEqual(connection.host, "bureau.exemple.net")
        XCTAssertEqual(connection.port, 3390)
        XCTAssertEqual(connection.username, "ana")
        XCTAssertEqual(connection.width, 1920)
        XCTAssertEqual(connection.height, 1080)
        XCTAssertTrue(connection.fullScreen)
        XCTAssertTrue(connection.redirectClipboard)
    }

    /// The other edge, and the half that must not be lost: a value wisq *does*
    /// read is still refused when it is not a number, because substituting a
    /// default there would describe a screen the file did not name.
    func testAMalformedValueWisqActuallyReadsIsStillRefused() {
        for key in ["desktopwidth", "desktopheight", "screen mode id", "redirectclipboard"] {
            let text = "full address:s:hôte.exemple\n\(key):i:grand"
            XCTAssertThrowsError(try RemoteDesktopFile.parse(text), "clé lue : \(key)") { error in
                XCTAssertEqual(
                    error as? RemoteDesktopFile.Failure,
                    .badInteger(key: key, value: "grand"))
            }
        }
    }

    /// A discarded option is still evidence the file is an `.rdp`. Dropping the
    /// value must not also drop that, or a file whose only lines wisq ignores
    /// would come back as "not one of ours" rather than as one missing its
    /// address.
    func testAFileOfOnlyIgnoredOptionsIsStillRecognisedAsAnRDPFile() {
        XCTAssertThrowsError(try RemoteDesktopFile.parse("audiomode:i:0\nuse multimon:i:1")) {
            XCTAssertEqual(
                $0 as? RemoteDesktopFile.Failure, .missingAddress,
                "reconnu comme .rdp, mais sans adresse")
        }
    }

    /// And something that is not an `.rdp` at all still says so.
    func testProseIsNotAnRDPFile() {
        XCTAssertThrowsError(try RemoteDesktopFile.parse("bonjour\nceci n'est pas un fichier")) {
            XCTAssertEqual($0 as? RemoteDesktopFile.Failure, .notARemoteDesktopFile)
        }
    }

    /// The ignored value is ignored, not silently coerced to something.
    func testAnIgnoredOptionLeavesNoTrace() throws {
        let connection = try RemoteDesktopFile.parse(
            "full address:s:hôte.exemple\ndesktopwidth:i:800\naudiomode:i:")
        XCTAssertEqual(connection.width, 800)
        XCTAssertNil(connection.height)
    }
}
