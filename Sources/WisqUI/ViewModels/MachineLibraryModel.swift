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
            if let password {
                let ref = machine.credentialRef ?? machine.defaultCredentialRef
                try credentials.setSecret(password.isEmpty ? nil : password, for: ref)
                machine.credentialRef = password.isEmpty ? nil : ref
            }
            machines = try store.upsert(machine)
            reload()
        } catch {
            loadError = error.localizedDescription
        }
    }

    public func delete(_ machine: Machine) {
        do {
            if let ref = machine.credentialRef {
                try credentials.setSecret(nil, for: ref)
            }
            machines = try store.delete(id: machine.id)
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
