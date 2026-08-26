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

    public init(store: MachineStore, credentials: CredentialStore) {
        self.store = store
        self.credentials = credentials
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

    public func reload() {
        do {
            machines = try store.load().sorted { lhs, rhs in
                switch (lhs.lastConnectedAt, rhs.lastConnectedAt) {
                case let (l?, r?): return l > r
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil): return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
            }
            loadError = nil
        } catch {
            machines = []
            loadError = error.localizedDescription
        }
    }

    /// Saves the machine and, when `password` is non-nil, its secret.
    /// An empty password removes the stored secret rather than saving a blank one.
    public func save(_ machine: Machine, password: String?) {
        var machine = machine
        do {
            let previous = machines.first { $0.id == machine.id }
            if let password {
                let ref = machine.credentialRef ?? machine.defaultCredentialRef
                try credentials.setSecret(password.isEmpty ? nil : password, for: ref)
                machine.credentialRef = password.isEmpty ? nil : ref
            }
            machines = try store.upsert(machine)
            // Unbinding a machine from its agent, or moving it to another one,
            // leaves the old token behind exactly as a deletion would.
            if let previous {
                try CredentialReaper.reap(after: previous, remaining: machines, from: credentials)
            }
            reload()
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// Removes the machine, then the secrets nothing points at any more.
    ///
    /// In that order, and through `CredentialReaper` rather than by hand. The
    /// hand-written version dropped `machine.credentialRef` *before* the save
    /// and never touched `agent.credentialRef` at all — so a failed write left
    /// a listed machine with no password, and the token of an agent whose last
    /// VM had just gone stayed in the keychain with nothing able to use it and
    /// no screen offering to remove it.
    public func delete(_ machine: Machine) {
        do {
            machines = try store.delete(id: machine.id)
            try CredentialReaper.reap(after: machine, remaining: machines, from: credentials)
            reload()
        } catch {
            loadError = error.localizedDescription
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
