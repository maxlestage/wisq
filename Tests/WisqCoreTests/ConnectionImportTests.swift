import XCTest
@testable import WisqCore

/// What a connection file becomes once the app owns it.
///
/// The parsers next door stop at what the file says. These are the decisions
/// about a value wisq did not choose, and each one is a place where carrying
/// the file's word too faithfully would be wrong.
final class ConnectionImportTests: XCTestCase {
    private func spiceFile(password: String? = nil) throws -> VirtViewerFile.Connection {
        var text = """
        [virt-viewer]
        type=spice
        host=console.example.net
        tls-port=5901
        host-subject=CN=console.example.net
        """
        if let password { text += "\npassword=\(password)" }
        return try VirtViewerFile.parse(text)
    }

    // MARK: - The secret

    /// The password comes back beside the machine, never inside it.
    ///
    /// `Machine` is `Codable` and is written to disk. A password reaching it
    /// would be persisted in the clear next to the host it opens — which is the
    /// whole reason this returns a pair instead of one value.
    func testThePasswordTravelsBesideTheMachineAndNeverInsideIt() throws {
        let imported = ConnectionImport.machine(from: try spiceFile(password: "un-ticket"))
        XCTAssertEqual(imported.password, "un-ticket")

        let encoded = try JSONEncoder().encode(imported.machine)
        let json = String(decoding: encoded, as: UTF8.self)
        XCTAssertFalse(
            json.contains("un-ticket"),
            "la machine sérialisée ne doit rien porter du secret ; obtenu \(json)"
        )
    }

    /// And the credential reference stays empty until someone has actually
    /// stored the secret. A machine pointing at a credential that was never
    /// written fails at connect time instead of asking for a password.
    func testTheCredentialReferenceIsNotMintedBeforeTheSecretIsStored() throws {
        let imported = ConnectionImport.machine(from: try spiceFile(password: "x"))
        XCTAssertNil(imported.machine.credentialRef)
    }

    /// An `.rdp` file's saved password is encrypted to the machine that wrote
    /// it. It is not read by the parser, and nothing is invented here to stand
    /// in for it.
    func testAnRDPImportCarriesNoPasswordAtAll() throws {
        let file = try RemoteDesktopFile.parse("""
        full address:s:vm.example.net:3390
        username:s:mlestage
        password 51:b:01000000D08C9DDF
        """)
        let imported = ConnectionImport.machine(from: file)
        XCTAssertNil(imported.password)
        XCTAssertEqual(imported.machine.username, "mlestage")
    }

    // MARK: - What the file says, and what wisq does with it

    func testASpiceFileBecomesASpiceMachineOnItsOwnPortAndTransport() throws {
        let imported = ConnectionImport.machine(from: try spiceFile())
        XCTAssertEqual(imported.machine.proto, .spice)
        XCTAssertEqual(imported.machine.host, "console.example.net")
        XCTAssertEqual(imported.machine.port, 5901, "le port TLS, pas un défaut")
        XCTAssertEqual(imported.machine.security, .tlsPinned)
    }

    /// `.rdp` files do not describe their transport: RDP negotiates TLS inside
    /// the connection. Claiming a `TransportSecurity` here would be inventing a
    /// fact the file does not state.
    func testAnRDPImportClaimsNoTransportTheFileNeverStated() throws {
        let imported = ConnectionImport.machine(
            from: try RemoteDesktopFile.parse("full address:s:vm.example.net")
        )
        XCTAssertEqual(imported.machine.proto, .rdp)
        XCTAssertEqual(imported.machine.security, .none)
        XCTAssertEqual(imported.machine.port, 3389)
    }

    /// The geometry in an `.rdp` file is the monitor of whoever saved it. It is
    /// read by the parser and deliberately not carried into the machine: on a
    /// phone it is somebody else's screen.
    func testTheFilesGeometryIsNotTurnedIntoAPreference() throws {
        let file = try RemoteDesktopFile.parse("""
        full address:s:vm.example.net
        desktopwidth:i:2560
        desktopheight:i:1440
        """)
        XCTAssertEqual(file.width, 2560, "le lecteur rapporte ce que le fichier dit")

        let imported = ConnectionImport.machine(from: file)
        let json = String(decoding: try JSONEncoder().encode(imported.machine), as: UTF8.self)
        XCTAssertFalse(json.contains("2560"), "mais l'import n'en fait pas une préférence")
        XCTAssertFalse(json.contains("1440"))
    }

    /// The host is the name. Titles in these files are things like `fedora:%d`
    /// — a printf template for a window title, not something to show a person.
    func testTheMachineIsNamedAfterItsHost() throws {
        XCTAssertEqual(
            ConnectionImport.machine(from: try spiceFile()).machine.name,
            "console.example.net"
        )
        XCTAssertEqual(ConnectionImport.name(forHost: ""), "Machine importée")
    }

    /// Imported machines are tagged, so a list of thirty can be told apart from
    /// the ones typed by hand.
    func testAnImportedMachineSaysThatItWasImported() throws {
        XCTAssertEqual(ConnectionImport.machine(from: try spiceFile()).machine.tags, ["importé"])
        XCTAssertEqual(
            ConnectionImport.machine(
                from: try RemoteDesktopFile.parse("full address:s:h")
            ).machine.tags,
            ["importé"]
        )
    }

    /// Two imports of the same file are two machines, not one overwriting the
    /// other: the identity is minted here, not read from a file that has none.
    func testEachImportIsItsOwnMachine() throws {
        let first = ConnectionImport.machine(from: try spiceFile())
        let second = ConnectionImport.machine(from: try spiceFile())
        XCTAssertNotEqual(first.machine.id, second.machine.id)
        XCTAssertEqual(first.machine.host, second.machine.host)
    }
}
