import Foundation

extension Machine {
    /// Every key into the `CredentialStore` this machine can reach: its own
    /// password, and the token of the agent it is bound to.
    ///
    /// Both are optional and they are not the same kind of key — see
    /// `CredentialReaper` for why that difference decides who may delete them.
    public var credentialRefs: Set<String> {
        var refs: Set<String> = []
        if let credentialRef { refs.insert(credentialRef) }
        if let agentRef = agent?.credentialRef { refs.insert(agentRef) }
        return refs
    }
}

/// Removes the secrets a machine leaves behind, without removing the ones its
/// neighbours still need.
///
/// The store holds two kinds of key and they must not be treated alike:
///
/// - a **machine password** is keyed by the machine's own id
///   (`Machine.defaultCredentialRef`), so exactly one machine ever points at
///   it and it dies with that machine;
/// - an **agent token** is keyed by host and port, and is deliberately shared
///   by every VM on that agent — the editor writes one per agent, not one per
///   machine.
///
/// So deleting a machine can neither keep all of its keys (the token of an
/// agent whose last VM just went would stay in the keychain with nothing left
/// able to use it) nor delete all of them (deleting one of five VMs on a NAS
/// would log the other four out). What is left over is a subtraction: the keys
/// the departing machine used, minus the keys the surviving list still points
/// at.
public enum CredentialReaper {
    /// The keys `removed` used and that nothing in `remaining` points at any more.
    ///
    /// `remaining` is the list **after** the change — the caller passes what
    /// the store returned, not what it had before.
    public static func orphanedRefs(after removed: Machine, remaining: [Machine]) -> Set<String> {
        let stillUsed = remaining.reduce(into: Set<String>()) { $0.formUnion($1.credentialRefs) }
        return removed.credentialRefs.subtracting(stillUsed)
    }

    /// Deletes those keys from `store`, and returns them.
    ///
    /// Every key is attempted even when one fails, and the first failure is
    /// rethrown afterwards: a keychain that refuses one deletion must not make
    /// the caller skip the others. Call this **after** the machine list has
    /// been written, never before — a secret dropped ahead of a save that then
    /// fails leaves a machine that is still listed and can no longer log in.
    @discardableResult
    public static func reap(
        after removed: Machine,
        remaining: [Machine],
        from store: CredentialStore
    ) throws -> Set<String> {
        let orphans = orphanedRefs(after: removed, remaining: remaining)
        var firstFailure: Error?
        for ref in orphans.sorted() {
            do {
                try store.setSecret(nil, for: ref)
            } catch {
                if firstFailure == nil { firstFailure = error }
            }
        }
        if let firstFailure { throw firstFailure }
        return orphans
    }
}
