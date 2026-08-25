import Foundation

/// The TCP settings a remote desktop session wants, as numbers rather than as
/// assignments to a platform object.
///
/// Three of these already existed inside `NetworkByteStream`, written straight
/// onto an `NWProtocolTCP.Options`. That file is `#if canImport(Network)`, so
/// on a Linux runner it does not compile, is not run, and is not tested — the
/// numbers in it could be anything. Pulled out here they are a value, and a
/// value can be checked on any machine; what stays behind the platform guard is
/// four assignments with nothing to get wrong.
///
/// Everything here is about one shape of connection: a person looking at a
/// screen somewhere else, over a phone's network.
public struct TransportTuning: Equatable, Sendable {
    /// Send small writes immediately instead of waiting to fill a segment.
    ///
    /// Nagle's algorithm exists to stop a stream of one-byte writes from
    /// costing a packet each, and a keystroke is exactly that write. Coalescing
    /// it with the next one adds up to a round trip of latency to the thing the
    /// user is most sensitive to — the gap between pressing a key and seeing
    /// it. The bytes saved are not worth it.
    public var noDelay: Bool

    /// How long to wait for the peer before giving up on connecting.
    ///
    /// Seconds. Long enough for a slow cellular handshake, short enough that a
    /// host that has moved reports it rather than leaving a spinner turning.
    public var connectionTimeout: Int

    /// Whether to keep the connection alive while nothing is being sent.
    ///
    /// A remote desktop is silent whenever the screen is: the client asks for
    /// an incremental update and the server holds the request open until
    /// something changes. Minutes of nothing on the wire is the normal state,
    /// not a stalled one.
    ///
    /// That is a problem specific to phones. Carrier NAT and home routers drop
    /// idle mappings — commonly after a few minutes — and neither end is told.
    /// The session looks fine until the user touches something, and then the
    /// write fails or hangs. Keepalive turns a silence into something the stack
    /// notices, so the session reports a failure the app can reconnect from
    /// rather than waiting for the person to discover it.
    public var keepaliveEnabled: Bool

    /// Seconds of silence before the first keepalive probe.
    ///
    /// Under the shortest NAT timeouts worth defending against. The default of
    /// two hours on most systems is useless here: the mapping is long gone.
    public var keepaliveIdle: Int

    /// Seconds between probes once they start.
    public var keepaliveInterval: Int

    /// How many unanswered probes before the connection is declared dead.
    ///
    /// With the interval above, this is the delay between a link going away and
    /// the app being told. Too eager and a tunnel that hiccups tears down a
    /// working session; too patient and the user gets a frozen screen.
    public var keepaliveCount: Int

    public init(
        noDelay: Bool = true,
        connectionTimeout: Int = 15,
        keepaliveEnabled: Bool = true,
        keepaliveIdle: Int = 60,
        keepaliveInterval: Int = 15,
        keepaliveCount: Int = 4
    ) {
        self.noDelay = noDelay
        self.connectionTimeout = connectionTimeout
        self.keepaliveEnabled = keepaliveEnabled
        self.keepaliveIdle = keepaliveIdle
        self.keepaliveInterval = keepaliveInterval
        self.keepaliveCount = keepaliveCount
    }

    /// What a session on a phone asks for.
    public static let interactive = TransportTuning()

    /// How long after the peer goes away this notices, in seconds.
    ///
    /// The idle wait plus every probe that goes unanswered. Worth having as a
    /// number rather than as three numbers to multiply in your head, because it
    /// is the only one a person would recognise: it is how long a screen stays
    /// frozen before the app admits the connection is gone.
    public var secondsUntilADeadPeerIsNoticed: Int {
        keepaliveIdle + keepaliveInterval * keepaliveCount
    }
}
