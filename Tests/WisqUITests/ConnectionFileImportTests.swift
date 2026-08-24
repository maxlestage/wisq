import Foundation
import WisqCore
import WisqUI
import XCTest

/// Reading a connection file, checked on the platform that ships.
///
/// These duplicate assertions that `WisqCoreTests` already makes on Linux, and
/// that is the point. What they check does not live in wisq's own code: the
/// byte order mark handling rests on what Foundation does while decoding, and
/// Foundation on Darwin and Foundation on Linux are two implementations. A
/// green Linux run says nothing about the phone, and the phone is where the
/// file actually gets opened.
final class ConnectionFileImportTests: XCTestCase {
    private let rdp = """
    full address:s:rdp.example.net:3390
    username:s:ana
    screen mode id:i:2
    """

    /// The one that matters: Windows' own client saves `.rdp` as UTF-16
    /// little-endian with a mark, so these are most of the files anyone will
    /// try to import.
    func testAnRDPFileSavedByWindowsInUTF16IsRead() throws {
        var bytes = Data([0xFF, 0xFE])
        bytes.append(contentsOf: Array(rdp.utf16).flatMap {
            [UInt8($0 & 0xFF), UInt8($0 >> 8)]
        })
        let imported = try ConnectionImport.machine(fromContentsOf: bytes)
        XCTAssertEqual(imported.machine.host, "rdp.example.net")
        XCTAssertEqual(imported.machine.port, 3390)
    }

    /// wisq carries no code for this — Foundation strips the mark itself. That
    /// is a fact about Foundation on *this* platform, so it is checked here
    /// rather than assumed from the Linux run.
    func testAUTF8MarkDoesNotBecomePartOfTheFirstKey() throws {
        var bytes = Data([0xEF, 0xBB, 0xBF])
        bytes.append(rdp.data(using: .utf8)!)
        XCTAssertEqual(
            try ConnectionImport.machine(fromContentsOf: bytes).machine.host,
            "rdp.example.net"
        )
    }

    /// A password read from a file must not end up inside the machine, because
    /// the machine is `Codable` and gets written to disk. Checked here too: on
    /// the phone that file is real, and so is the leak.
    func testThePasswordIsNeverInsideTheMachineThatGetsWrittenToDisk() throws {
        let ticket = "valeur-de-test-sans-aucun-secret"
        let imported = try ConnectionImport.machine(fromContentsOf: """
        [virt-viewer]
        host=spice.example.net
        port=5900
        password=\(ticket)
        """)
        XCTAssertEqual(imported.password, ticket)

        let encoded = try JSONEncoder().encode(imported.machine)
        let json = String(data: encoded, encoding: .utf8) ?? ""
        XCTAssertFalse(json.contains(ticket), "le mot de passe est écrit sur le disque : \(json)")
        XCTAssertNil(imported.machine.credentialRef)
    }

    /// The imported ticket has to survive being put in front of the user.
    ///
    /// The editor writes the secret only when its field was *edited*, so that
    /// opening an existing machine and saving does not wipe the password it
    /// already has. An imported password is filled in and never touched, which
    /// is exactly the shape that rule drops — and dropping it creates a machine
    /// with no credential, so connecting asks for a password the user does not
    /// have: it was a one-shot ticket from a server, not something they chose.
    @MainActor
    func testAnImportedPasswordIsMarkedForSavingEvenThoughNobodyTypedIt() throws {
        let imported = try ConnectionImport.machine(fromContentsOf: """
        [virt-viewer]
        host=spice.example.net
        port=5900
        password=valeur-de-test-sans-aucun-secret
        """)
        let draft = MachineDraft(imported: imported)

        XCTAssertEqual(draft.password, "valeur-de-test-sans-aucun-secret")
        XCTAssertTrue(draft.passwordCameFilledIn, "sinon le ticket est perdu à l'enregistrement")
    }

    /// A file with no password must not set the flag: it would make saving
    /// write an empty secret over one the machine already had.
    @MainActor
    func testAFileWithNoPasswordDoesNotMarkAnythingForSaving() throws {
        let imported = try ConnectionImport.machine(fromContentsOf: """
        [virt-viewer]
        host=spice.example.net
        port=5900
        """)
        let draft = MachineDraft(imported: imported)
        XCTAssertEqual(draft.password, "")
        XCTAssertFalse(draft.passwordCameFilledIn)
    }

    /// An import is a new machine even though it arrives filled in. Read as an
    /// existing one, the sheet heads itself with the host name and the file
    /// passes for something the user had saved before.
    @MainActor
    func testAnImportIsANewMachineRatherThanOneTheLibraryAlreadyHolds() throws {
        let imported = try ConnectionImport.machine(fromContentsOf: rdp)
        XCTAssertTrue(MachineDraft(imported: imported).isNew)
    }
}
