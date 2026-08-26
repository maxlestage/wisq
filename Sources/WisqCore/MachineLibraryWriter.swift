import Foundation

/// The order in which a machine and its secrets are written, and the removal
/// of the ones that end up pointing at nothing.
///
/// This lives in `WisqCore` and not in the view model that calls it for one
/// reason: what it carries is an **order**, and an order can only be shown to
/// matter by making one of its steps fail. `WisqUI` is not compiled on Linux,
/// so a rule written there can be broken on purpose nowhere that runs in a few
/// seconds. Here it can, against a real `MachineStore` writing real files.
///
/// The rule itself is one sentence: **nothing reaches the credential store
/// before the machine that will point at it is in the list.** A secret written
/// ahead of a save that then fails is worse than a lost secret — for a
/// password it is a machine still listed that can no longer log in, and for an
/// agent token it is a key no machine references, which puts it beyond
/// `CredentialReaper` too, since the reaper only ever knows the keys a machine
/// carried.
public struct MachineLibraryWriter {
    private let store: MachineStore
    private let credentials: CredentialStore

    public init(store: MachineStore, credentials: CredentialStore) {
        self.store = store
        self.credentials = credentials
    }

    /// Saves `machine`, then its secrets, then reaps what `previous` left behind.
    ///
    /// `password` nil means "not edited" and leaves any stored one alone; empty
    /// means "cleared" and removes it. `agentToken` is written only when the
    /// machine actually carries an agent binding to reference it. `previous` is
    /// the machine as it was in the list, or nil when this is a new one.
    ///
    /// Returns the machine as saved — its `credentialRef` may have been filled
    /// in or cleared — and the list the store now holds.
    @discardableResult
    public func save(
        _ machine: Machine,
        password: String?,
        agentToken: String? = nil,
        previous: Machine?
    ) throws -> (machine: Machine, machines: [Machine]) {
        var machine = machine

        // The reference is decided here because it is part of what gets saved;
        // the secret behind it is written further down, once the save is real.
        var pendingPassword: (secret: String?, ref: String)?
        if let password {
            let ref = machine.credentialRef ?? machine.defaultCredentialRef
            pendingPassword = (password.isEmpty ? nil : password, ref)
            machine.credentialRef = password.isEmpty ? nil : ref
        }

        let machines = try store.upsert(machine)

        if let pendingPassword {
            try credentials.setSecret(pendingPassword.secret, for: pendingPassword.ref)
        }
        // An agent token with no binding to reference it would be exactly the
        // orphan this type exists to avoid, so the binding decides.
        if let agentToken, !agentToken.isEmpty, let ref = machine.agent?.credentialRef {
            try credentials.setSecret(agentToken, for: ref)
        }
        // Unbinding a machine from its agent, or moving it to another one,
        // leaves the old token behind exactly as a deletion would.
        if let previous {
            try CredentialReaper.reap(after: previous, remaining: machines, from: credentials)
        }
        return (machine, machines)
    }

    /// Removes the machine, then the secrets nothing points at any more.
    public func delete(_ machine: Machine) throws -> [Machine] {
        let machines = try store.delete(id: machine.id)
        try CredentialReaper.reap(after: machine, remaining: machines, from: credentials)
        return machines
    }
}
