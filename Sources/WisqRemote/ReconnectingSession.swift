import Foundation
import WisqCore

/// When and how hard to retry a dropped session.
public struct ReconnectPolicy: Sendable {
    public var maxAttempts: Int
    public var initialDelay: Duration
    public var maxDelay: Duration
    public var multiplier: Double
    /// How long a connection has to last before it refills the retry budget.
    ///
    /// The budget used to be refilled by `.ready`, and that was unreachable as
    /// a limit: **every** server emits `.ready`, including one that finishes
    /// the handshake and drops a millisecond later. Such a server reset the
    /// counter on every cycle, so `maxAttempts` was never reached and the
    /// backoff never grew past `initialDelay` — a full handshake every second,
    /// for as long as the phone stayed awake, with no error ever shown.
    ///
    /// Reaching `.ready` cannot be the test, because the pathological case
    /// reaches it too. Lasting can: a connection that stayed up long enough to
    /// be used has proved the host works, which is what the budget is asking.
    public var minimumUptimeToResetBudget: Duration

    public init(
        maxAttempts: Int,
        initialDelay: Duration,
        maxDelay: Duration,
        multiplier: Double = 2,
        minimumUptimeToResetBudget: Duration = .seconds(10)
    ) {
        self.maxAttempts = maxAttempts
        self.initialDelay = initialDelay
        self.maxDelay = maxDelay
        self.multiplier = multiplier
        self.minimumUptimeToResetBudget = minimumUptimeToResetBudget
    }

    /// Five tries over roughly a minute: enough to ride out a cell handoff or a
    /// Wi-Fi blip, short enough that a genuinely dead host fails while the user
    /// still remembers tapping Connect.
    ///
    /// The ten seconds is spelled out here rather than left to the default,
    /// because it is what makes the sentence above true: without a floor, the
    /// five tries were unreachable against any host that answers the handshake
    /// and then falls over, and "a genuinely dead host fails" was not what
    /// happened. Ten seconds is comfortably longer than a handshake and
    /// comfortably shorter than a session someone actually used.
    public static let standard = ReconnectPolicy(
        maxAttempts: 5, initialDelay: .seconds(1), maxDelay: .seconds(30),
        minimumUptimeToResetBudget: .seconds(10)
    )

    public static let none = ReconnectPolicy(
        maxAttempts: 0, initialDelay: .zero, maxDelay: .zero
    )

    public func delay(forAttempt attempt: Int) -> Duration {
        let base = Self.seconds(of: initialDelay) * pow(multiplier, Double(max(0, attempt - 1)))
        return .seconds(min(base, Self.seconds(of: maxDelay)))
    }

    private static func seconds(of duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}

/// Wraps a session factory and reconnects through network failures.
///
/// This is the most visible defect of every existing iOS VNC client: a phone
/// changes networks constantly, each handoff kills the socket, and the user is
/// thrown back to the machine list. Here the session object survives; the wire
/// connection underneath it is rebuilt.
///
/// Two properties matter for correctness:
///
/// - The framebuffer is owned *here* and shared into every underlying session, so
///   the renderer's reference stays valid across reconnects.
/// - Everything else — the zlib dictionaries above all — dies with the underlying
///   session and is rebuilt fresh. A zlib dictionary inherited from a previous
///   connection decodes to garbage, so reusing the session actor was never an
///   option.
///
/// Auth and handshake failures are terminal: retrying a wrong password hammers
/// the server, and a protocol mismatch will not fix itself.
public actor ReconnectingSession: RemoteSession {
    public typealias Factory = @Sendable (Framebuffer) throws -> any RemoteSession

    public nonisolated let events: AsyncStream<SessionEvent>
    public nonisolated let framebuffer = Framebuffer(width: 0, height: 0)

    private let continuation: AsyncStream<SessionEvent>.Continuation
    private let makeSession: Factory
    private let policy: ReconnectPolicy

    private var current: (any RemoteSession)?
    private var pump: Task<Void, Never>?
    private var stopped = false
    private var hasFinished = false

    public init(policy: ReconnectPolicy = .standard, makeSession: @escaping Factory) {
        self.policy = policy
        self.makeSession = makeSession
        var escapee: AsyncStream<SessionEvent>.Continuation!
        self.events = AsyncStream(bufferingPolicy: .bufferingNewest(64)) { escapee = $0 }
        self.continuation = escapee
    }

    // MARK: - RemoteSession

    public func start() async {
        guard pump == nil else { return }
        pump = Task { await run() }
    }

    public func stop() async {
        stopped = true
        pump?.cancel()
        if let current {
            await current.stop()
        }
        current = nil
        finish(with: nil)
    }

    public func send(_ event: InputEvent) async {
        await current?.send(event)
    }

    public func setPreferredSize(width: Int, height: Int) async {
        await current?.setPreferredSize(width: width, height: height)
    }

    // MARK: - The reconnect loop

    private func run() async {
        var attempt = 0
        while !stopped {
            let session: any RemoteSession
            do {
                session = try makeSession(framebuffer)
            } catch let error as WisqError {
                finish(with: error)
                return
            } catch {
                finish(with: .connectionFailed(error.localizedDescription))
                return
            }

            current = session
            await session.start()

            var failure: WisqError?
            var reachedReady = false
            let startedAt = ContinuousClock.now
            for await event in session.events {
                switch event {
                case .ready:
                    reachedReady = true
                    continuation.yield(event)
                case .disconnected(let error):
                    // Held back: either it becomes a .reconnecting, or it is
                    // re-emitted as the terminal event below.
                    failure = error
                default:
                    continuation.yield(event)
                }
            }
            current = nil

            // Refilling the budget is decided here rather than on `.ready`,
            // and the reason is the order of events: how long a connection
            // lasted is only known once it is over. A connection that came up
            // and stayed up gets the next drop the full retry schedule again;
            // one that came up and fell over does not, or the limit below is
            // not a limit at all.
            if reachedReady, ContinuousClock.now - startedAt >= policy.minimumUptimeToResetBudget {
                attempt = 0
            }

            if stopped { finish(with: nil); return }
            guard let error = failure else {
                // The stream ended without an error: a deliberate stop.
                finish(with: nil)
                return
            }
            guard error.isRetryable, attempt < policy.maxAttempts else {
                finish(with: error)
                return
            }

            attempt += 1
            continuation.yield(.reconnecting(attempt: attempt))
            do {
                try await Task.sleep(for: policy.delay(forAttempt: attempt))
            } catch {
                finish(with: nil)
                return
            }
        }
        finish(with: nil)
    }

    private func finish(with error: WisqError?) {
        guard !hasFinished else { return }
        hasFinished = true
        continuation.yield(.disconnected(error))
        continuation.finish()
    }
}
