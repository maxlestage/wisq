import XCTest
@testable import WisqCore

/// The `.rdp` file, read the way Windows and the gateways actually write it.
///
/// The fixture below is shaped after what "Save as" in mstsc and what Azure
/// Bastion produce, options and all — a parser that refuses a file for carrying
/// settings this client has no use for refuses nearly every real one.
final class RemoteDesktopFileTests: XCTestCase {
    private let saved = """
    screen mode id:i:2
    use multimon:i:0
    desktopwidth:i:1920
    desktopheight:i:1080
    session bpp:i:32
    full address:s:vm-prod-01.corp.example.net:3390
    username:s:mlestage
    domain:s:CORP
    audiomode:i:0
    redirectclipboard:i:1
    redirectprinters:i:0
    authentication level:i:2
    prompt for credentials:i:0
    gatewayusagemethod:i:0
    """

    func testASavedConnectionIsRead() throws {
        let connection = try RemoteDesktopFile.parse(saved)
        XCTAssertEqual(connection.host, "vm-prod-01.corp.example.net")
        XCTAssertEqual(connection.port, 3390)
        XCTAssertEqual(connection.username, "mlestage")
        XCTAssertEqual(connection.domain, "CORP")
        XCTAssertEqual(connection.width, 1920)
        XCTAssertEqual(connection.height, 1080)
        XCTAssertTrue(connection.fullScreen, "screen mode id 2")
        XCTAssertTrue(connection.redirectClipboard)
    }

    /// Real files are mostly options this client has no use for. Refusing on
    /// the first would refuse nearly every one of them.
    func testTheOptionsThisClientDoesNotHaveAreIgnored() throws {
        XCTAssertNoThrow(try RemoteDesktopFile.parse(saved))
    }

    /// `full address` carries the port after a colon, and the value keeps every
    /// colon it has — which is the whole reason this is a parser rather than a
    /// split on `:`.
    func testTheAddressKeepsItsOwnColons() throws {
        XCTAssertEqual(
            try RemoteDesktopFile.parse("full address:s:host.example.net:3390").port, 3390
        )
        XCTAssertEqual(
            try RemoteDesktopFile.parse("full address:s:host.example.net").port,
            RemoteDesktopFile.defaultPort,
            "sans port donné, le port enregistré de RDP"
        )
    }

    /// `[2001:db8::1]:3389` has five colons and only the last separates a port.
    /// Splitting on any of the others gives a host of `[2001` and a connection
    /// to nowhere.
    func testAnIPv6LiteralIsNotCutAtTheWrongColon() throws {
        let withPort = try RemoteDesktopFile.parse("full address:s:[2001:db8::1]:3390")
        XCTAssertEqual(withPort.host, "2001:db8::1")
        XCTAssertEqual(withPort.port, 3390)

        let withoutPort = try RemoteDesktopFile.parse("full address:s:[2001:db8::1]")
        XCTAssertEqual(withoutPort.host, "2001:db8::1")
        XCTAssertEqual(withoutPort.port, RemoteDesktopFile.defaultPort)
    }

    /// A bare IPv6 literal carries no port. Taking its last group as one would
    /// silently truncate the address and connect somewhere else entirely.
    func testABareIPv6LiteralIsNotTruncatedIntoAHostAndAPort() throws {
        let connection = try RemoteDesktopFile.parse("full address:s:2001:db8::1")
        XCTAssertEqual(connection.host, "2001:db8::1")
        XCTAssertEqual(connection.port, RemoteDesktopFile.defaultPort)
    }

    /// The default port applies when none is given — never in place of one that
    /// could not be read, which would connect somewhere the file did not name.
    func testAMalformedPortIsRefusedRatherThanReplacedByTheDefault() {
        for bad in ["abc", "0", "70000", "-1", "33 90"] {
            XCTAssertThrowsError(
                try RemoteDesktopFile.parse("full address:s:host:\(bad)"), "port « \(bad) »"
            ) { error in
                XCTAssertEqual(error as? RemoteDesktopFile.Failure, .badPort(bad))
            }
        }
    }

    /// `i` says the writer meant a number. A value that is not one is a
    /// malformed file, not an invitation to guess.
    func testAnIntegerFieldHoldingTextIsRefused() {
        XCTAssertThrowsError(
            try RemoteDesktopFile.parse("full address:s:h\ndesktopwidth:i:large")
        ) { error in
            XCTAssertEqual(
                error as? RemoteDesktopFile.Failure,
                .badInteger(key: "desktopwidth", value: "large")
            )
        }
    }

    func testAFileWithNoAddressIsRefused() {
        XCTAssertThrowsError(try RemoteDesktopFile.parse("username:s:someone")) { error in
            XCTAssertEqual(error as? RemoteDesktopFile.Failure, .missingAddress)
        }
    }

    /// Something that is not an `.rdp` file is refused rather than half-read
    /// into a connection to whatever it happened to contain.
    func testSomethingThatIsNotAnRDPFileIsRefused() {
        for text in ["", "hello world", "[virt-viewer]\nhost=h\nport=1"] {
            XCTAssertThrowsError(try RemoteDesktopFile.parse(text)) { error in
                XCTAssertEqual(
                    error as? RemoteDesktopFile.Failure, .notARemoteDesktopFile
                )
            }
        }
    }

    /// The saved password is encrypted to the machine that wrote the file. It
    /// is not decoded, not stored, and not carried — it would be useless here
    /// even if it were, and holding it would only be a liability.
    func testTheSavedPasswordBlobIsNeitherReadNorCarried() throws {
        let withBlob = saved + "\npassword 51:b:01000000D08C9DDF0115D1118C7A00C04FC297EB"
        let connection = try RemoteDesktopFile.parse(withBlob)
        XCTAssertEqual(connection.host, "vm-prod-01.corp.example.net")

        // The count is asserted before the walk, and exactly rather than
        // loosely. A `Mirror` that yielded nothing would make the loop below
        // pass by iterating over an empty sequence — the shape of vacuous test
        // that reads as a guarantee. And pinning the number means a field added
        // later cannot slip past this check unexamined: the test fails and asks
        // whether the new one could carry the blob.
        let mirror = Mirror(reflecting: connection)
        XCTAssertEqual(
            mirror.children.count, 8,
            "le parcours doit voir tous les champs, sinon il ne vérifie rien"
        )
        for child in mirror.children {
            XCTAssertFalse(
                "\(child.value)".contains("D08C9DDF"),
                "aucun champ ne doit porter le blob : \(child.label ?? "?")"
            )
        }
    }

    /// The description ends up in logs. It carries the address and the
    /// geometry, and says nothing about who is connecting.
    func testTheDescriptionNamesNoUser() throws {
        let printed = "\(try RemoteDesktopFile.parse(saved))"
        XCTAssertFalse(printed.contains("mlestage"), "obtenu « \(printed) »")
        XCTAssertFalse(printed.contains("CORP"))
        XCTAssertTrue(printed.contains("vm-prod-01.corp.example.net"))
        XCTAssertTrue(printed.contains("masqué"), "mais la présence d'un utilisateur est dite")
    }

    /// Keys come in whatever case the writing tool felt like, and blank lines
    /// are everywhere in these files.
    func testKeysAreReadWhateverTheirCaseAndBlankLinesAreTolerated() throws {
        let connection = try RemoteDesktopFile.parse("""

        FULL ADDRESS:S:host.example.net

        Screen Mode Id:i:2

        """)
        XCTAssertEqual(connection.host, "host.example.net")
        XCTAssertTrue(connection.fullScreen)
    }

    /// A windowed session is not a full-screen one, and an absent setting is
    /// not either — neither should be read as "yes".
    func testWindowedAndAbsentAreBothNotFullScreen() throws {
        XCTAssertFalse(
            try RemoteDesktopFile.parse("full address:s:h\nscreen mode id:i:1").fullScreen
        )
        XCTAssertFalse(try RemoteDesktopFile.parse("full address:s:h").fullScreen)
    }
}
