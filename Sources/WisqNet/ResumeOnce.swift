import Foundation

/// Lets exactly one caller resume a continuation, whoever gets there first.
///
/// `NWConnection.stateUpdateHandler` can fire more than once — `.waiting`
/// then `.failed`, or `.ready` racing a cancellation — and resuming a
/// continuation twice is a hard crash, not a warning. The obvious version of
/// this is a captured `var` flag, which Swift 6 rejects outright: the handler
/// runs on Network.framework's own queue, so the flag really is shared mutable
/// state.
///
/// This lives outside the `canImport(Network)` guard on purpose, so the part
/// with the actual concurrency argument is compiled and tested on every
/// platform rather than only where the socket code exists.
public final class ResumeOnce: @unchecked Sendable {
    private var claimed = false
    private let lock = NSLock()

    public init() {}

    /// Returns `true` exactly once across every thread that ever calls it.
    public func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}
