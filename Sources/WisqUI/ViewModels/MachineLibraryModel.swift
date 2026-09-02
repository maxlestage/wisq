import Foundation
import Observation
import WisqCore

/// The machine list, its persistence, and the secrets that go with it.
@Observable
public final class MachineLibraryModel {
    public private(set) var machines: [Machine] = []
    public var loadError: String?
    /// How many entries of the file this build could not read. Non-zero is
    /// what offers the user the choice to discard them; see
    /// `discardUnreadable`.
    public private(set) var unreadable = 0

    private let store: MachineStore
    private let credentials: CredentialStore
    private let writer: MachineLibraryWriter

    public init(store: MachineStore, credentials: CredentialStore) {
        self.store = store
        self.credentials = credentials
        self.writer = MachineLibraryWriter(store: store, credentials: credentials)
        reload()
    }

    /// Convenience for the app entry point: on-disk store plus keychain.
    public static func makeDefault() -> MachineLibraryModel {
        #if canImport(Security)
        let credentials: CredentialStore = KeychainCredentialStore()
        #else
        let credentials: CredentialStore = EphemeralCredentialStore()
        #endif
        do {
            return MachineLibraryModel(store: try MachineStore.makeDefault(), credentials: credentials)
        } catch {
            // Falling back to a temporary store keeps the app usable; the banner
            // in the list tells the user their machines will not be kept.
            let fallback = MachineStore(
                fileURL: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("wisq-machines.json")
            )
            let model = MachineLibraryModel(store: fallback, credentials: credentials)
            model.loadError = error.localizedDescription
            return model
        }
    }

    /// Reloads the list, and says so when the file held entries this build
    /// could not read.
    ///
    /// The banner already existed for `loadError`; what it never had was
    /// anything to say about this case, because there was no such case — one
    /// unreadable entry used to make the whole load throw and the list go
    /// empty. Now the readable machines are shown and the count of the others
    /// is stated, which is the difference between a loss and a silent loss.
    /// The entries themselves are kept in the file; see `MachineStore`.
    public func reload() {
        do {
            let outcome = try store.loadReportingUnreadable()
            machines = outcome.machines.sorted { lhs, rhs in
                switch (lhs.lastConnectedAt, rhs.lastConnectedAt) {
                case let (l?, r?): return l > r
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil): return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
            }
            unreadable = outcome.unreadable
            loadError = Self.unreadableMessage(outcome.unreadable, names: outcome.unreadableNames)
        } catch {
            machines = []
            unreadable = 0
            loadError = error.localizedDescription
        }
    }

    /// Nil when there is nothing to say — so a clean load still clears the
    /// banner, which is what it used to do unconditionally. Names the
    /// machines when the entries still carry a name: "une machine" is a
    /// count, "« nas »" is something the user can recognise and decide about.
    static func unreadableMessage(_ count: Int, names: [String] = []) -> String? {
        let named = names.isEmpty ? "" : " (" + names.map { "« \($0) »" }.joined(separator: ", ") + ")"
        switch count {
        case 0: return nil
        case 1:
            return "Une machine\(named) n'a pas pu être lue et n'apparaît pas ici. Elle reste enregistrée."
        default:
            return "\(count) machines\(named) n'ont pas pu être lues et n'apparaissent pas ici. "
                + "Elles restent enregistrées."
        }
    }

    /// What the confirmation says before discarding — the truth, which is
    /// that the app cannot tell the two cases apart and will not choose.
    ///
    /// An entry this build cannot read is either from a newer wisq, in which
    /// case updating brings it back and discarding loses a machine somebody
    /// set up, or damaged, in which case nothing brings it back and it will
    /// be announced at every launch forever. Only the user knows which.
    public static func discardExplanation(count: Int) -> String {
        let these = count == 1 ? "Cette entrée vient" : "Ces entrées viennent"
        let them = count == 1 ? "la" : "les"
        return "\(these) peut-être d'une version plus récente de wisq : mettre à jour "
            + "\(them) ferait revenir. Si vous êtes sûr que non, vous pouvez "
            + "\(them) écarter. Ce qui est écarté est effacé du fichier et ne revient pas."
    }

    /// Discards the entries this build cannot read, on the user's word.
    /// The list is reloaded afterwards, so the banner goes with them.
    public func discardUnreadable() {
        do {
            _ = try store.discardUnreadable()
            reload()
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// Saves the machine and the secrets that go with it.
    ///
    /// `password` nil means "not edited"; empty means "cleared". `agentToken`
    /// is the token of the agent the machine is bound to, and it is passed
    /// here rather than written by the caller on its way in: the order — list
    /// first, secrets after — is the whole point, and it lives in
    /// `MachineLibraryWriter` where it can be broken on purpose.
    ///
    /// Returns whether it worked, so a caller that has a secret in hand can
    /// tell a save that happened from one that did not.
    @discardableResult
    public func save(_ machine: Machine, password: String?, agentToken: String? = nil) -> Bool {
        do {
            let previous = machines.first { $0.id == machine.id }
            machines = try writer.save(
                machine, password: password, agentToken: agentToken, previous: previous
            ).machines
            reload()
            return true
        } catch {
            loadError = error.localizedDescription
            return false
        }
    }

    /// Removes the machine, then the secrets nothing points at any more.
    @discardableResult
    public func delete(_ machine: Machine) -> Bool {
        do {
            machines = try writer.delete(machine)
            reload()
            return true
        } catch {
            loadError = error.localizedDescription
            return false
        }
    }

    public func password(for machine: Machine) -> String? {
        guard let ref = machine.credentialRef else { return nil }
        return try? credentials.secret(for: ref)
    }

    public func markConnected(_ machine: Machine) {
        var machine = machine
        machine.lastConnectedAt = Date()
        save(machine, password: nil)
    }

    public var credentialStore: CredentialStore { credentials }
}
