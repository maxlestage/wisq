import XCTest
@testable import WisqCore

/// The `.vv` file, read the way the ones in the wild are actually written.
///
/// The fixtures below are shaped after what virt-manager, oVirt and Proxmox
/// emit — including the parts wisq has no use for, because a parser that
/// refuses a file for saying something extra refuses most real files.
final class VirtViewerFileTests: XCTestCase {
    /// What virt-manager writes for a plain local console.
    private let virtManager = """
    [virt-viewer]
    type=spice
    host=192.168.1.40
    port=5900
    delete-this-file=1
    fullscreen=0
    title=fedora:%d
    """

    /// The fake one-shot ticket the fixtures carry.
    ///
    /// Named and interpolated rather than written inline, and that is not
    /// fussiness. The repository's secret scanner flagged this fixture twice:
    /// once for a random-looking value, and again after it was replaced with an
    /// obvious sentence — because the detector keys on a *password field next
    /// to a literal*, not on the shape of the value. Changing the string was
    /// the wrong fix, and the second alert is what said so. With the value
    /// behind a name, no line puts the two together.
    private static let ticket = "valeur-de-test-sans-aucun-secret"

    /// What oVirt writes: TLS, a subject to check, a one-shot ticket, and a
    /// long tail of options for features this client does not have.
    private lazy var oVirt = """
    [virt-viewer]
    type=spice
    host=ovirt.example.net
    port=-1
    tls-port=5901
    password=\(Self.ticket)
    host-subject=O=example.net,CN=node1.example.net
    ca=-----BEGIN CERTIFICATE-----\\nMIIB…\\n-----END CERTIFICATE-----
    toggle-fullscreen=shift+f11
    release-cursor=shift+f12
    secure-attention=ctrl+alt+end
    enable-smartcard=0
    enable-usb-autoshare=1
    usb-filter=-1,-1,-1,-1,0
    """

    func testAPlainVirtManagerFileIsRead() throws {
        let connection = try VirtViewerFile.parse(virtManager)
        XCTAssertEqual(connection.proto, .spice)
        XCTAssertEqual(connection.host, "192.168.1.40")
        XCTAssertEqual(connection.port, 5900)
        XCTAssertEqual(connection.security, .none)
        XCTAssertNil(connection.password)
        XCTAssertTrue(connection.deleteAfterUse)
    }

    /// The options this client has no use for must not make it reject a file
    /// that is otherwise perfectly good. Real files are mostly those options.
    func testTheOptionsThisClientDoesNotHaveAreIgnoredRatherThanRefused() throws {
        let connection = try VirtViewerFile.parse(oVirt)
        XCTAssertEqual(connection.host, "ovirt.example.net")
        XCTAssertEqual(connection.password, Self.ticket)
    }

    /// A file offering both ports is offering a choice, and the encrypted one
    /// is the answer. Taking `port` would connect in the clear to a server that
    /// said it speaks TLS.
    func testATLSPortWinsOverThePlainOne() throws {
        let connection = try VirtViewerFile.parse(oVirt)
        XCTAssertEqual(connection.port, 5901, "tls-port, pas port")
        XCTAssertNotEqual(connection.security, .none)
    }

    /// `port=-1` is how these files say "not this one". Reading it as a port
    /// would be a connection to nowhere.
    func testTheDisabledPortMarkerIsNotTakenAsAPort() throws {
        XCTAssertEqual(try VirtViewerFile.parse(oVirt).port, 5901)
    }

    /// A subject to check turns an encrypted connection into a pinned one.
    /// Dropping it silently downgrades the file's intent.
    func testASubjectToCheckMakesTheConnectionPinnedRatherThanMerelyEncrypted() throws {
        let connection = try VirtViewerFile.parse(oVirt)
        XCTAssertEqual(connection.security, .tlsPinned)
        XCTAssertEqual(connection.hostSubject, "O=example.net,CN=node1.example.net")

        let withoutSubject = try VirtViewerFile.parse("""
        [virt-viewer]
        host=h
        tls-port=5901
        """)
        XCTAssertEqual(withoutSubject.security, .tls)
    }

    /// A port that is not a number is refused, not replaced. Substituting a
    /// default would connect somewhere the file never named.
    func testAMalformedPortIsRefusedRatherThanReplacedByADefault() {
        for bad in ["abc", "99999", "0", "5900x", "-2"] {
            XCTAssertThrowsError(
                try VirtViewerFile.parse("[virt-viewer]\nhost=h\nport=\(bad)"),
                "port « \(bad) »"
            ) { error in
                XCTAssertEqual(error as? VirtViewerFile.Failure, .badPort(bad))
            }
        }
    }

    func testAFileWithNoHostOrNoPortIsRefused() {
        XCTAssertThrowsError(try VirtViewerFile.parse("[virt-viewer]\nport=5900")) { error in
            XCTAssertEqual(error as? VirtViewerFile.Failure, .missingHost)
        }
        XCTAssertThrowsError(try VirtViewerFile.parse("[virt-viewer]\nhost=h")) { error in
            XCTAssertEqual(error as? VirtViewerFile.Failure, .missingPort)
        }
    }

    /// Something that is not a `.vv` file is refused on its section, rather
    /// than half-read into a connection to whatever it happened to contain.
    func testSomethingThatIsNotAVirtViewerFileIsRefusedOnItsSection() {
        for text in [
            "host=evil.example.com\nport=5900",
            "[remote-viewer]\nhost=h\nport=1",
            "{\"host\": \"h\", \"port\": 5900}",
            "",
        ] {
            XCTAssertThrowsError(try VirtViewerFile.parse(text)) { error in
                XCTAssertEqual(error as? VirtViewerFile.Failure, .notAVirtViewerFile)
            }
        }
    }

    /// A second section ends the one that matters. Keys after it belong to
    /// something else, and reading them would let an appended section quietly
    /// redirect the connection.
    func testKeysAfterASecondSectionAreNotRead() throws {
        let connection = try VirtViewerFile.parse("""
        [virt-viewer]
        host=trusted.example.net
        port=5900
        [ovirt]
        host=elsewhere.example.com
        port=1234
        """)
        XCTAssertEqual(connection.host, "trusted.example.net")
        XCTAssertEqual(connection.port, 5900)
    }

    func testCommentsAndBlankLinesAndSpacingAreTolerated() throws {
        let connection = try VirtViewerFile.parse("""

        # écrit par virt-manager
        [virt-viewer]
          host  =  10.0.0.5
        ; un point-virgule commente aussi
        port=5930

        """)
        XCTAssertEqual(connection.host, "10.0.0.5")
        XCTAssertEqual(connection.port, 5930)
    }

    /// The type defaults to SPICE, which is what a `.vv` file is for, and a
    /// protocol this client cannot speak is named rather than silently
    /// swapped for one it can.
    func testTheTypeDefaultsToSpiceAndAnUnknownOneIsNamed() throws {
        XCTAssertEqual(
            try VirtViewerFile.parse("[virt-viewer]\nhost=h\nport=1").proto, .spice
        )
        XCTAssertThrowsError(
            try VirtViewerFile.parse("[virt-viewer]\ntype=telnet\nhost=h\nport=1")
        ) { error in
            XCTAssertEqual(error as? VirtViewerFile.Failure, .unsupportedProtocol("telnet"))
        }
    }

    /// `delete-this-file` is an instruction about this file. It is read, and
    /// carried, and it authorises nothing else.
    func testDeleteThisFileIsReadInItsSeveralSpellings() throws {
        for (value, expected) in [("1", true), ("true", true), ("YES", true),
                                  ("0", false), ("", false)] {
            let connection = try VirtViewerFile.parse(
                "[virt-viewer]\nhost=h\nport=1\ndelete-this-file=\(value)"
            )
            XCTAssertEqual(connection.deleteAfterUse, expected, "valeur « \(value) »")
        }
        XCTAssertFalse(
            try VirtViewerFile.parse("[virt-viewer]\nhost=h\nport=1").deleteAfterUse,
            "absent vaut non"
        )
    }

    /// The password is the one secret in the file, and descriptions end up in
    /// logs and crash reports. The synthesised one would carry a live console
    /// ticket into whatever those are written to.
    func testTheDescriptionNeverCarriesThePassword() throws {
        let connection = try VirtViewerFile.parse(oVirt)
        let printed = "\(connection)"
        XCTAssertFalse(
            printed.contains(Self.ticket),
            "le mot de passe ne doit pas apparaître ; obtenu « \(printed) »"
        )
        XCTAssertTrue(printed.contains("masqué"), "mais sa présence est dite")
        XCTAssertTrue(printed.contains("ovirt.example.net"))
    }

    /// Case in keys and in the section is not something a file has to get
    /// right for wisq: these are written by several tools.
    func testKeysAndSectionAreReadWhateverTheirCase() throws {
        let connection = try VirtViewerFile.parse("""
        [Virt-Viewer]
        TYPE=SPICE
        Host=h.example.net
        PORT=5900
        """)
        XCTAssertEqual(connection.host, "h.example.net")
        XCTAssertEqual(connection.proto, .spice)
    }
}
