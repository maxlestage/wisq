import Foundation
import Observation
import WisqCore

/// The machine list, its persistence, and the secrets that go with it.
@Observable
public final class MachineLibraryModel {
    public private(set) var machines: [Machine] = []
    public var loadError: String?

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
            loadError = Self.unreadableMessage(outcome.unreadable)
        } catch {
            machines = []
            loadError = error.localizedDescription
        }
    }

    /// Nil when there is nothing to say — so a clean load still clears the
    /// banner, which is what it used to do unconditionally.
    static func unreadableMessage(_ count: Int) -> String? {
        switch count {
        case 0: return nil
        case 1: return "Une machine n'a pas pu être lue et n'apparaît pas ici. Elle reste enregistrée."
        default:
            return "\(count) machines n'ont pas pu être lues et n'apparaissent pas ici. "
                + "Elles restent enregistrées."
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
