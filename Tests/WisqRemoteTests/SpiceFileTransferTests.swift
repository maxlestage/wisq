import Foundation
import XCTest
@testable import WisqRemote

/// The wire half of sending a file to the guest.
///
/// The start payload is held to GLib's own output — `scripts/
/// spice-file-xfer-fixtures/gen.c` links GLib and prints what
/// `g_key_file_to_data` produces, because the agent parses these bytes with
/// GLib and a fixture written by the serialiser's author would only confirm
/// the same guess twice. The escaping GLib actually does is narrower and
/// stranger than one would write from memory: a tab in the middle travels
/// raw, a backslash ends the leading-blank run, an escaped newline leaves it
/// open.
final class SpiceFileTransferTests: XCTestCase {
    /// `<label> <name> <size> <hex>` rows, verbatim from running `gen.c`.
    private static let glibFixtures: [(String, String, UInt64, String)] = [
        ("plain", "notes.txt", 5,
         "5b76646167656e742d66696c652d786665725d0a6e616d653d6e6f7465732e7478740a73697a653d350a00"),
        ("utf8", "café été.txt", 1234567890123,
         "5b76646167656e742d66696c652d786665725d0a6e616d653d636166c3a920c3a974c3a92e7478740a73697a653d313233343536373839303132330a00"),
        ("space-inside", "mon fichier.txt", 0,
         "5b76646167656e742d66696c652d786665725d0a6e616d653d6d6f6e20666963686965722e7478740a73697a653d300a00"),
        ("leading-space", " garde.txt", 7,
         "5b76646167656e742d66696c652d786665725d0a6e616d653d5c7367617264652e7478740a73697a653d370a00"),
        ("backslash", "a\\b.txt", 42,
         "5b76646167656e742d66696c652d786665725d0a6e616d653d615c5c622e7478740a73697a653d34320a00"),
        ("equals", "a=b.txt", 1,
         "5b76646167656e742d66696c652d786665725d0a6e616d653d613d622e7478740a73697a653d310a00"),
        ("brackets", "[section].txt", 2,
         "5b76646167656e742d66696c652d786665725d0a6e616d653d5b73656374696f6e5d2e7478740a73697a653d320a00"),
        ("hash", "#pas-un-commentaire", 3,
         "5b76646167656e742d66696c652d786665725d0a6e616d653d237061732d756e2d636f6d6d656e74616972650a73697a653d330a00"),
        ("tab", "avant\tapres.txt", 4,
         "5b76646167656e742d66696c652d786665725d0a6e616d653d6176616e740961707265732e7478740a73697a653d340a00"),
        ("newline", "ligne\ncoupee.txt", 9,
         "5b76646167656e742d66696c652d786665725d0a6e616d653d6c69676e655c6e636f757065652e7478740a73697a653d390a00"),
        ("carriage", "avant\rapres.txt", 9,
         "5b76646167656e742d66696c652d786665725d0a6e616d653d6176616e745c7261707265732e7478740a73697a653d390a00"),
        ("trailing-space", "fin .txt ", 9,
         "5b76646167656e742d66696c652d786665725d0a6e616d653d66696e202e747874200a73697a653d390a00"),
        ("two-leading", "  deux.txt", 9,
         "5b76646167656e742d66696c652d786665725d0a6e616d653d5c735c73646575782e7478740a73697a653d390a00"),
        ("leading-tab", "\ttab-en-tete.txt", 9,
         "5b76646167656e742d66696c652d786665725d0a6e616d653d5c747461622d656e2d746574652e7478740a73697a653d390a00"),
        ("backslash-ends-run", "\\ apres-antislash", 9,
         "5b76646167656e742d66696c652d786665725d0a6e616d653d5c5c2061707265732d616e7469736c6173680a73697a653d390a00"),
        ("newline-keeps-run", "\n suite.txt", 9,
         "5b76646167656e742d66696c652d786665725d0a6e616d653d5c6e5c7373756974652e7478740a73697a653d390a00"),
    ]

    private func bytes(fromHex hex: String) -> [UInt8] {
        var out: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            out.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        return out
    }

    func testTheStartPayloadIsGLibsByteForByte() {
        for (label, name, size, hex) in Self.glibFixtures {
            XCTAssertEqual(
                SpiceFileTransfer.startBody(id: 7, name: name, size: size),
                SpiceWire.u32(7) + bytes(fromHex: hex),
                "gabarit « \(label) » : l'agent parse avec GLib, l'octet près compte"
            )
        }
    }

    /// The reference queues `data_len + 1` bytes: the NUL is on the wire, not
    /// an artefact of C strings that stops at the sender.
    func testTheTerminatingNulTravels() {
        XCTAssertEqual(SpiceFileTransfer.startBody(id: 1, name: "a", size: 1).last, 0)
    }

    func testADataBodyIsIdThenASixtyFourBitCountThenTheBytes() {
        let chunk: [UInt8] = [0xAA, 0xBB, 0xCC]
        XCTAssertEqual(
            SpiceFileTransfer.dataBody(id: 3, chunk: chunk[...]),
            SpiceWire.u32(3) + SpiceWire.u64(3) + chunk
        )
        XCTAssertEqual(
            SpiceFileTransfer.dataBody(id: 3, chunk: [][...]),
            SpiceWire.u32(3) + SpiceWire.u64(0),
            "le message vide d'un fichier vide : un compte de zéro, aucun octet"
        )
    }

    func testAStatusBodyIsIdThenResult() {
        XCTAssertEqual(
            SpiceFileTransfer.statusBody(id: 9, result: .cancelled),
            SpiceWire.u32(9) + SpiceWire.u32(1)
        )
    }

    func testAStatusMessageDecodes() throws {
        let message = try SpiceFileTransfer.statusMessage(
            SpiceWire.u32(4) + SpiceWire.u32(0)
        )
        XCTAssertEqual(message.id, 4)
        XCTAssertEqual(message.status, .canSendData)
        XCTAssertNil(message.diskFreeSpace)
    }

    /// The free-space detail is read when it fits, like the reference's size
    /// gate — never assumed from the capability, and never from a result that
    /// does not carry one.
    func testTheFreeSpaceDetailIsReadOnlyWhenItFits() throws {
        let withDetail = try SpiceFileTransfer.statusMessage(
            SpiceWire.u32(4) + SpiceWire.u32(4) + SpiceWire.u64(123_456)
        )
        XCTAssertEqual(withDetail.status, .notEnoughSpace)
        XCTAssertEqual(withDetail.diskFreeSpace, 123_456)

        let tooShort = try SpiceFileTransfer.statusMessage(
            SpiceWire.u32(4) + SpiceWire.u32(4) + SpiceWire.u32(1)
        )
        XCTAssertNil(tooShort.diskFreeSpace, "quatre octets ne font pas un u64")

        let otherResult = try SpiceFileTransfer.statusMessage(
            SpiceWire.u32(4) + SpiceWire.u32(2) + SpiceWire.u64(99)
        )
        XCTAssertNil(
            otherResult.diskFreeSpace,
            "le détail d'une erreur n'est pas un espace libre"
        )
    }

    /// Statuses are an enumeration built to grow: an unknown value fails one
    /// transfer with its number rather than killing the pump.
    func testAnUnknownResultIsKeptAsItsNumber() throws {
        let message = try SpiceFileTransfer.statusMessage(
            SpiceWire.u32(4) + SpiceWire.u32(9)
        )
        XCTAssertNil(message.status)
        XCTAssertEqual(message.result, 9)
    }

    func testATruncatedStatusIsRefused() {
        XCTAssertThrowsError(
            try SpiceFileTransfer.statusMessage(SpiceWire.u32(4) + [0, 0])
        )
    }
}
