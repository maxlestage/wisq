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

        // Asserted on the settings themselves rather than on a substring of
        // the encoded machine, which is how this test used to read and which
        // made it flaky about once in a few dozen runs.
        //
        // `Machine` encodes a `createdAt` date as a floating-point number and
        // an `id` as hex, and both change from run to run. Either can contain
        // "2560" or "1440" by coincidence, and when it does the test fails
        // having found nothing wrong. A tight loop hides it — the timestamp's
        // digits barely move — so it only ever showed up on runs minutes
        // apart, which is the worst way for a test to be wrong.
        //
        // The real claim is narrower and exact: `DisplaySettings` has no width
        // or height at all, so the file's geometry has nowhere to go, and what
        // the import produces is the default.
        let imported = ConnectionImport.machine(from: file)
        XCTAssertEqual(
            imported.machine.display, DisplaySettings(),
            "l'import ne fait pas de la géométrie du fichier une préférence"
        )
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

    // MARK: - Choosing a reader

    private let vvText = """
    [virt-viewer]
    type=spice
    host=spice.example.net
    port=5900
    """

    private let rdpText = """
    full address:s:rdp.example.net:3390
    username:s:ana
    screen mode id:i:2
    """

    /// The contents decide, and that is the whole point: these files arrive by
    /// mail and by AirDrop, where the name is chosen by the sender. If the
    /// extension picked the parser, the sender would be picking it.
    func testTheContentsChooseTheReaderRatherThanTheFileName() throws {
        XCTAssertEqual(ConnectionImport.kind(of: vvText), .virtViewer)
        XCTAssertEqual(ConnectionImport.kind(of: rdpText), .remoteDesktop)

        let fromVV = try ConnectionImport.machine(fromContentsOf: vvText)
        XCTAssertEqual(fromVV.machine.host, "spice.example.net")
        XCTAssertEqual(fromVV.machine.proto, .spice)

        let fromRDP = try ConnectionImport.machine(fromContentsOf: rdpText)
        XCTAssertEqual(fromRDP.machine.host, "rdp.example.net")
        XCTAssertEqual(fromRDP.machine.port, 3390)
        XCTAssertEqual(fromRDP.machine.proto, .rdp)
    }

    /// A `.vv` file carries lines with colons in them — `title=fedora:%d` is
    /// the common one. None of them is a `key:type:value` triple, and this
    /// checks that none of them is mistaken for one.
    func testAVirtViewerFileIsNotMistakenForARemoteDesktopOne() {
        XCTAssertEqual(ConnectionImport.kind(of: """
        [virt-viewer]
        host=h.example.net
        port=5900
        title=fedora:%d
        toggle-fullscreen=shift+f11
        """), .virtViewer)
    }

    /// Text that is neither is named as neither, rather than handed to a parser
    /// to see what falls out. What falls out of a parser given arbitrary text
    /// is a connection to somewhere nobody asked for.
    func testSomethingThatIsNeitherKindIsRefusedRatherThanGuessedAt() {
        // The last one is a triple with no key. `key:type:value` needs the
        // key; without it the line names nothing, and a file made only of
        // those names nothing either.
        for text in ["", "bonjour", "{\"host\": \"h\"}", "host=h\nport=5900", ":s:x"] {
            XCTAssertNil(ConnectionImport.kind(of: text), "« \(text) »")
            XCTAssertThrowsError(try ConnectionImport.machine(fromContentsOf: text)) { error in
                XCTAssertEqual(error as? ConnectionImport.Failure, .unrecognisedFile)
            }
        }
    }

    /// Once the contents have said which kind of file this is, the reader's own
    /// complaint is what the user needs to see. Flattening it into
    /// "unrecognised" would hide the one sentence that says what to fix.
    func testTheReadersOwnFailureIsPassedThroughRatherThanFlattened() {
        XCTAssertThrowsError(
            try ConnectionImport.machine(fromContentsOf: "[virt-viewer]\nhost=h\nport=abc")
        ) { error in
            XCTAssertEqual(error as? VirtViewerFile.Failure, .badPort("abc"))
        }
        XCTAssertThrowsError(
            try ConnectionImport.machine(fromContentsOf: "username:s:ana\nscreen mode id:i:2")
        ) { error in
            XCTAssertEqual(error as? RemoteDesktopFile.Failure, .missingAddress)
        }
    }

    // MARK: - Bytes

    /// The one that matters most in practice. Windows' own client saves `.rdp`
    /// files as UTF-16 little-endian with a byte order mark, so a reader that
    /// only speaks UTF-8 fails on the files the dominant tool writes — which
    /// is most of the files anyone will ever try to import.
    func testAnRDPFileSavedByWindowsInUTF16IsRead() throws {
        var bytes = Data([0xFF, 0xFE])
        bytes.append(contentsOf: Array(rdpText.utf16).flatMap {
            [UInt8($0 & 0xFF), UInt8($0 >> 8)]
        })

        // First, the point: read as UTF-8 those bytes are not this file.
        XCTAssertNotEqual(String(data: bytes, encoding: .utf8), rdpText)

        let imported = try ConnectionImport.machine(fromContentsOf: bytes)
        XCTAssertEqual(imported.machine.host, "rdp.example.net")
        XCTAssertEqual(imported.machine.port, 3390)
    }

    func testABigEndianMarkIsReadTheOtherWayRound() throws {
        var bytes = Data([0xFE, 0xFF])
        bytes.append(contentsOf: Array(rdpText.utf16).flatMap {
            [UInt8($0 >> 8), UInt8($0 & 0xFF)]
        })
        XCTAssertEqual(try ConnectionImport.machine(fromContentsOf: bytes).machine.host,
                       "rdp.example.net")
    }

    /// A UTF-8 mark is legal and Notepad writes it. Left in the text it would
    /// become an invisible first character of the first key, so the first line
    /// would stop being recognised — here, the one line the file cannot do
    /// without.
    ///
    /// There is no code in `text(from:)` for this: a branch was written, and
    /// removing it changed nothing, because Foundation strips a leading UTF-8
    /// mark itself. The test stays anyway. It guards the behaviour rather than
    /// the branch, and the behaviour is now resting on what Foundation does —
    /// which is exactly the kind of thing worth having a test sitting on.
    func testAUTF8MarkIsDroppedRatherThanBecomingPartOfTheFirstKey() throws {
        var bytes = Data([0xEF, 0xBB, 0xBF])
        bytes.append(rdpText.data(using: .utf8)!)
        XCTAssertEqual(try ConnectionImport.machine(fromContentsOf: bytes).machine.host,
                       "rdp.example.net")
    }

    func testPlainUTF8WithNoMarkIsStillTheDefault() throws {
        let bytes = vvText.data(using: .utf8)!
        XCTAssertEqual(try ConnectionImport.machine(fromContentsOf: bytes).machine.host,
                       "spice.example.net")
    }

    /// Bytes that are not text in any of these encodings are named as such
    /// rather than reported as an unrecognised file: it points at a different
    /// problem, and at a different thing for the user to try.
    func testBytesThatAreNotTextAreNamedAsSuch() {
        let bytes = Data([0xFF, 0xFF, 0xC0, 0x80, 0xED, 0xA0, 0x80])
        XCTAssertThrowsError(try ConnectionImport.machine(fromContentsOf: bytes)) { error in
            XCTAssertEqual(error as? ConnectionImport.Failure, .unreadableEncoding)
        }
    }

    // MARK: - Saying what went wrong

    /// Every failure either reader can produce has a sentence of its own.
    ///
    /// Written as a walk over the whole list rather than a few spot checks,
    /// because the failure this guards against is a new case being added to a
    /// reader and quietly falling through to `localizedDescription` — which,
    /// for a Swift enum with no `LocalizedError`, is a type name and a case
    /// name in English.
    func testEveryFailureTheReadersCanProduceHasItsOwnSentence() {
        let failures: [Error] = [
            ConnectionImport.Failure.unrecognisedFile,
            ConnectionImport.Failure.unreadableEncoding,
            VirtViewerFile.Failure.notAVirtViewerFile,
            VirtViewerFile.Failure.missingHost,
            VirtViewerFile.Failure.missingPort,
            VirtViewerFile.Failure.badPort("abc"),
            VirtViewerFile.Failure.unsupportedProtocol("telnet"),
            RemoteDesktopFile.Failure.notARemoteDesktopFile,
            RemoteDesktopFile.Failure.missingAddress,
            RemoteDesktopFile.Failure.badPort("abc"),
            RemoteDesktopFile.Failure.badInteger(key: "desktopwidth", value: "large"),
        ]

        for failure in failures {
            let message = ConnectionImport.message(for: failure)
            XCTAssertFalse(message.isEmpty, "\(failure)")
            // `localizedDescription` for these enums is the type and case name.
            // If a message is that, the case fell through the switch.
            XCTAssertNotEqual(message, failure.localizedDescription, "\(failure) : non traduit")
            XCTAssertFalse(message.contains("Failure"), "\(failure) : nom de type visible")
        }

        // The values the file gave are quoted back, so the user can see which
        // line to look at rather than being told only that something is wrong.
        XCTAssertTrue(
            ConnectionImport.message(for: VirtViewerFile.Failure.badPort("99999")).contains("99999")
        )
        XCTAssertTrue(
            ConnectionImport.message(for: RemoteDesktopFile.Failure.badInteger(
                key: "desktopwidth", value: "large"
            )).contains("desktopwidth")
        )
    }

    /// Anything else — a file that could not be read off the disk, most often —
    /// keeps its own text, which says more than a sentence invented here.
    func testAnErrorFromSomewhereElseKeepsItsOwnText() {
        let error = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError)
        XCTAssertEqual(ConnectionImport.message(for: error), error.localizedDescription)
    }
}
