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
