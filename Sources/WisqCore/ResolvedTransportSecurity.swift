import Foundation

/// What the transport must actually do, once it is known what there is to pin.
///
/// `TransportSecurity` is what the user picked and what the file said.
/// This is what the socket does, and the difference between the two is a
/// fingerprint that may not exist.
///
/// The dangerous state is not representable here on purpose: `.pinned` carries
/// its fingerprint, so no code path can ask for a pinned connection while
/// holding nothing to pin it to. That state used to exist, and what it did was
/// install a verification block that replaced the system's own checks and then
/// accepted every certificate presented to it — which made the mode the picker
/// calls "TLS épinglé" strictly weaker than the "TLS" listed right above it.
public enum ResolvedTransportSecurity: Equatable, Sendable {
    /// Plain TCP.
    case plain
    /// TLS, validated the way the operating system validates anything else.
    case systemValidated
    /// TLS accepted only if the leaf certificate hashes to exactly this.
    case pinned(Data)

    /// Resolves what was asked for against what is available.
    ///
    /// `.tlsPinned` with no fingerprint resolves to **full system validation**,
    /// never to a connection that trusts whatever answers. Refusing outright
    /// was the other candidate and is the safer-sounding one, but it would
    /// break machines the user believed were already working while giving them
    /// nothing they do not get here: today no saved machine can carry a
    /// fingerprint at all — neither `Machine` nor `SessionConfiguration` has a
    /// field for one — so this branch is the whole of the machine path, and
    /// system validation is a real check where the previous behaviour was none.
    ///
    /// What it deliberately is *not* is trust-on-first-use. Real TOFU needs
    /// somewhere to record the fingerprint and a way to show it to the person
    /// accepting it; see `docs/ROADMAP.md`.
    public static func resolve(_ security: TransportSecurity, fingerprint: Data?) -> Self {
        switch security {
        case .none:
            return .plain
        case .tls:
            return .systemValidated
        case .tlsPinned:
            guard let fingerprint, !fingerprint.isEmpty else { return .systemValidated }
            return .pinned(fingerprint)
        }
    }

    /// Whether the certificate chain is checked at all. False only for `.plain`.
    public var validatesCertificate: Bool { self != .plain }
}
