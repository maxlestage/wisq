import Foundation
import WisqCore
import WisqUI
import XCTest

/// The half of the partial-library rule that only exists on the phone.
///
/// `MachineStore`'s own behaviour is broken on purpose in `WisqCoreTests`,
/// where Linux can do it for free. What cannot be checked there is the thing
/// the user actually meets: the list shows the machines it could read, and the
/// banner that already existed says how many it could not.
///
/// Without the banner the fix would be worse than the bug it closes — a library
/// that silently shows eleven machines where the file holds twelve is a loss
/// nobody notices, and the old behaviour at least failed loudly.
final class PartialLibraryBannerTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wisq-banner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func model(_ json: String) throws -> MachineLibraryModel {
        let url = directory.appendingPathComponent("machines.json")
        try Data(json.utf8).write(to: url)
        return MachineLibraryModel(
            store: MachineStore(fileURL: url), credentials: EphemeralCredentialStore())
    }

    private func entry(id: String, name: String) -> String {
        """
        {"id":"\(id)","name":"\(name)","host":"\(name).local","port":5900,
         "proto":"vnc","security":"none","guestOS":"linux","tags":[],
         "createdAt":"2026-01-01T00:00:00Z","display":{},"input":{}}
        """
    }

    /// An entry from a newer build: a protocol this one has never heard of.
    private let alien = """
        {"id":"99999999-9999-9999-9999-999999999999","name":"Du futur",
         "host":"futur.local","port":5900,"proto":"holodeck","security":"none",
         "guestOS":"linux","tags":[],"createdAt":"2026-01-01T00:00:00Z",
         "display":{},"input":{}}
        """

    func testTheListShowsWhatItCouldReadAndSaysWhatItCouldNot() throws {
        let model = try model(
            "[\(entry(id: "11111111-1111-1111-1111-111111111111", name: "nas")),\(alien)]")
        XCTAssertEqual(model.machines.map(\.name), ["nas"])
        let banner = try XCTUnwrap(model.loadError, "rien n'a été dit de la machine perdue")
        XCTAssertTrue(banner.contains("n'a pas pu être lue"), banner)
    }

    /// Plural, because "1 machines" in a banner is how a user learns not to
    /// trust the rest of the sentence.
    func testTheBannerCountsCorrectly() throws {
        let model = try model("[\(alien),\(alien),\(alien)]")
        XCTAssertTrue(model.machines.isEmpty)
        let banner = try XCTUnwrap(model.loadError)
        XCTAssertTrue(banner.contains("3 machines"), banner)
    }

    /// The other edge: a library with nothing wrong in it shows no banner at
    /// all. A message that is always there is a message nobody reads.
    func testACleanLibraryShowsNoBanner() throws {
        let model = try model("[\(entry(id: "11111111-1111-1111-1111-111111111111", name: "nas"))]")
        XCTAssertEqual(model.machines.map(\.name), ["nas"])
        XCTAssertNil(model.loadError)
    }

    /// The banner names the machine when the entry still has a name, so the
    /// user decides about « Du futur » rather than about "one entry".
    func testTheBannerNamesTheMachineItCannotShow() throws {
        let model = try model(
            "[\(entry(id: "11111111-1111-1111-1111-111111111111", name: "nas")),\(alien)]")
        let banner = try XCTUnwrap(model.loadError)
        XCTAssertTrue(banner.contains("« Du futur »"), banner)
        XCTAssertEqual(model.unreadable, 1)
    }

    /// Discarding is the user's decision, and once taken the entry is gone
    /// from the file and the banner with it. The explanation offered before
    /// it says the one thing that matters: updating might bring the entry
    /// back, discarding never will.
    func testDiscardingOnTheUsersWordRemovesTheEntryAndTheBanner() throws {
        let url = directory.appendingPathComponent("machines.json")
        let model = try model(
            "[\(entry(id: "11111111-1111-1111-1111-111111111111", name: "nas")),\(alien)]")
        XCTAssertEqual(model.unreadable, 1)
        let explanation = MachineLibraryModel.discardExplanation(count: model.unreadable)
        XCTAssertTrue(explanation.contains("version plus récente"), explanation)
        XCTAssertTrue(explanation.contains("ne revient pas"), explanation)

        model.discardUnreadable()

        XCTAssertNil(model.loadError)
        XCTAssertEqual(model.unreadable, 0)
        XCTAssertEqual(model.machines.map(\.name), ["nas"])
        let raw = try JSONDecoder().decode([JSONValue].self, from: Data(contentsOf: url))
        XCTAssertEqual(raw.count, 1, "l'entrée écartée doit avoir quitté le fichier")
    }

    /// And the banner does not linger once the reason is gone — `reload()` runs
    /// again every time the list comes back on screen.
    func testTheBannerGoesAwayWhenTheReasonDoes() throws {
        let url = directory.appendingPathComponent("machines.json")
        let model = try model(
            "[\(entry(id: "11111111-1111-1111-1111-111111111111", name: "nas")),\(alien)]")
        XCTAssertNotNil(model.loadError)

        try Data("[\(entry(id: "11111111-1111-1111-1111-111111111111", name: "nas"))]".utf8)
            .write(to: url)

        let fresh = MachineLibraryModel(
            store: MachineStore(fileURL: url), credentials: EphemeralCredentialStore())
        XCTAssertNil(fresh.loadError)
        XCTAssertEqual(fresh.machines.map(\.name), ["nas"])
    }
}
