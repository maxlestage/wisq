import Foundation
import XCTest

@testable import WisqCore

/// One entry this build cannot read used to cost the whole library.
///
/// `loadOnQueue` decoded `[Machine].self` in a single call, so a file holding
/// twelve machines and one entry from a newer wisq decoded to **nothing**:
/// `MachineLibraryModel.reload` set the list to empty and showed an error, and
/// an app that cannot reach its own container gave the user no way back.
///
/// The fix has a second half that matters as much. Dropping the entry from the
/// *list* is a loss the banner reports; dropping it from the *file* would be a
/// loss nobody can undo, and the first `upsert` after an older build read a
/// newer file would do exactly that. So what cannot be read is carried through
/// the save untouched.
final class PartiallyUnreadableLibraryTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wisq-partial-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func store(_ json: String) throws -> MachineStore {
        let url = directory.appendingPathComponent("machines.json")
        try Data(json.utf8).write(to: url)
        return MachineStore(fileURL: url)
    }

    private func entry(id: String, name: String, extra: String = "") -> String {
        """
        {"id":"\(id)","name":"\(name)","host":"\(name).local","port":5900,
         "proto":"vnc","security":"none","guestOS":"linux","tags":[],
         "createdAt":"2026-01-01T00:00:00Z","display":{},"input":{}\(extra)}
        """
    }

    private let alien = """
        {"id":"99999999-9999-9999-9999-999999999999","name":"Du futur",
         "host":"futur.local","port":5900,"proto":"holodeck","security":"none",
         "guestOS":"linux","tags":[],"createdAt":"2026-01-01T00:00:00Z",
         "display":{},"input":{}}
        """

    // MARK: - The library survives

    func testAnUnreadableEntryCostsOnlyItself() throws {
        let store = try store("[\(entry(id: "11111111-1111-1111-1111-111111111111", name: "nas")),"
            + "\(alien),\(entry(id: "22222222-2222-2222-2222-222222222222", name: "bureau"))]")
        let outcome = try store.loadReportingUnreadable()
        XCTAssertEqual(outcome.machines.map(\.name), ["nas", "bureau"])
        XCTAssertEqual(outcome.unreadable, 1)
    }

    /// The count is what the banner says. Without it the list would quietly
    /// show two machines where the file holds three, which is the silent loss
    /// this whole slice exists to avoid.
    func testTheCountIsReported() throws {
        let store = try store("[\(alien),\(alien)]")
        let outcome = try store.loadReportingUnreadable()
        XCTAssertTrue(outcome.machines.isEmpty)
        XCTAssertEqual(outcome.unreadable, 2)
    }

    /// The second load has to say the same thing as the first.
    ///
    /// Found by sabotage: making the cached path report zero left every other
    /// test in this file green, because each of them loads exactly once. But
    /// `MachineLibraryModel.reload()` is called again on every return to the
    /// list, so the banner would have appeared once and then quietly vanished
    /// while the entries were still unreadable — the same disappearing loss
    /// this slice exists to stop.
    func testASecondLoadStillReportsTheSameCount() throws {
        let store = try store("[\(entry(id: "11111111-1111-1111-1111-111111111111", name: "nas")),\(alien)]")
        XCTAssertEqual(try store.loadReportingUnreadable().unreadable, 1)
        XCTAssertEqual(try store.loadReportingUnreadable().unreadable, 1, "le cache a effacé le compte")
        XCTAssertEqual(try store.loadReportingUnreadable().machines.count, 1)
    }

    /// And after a write, which repopulates the cache by another route.
    func testTheCountSurvivesASave() throws {
        let store = try store("[\(entry(id: "11111111-1111-1111-1111-111111111111", name: "nas")),\(alien)]")
        _ = try store.upsert(Machine(name: "ajoutée", host: "ajoutee.local"))
        XCTAssertEqual(try store.loadReportingUnreadable().unreadable, 1)
    }

    // MARK: - And the file is not damaged

    /// The half that would otherwise have made this change worse than the bug.
    func testSavingDoesNotDeleteWhatThisBuildCannotRead() throws {
        let url = directory.appendingPathComponent("machines.json")
        let store = try store("[\(entry(id: "11111111-1111-1111-1111-111111111111", name: "nas")),\(alien)]")

        _ = try store.upsert(Machine(name: "ajoutée", host: "ajoutee.local"))

        // Read the file back with no knowledge of Machine at all: the entry we
        // could not decode has to still be in there, with its own fields.
        let raw = try JSONDecoder().decode([JSONValue].self, from: Data(contentsOf: url))
        let protocols = raw.compactMap { value -> String? in
            guard case .object(let fields) = value, case .string(let name)? = fields["proto"] else {
                return nil
            }
            return name
        }
        XCTAssertEqual(protocols.sorted(), ["holodeck", "vnc", "vnc"])
    }

    /// And it survives a delete too, which is the other composite operation
    /// that reads the list and writes it back.
    func testDeletingAMachineDoesNotDeleteTheUnreadableOne() throws {
        let url = directory.appendingPathComponent("machines.json")
        let id = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let store = try store("[\(entry(id: id.uuidString, name: "nas")),\(alien)]")

        _ = try store.delete(id: id)

        let raw = try JSONDecoder().decode([JSONValue].self, from: Data(contentsOf: url))
        XCTAssertEqual(raw.count, 1, "l'entrée illisible a été effacée avec la machine supprimée")
    }

    /// And it survives the third one — the only one that used to write without
    /// reading first.
    ///
    /// `upsert` and `delete` both load before they save, so `preserved` is
    /// filled by the time the file is rewritten. `save` is public and does
    /// neither: on a store that had not loaded, it appended an empty list of
    /// preserved entries and deleted the newer ones from the file. Measured
    /// before it was fixed — one unreadable entry in, zero out.
    ///
    /// Nothing in the app called it that way. That is a coincidence of the
    /// callers, not a defence, and it is the fourth time this repository has
    /// found a guard armed only by what its callers happen to do.
    func testSavingWithoutHavingLoadedDoesNotDeleteWhatItNeverRead() throws {
        let url = directory.appendingPathComponent("machines.json")
        _ = try store("[\(entry(id: "11111111-1111-1111-1111-111111111111", name: "nas")),\(alien)]")

        // A second store over the same file, which never reads it.
        let blind = MachineStore(fileURL: url)
        try blind.save([Machine(name: "ajoutée", host: "ajoutee.local")])

        let raw = try JSONDecoder().decode([JSONValue].self, from: Data(contentsOf: url))
        let protocols = raw.compactMap { value -> String? in
            guard case .object(let fields) = value, case .string(let name)? = fields["proto"] else {
                return nil
            }
            return name
        }
        XCTAssertEqual(
            protocols.sorted(), ["holodeck", "vnc"],
            "un save qui n'a rien lu a effacé l'entrée illisible"
        )
    }

    /// The cost of the fix, stated rather than discovered: a `save` over a file
    /// that will not parse now refuses, where it used to replace it. That is
    /// what `upsert` and `delete` have always done, and a library that will not
    /// parse may still be a library.
    func testSavingOverAFileThatIsNotALibraryRefusesRatherThanReplacingIt() throws {
        let url = directory.appendingPathComponent("machines.json")
        try Data("pas une bibliothèque".utf8).write(to: url)

        let store = MachineStore(fileURL: url)
        XCTAssertThrowsError(try store.save([Machine(name: "ajoutée", host: "ajoutee.local")]))
        XCTAssertEqual(
            try String(contentsOf: url, encoding: .utf8), "pas une bibliothèque",
            "le fichier refusé doit être laissé tel quel"
        )
    }

    /// The whole point of preserving it: the build that understands the entry
    /// still finds it intact afterwards, field for field.
    func testThePreservedEntryComesBackUnchanged() throws {
        let url = directory.appendingPathComponent("machines.json")
        let before = try JSONDecoder().decode(JSONValue.self, from: Data(alien.utf8))
        let store = try store("[\(alien)]")

        _ = try store.upsert(Machine(name: "ajoutée", host: "ajoutee.local"))

        let after = try JSONDecoder().decode([JSONValue].self, from: Data(contentsOf: url))
        XCTAssertTrue(after.contains(before), "l'entrée conservée a été altérée en passant par la sauvegarde")
    }

    // MARK: - Letting them go, on the user's word

    /// The one way an unreadable entry leaves the file: an explicit discard.
    /// It takes the unreadable entries and nothing else — the readable
    /// machines come back field for field, and the next load has nothing
    /// left to report.
    func testDiscardingRemovesOnlyWhatCannotBeRead() throws {
        let url = directory.appendingPathComponent("machines.json")
        let store = try store("[\(entry(id: "11111111-1111-1111-1111-111111111111", name: "nas")),"
            + "\(alien),\(entry(id: "22222222-2222-2222-2222-222222222222", name: "bureau"))]")

        XCTAssertEqual(try store.discardUnreadable(), 1, "une entrée écartée, et c'est dit")

        let raw = try JSONDecoder().decode([JSONValue].self, from: Data(contentsOf: url))
        XCTAssertEqual(raw.count, 2, "l'entrée illisible est partie, les deux autres non")
        let reloaded = try MachineStore(fileURL: url).loadReportingUnreadable()
        XCTAssertEqual(reloaded.unreadable, 0)
        XCTAssertEqual(reloaded.machines.map(\.name), ["nas", "bureau"])
        XCTAssertEqual(reloaded.machines.map(\.host), ["nas.local", "bureau.local"])
        XCTAssertEqual(try store.loadReportingUnreadable().unreadable, 0, "le cache doit suivre")
    }

    /// Nothing to discard means nothing written: a library with nothing
    /// wrong in it keeps its bytes, not a re-encoded copy of them.
    func testDiscardingOnACleanLibraryTouchesNothing() throws {
        let url = directory.appendingPathComponent("machines.json")
        let store = try store("[\(entry(id: "11111111-1111-1111-1111-111111111111", name: "nas"))]")
        let before = try Data(contentsOf: url)

        XCTAssertEqual(try store.discardUnreadable(), 0)

        XCTAssertEqual(try Data(contentsOf: url), before, "rien à écarter, rien à écrire")
    }

    /// Like every write here, it reads before it writes: a store that has
    /// never loaded discards what *this* load cannot read and keeps what it
    /// can — it does not write an empty list over the machines.
    func testDiscardingFromAStoreThatNeverLoadedKeepsTheReadableMachines() throws {
        let url = directory.appendingPathComponent("machines.json")
        _ = try store("[\(entry(id: "11111111-1111-1111-1111-111111111111", name: "nas")),\(alien)]")

        let blind = MachineStore(fileURL: url)
        XCTAssertEqual(try blind.discardUnreadable(), 1)

        let reloaded = try MachineStore(fileURL: url).loadReportingUnreadable()
        XCTAssertEqual(reloaded.machines.map(\.name), ["nas"], "écarter l'illisible a emporté le lisible")
        XCTAssertEqual(reloaded.unreadable, 0)
    }

    /// The banner can say *which* machine it cannot show, when the entry
    /// still has a name: a person recognises « nas », not "one entry". An
    /// entry with no name, or a name that is not text, is counted but not
    /// named — a damaged entry may have lost its name with the rest.
    func testTheNamesOfUnreadableEntriesAreReportedWhenTheyHaveOne() throws {
        let nameless = """
            {"id":"88888888-8888-8888-8888-888888888888","host":"x.local","proto":"holodeck"}
            """
        let numbered = """
            {"id":"77777777-7777-7777-7777-777777777777","name":42,"proto":"holodeck"}
            """
        let store = try store("[\(alien),\(nameless),\(numbered)]")

        let outcome = try store.loadReportingUnreadable()
        XCTAssertEqual(outcome.unreadable, 3)
        XCTAssertEqual(outcome.unreadableNames, ["Du futur"])
        XCTAssertEqual(try store.loadReportingUnreadable().unreadableNames, ["Du futur"], "le cache doit le dire aussi")
    }

    // MARK: - What must not change

    /// A library with nothing wrong in it round-trips exactly as before. A fix
    /// that quietly reshaped every saved machine would be a bigger change than
    /// the one intended.
    func testAnOrdinaryLibraryIsUnaffected() throws {
        let url = directory.appendingPathComponent("machines.json")
        let store = MachineStore(fileURL: url)
        let machine = Machine(name: "nas", host: "nas.local", port: 5901, proto: .vnc)
        _ = try store.upsert(machine)

        let reloaded = try MachineStore(fileURL: url).loadReportingUnreadable()
        XCTAssertEqual(reloaded.unreadable, 0)
        XCTAssertEqual(reloaded.machines.count, 1)
        XCTAssertEqual(reloaded.machines.first?.port, 5901, "le port a changé de forme en passant par le JSON brut")
        XCTAssertEqual(reloaded.machines.first?.name, "nas")
        XCTAssertEqual(reloaded.machines.first?.id, machine.id)
    }

    /// A file that is not an array at all is still a refusal, not an empty
    /// library: tolerating *that* would turn a corrupted file into "you have no
    /// machines", and the next save would make it true.
    func testAFileThatIsNotALibraryStillThrows() throws {
        let store = try store("{\"machines\": []}")
        XCTAssertThrowsError(try store.loadReportingUnreadable())
    }

    func testTruncatedJSONStillThrows() throws {
        let store = try store("[{\"id\":")
        XCTAssertThrowsError(try store.loadReportingUnreadable())
    }
}
