import Foundation

/// Which haptic, if any, a session event is worth.
///
/// The decision lives here rather than in the view, and that is deliberate:
/// `WisqUI` is not built on Linux at all, so anything decided there is decided
/// where no test on this side can reach it. What is left for the view is the
/// mapping onto `UINotificationFeedbackGenerator`, which has nothing to get
/// wrong.
///
/// The three cases are the platform's own vocabulary — it plays a distinct
/// pattern for each, and people recognise them without being taught.
public enum SessionHaptic: Equatable, Sendable {
    /// The screen arrived. The thing the user was waiting for.
    case success
    /// Still working, but something went wrong on the way.
    case warning
    /// It gave up.
    case error
}

extension SessionEvent {
    /// The haptic this event deserves, or `nil` for the overwhelming majority
    /// that deserve none.
    ///
    /// Four decisions, and three of them are about *not* buzzing:
    ///
    ///   * **`.ready` is the one that earns a tap.** A phone connecting to a
    ///     machine is a wait with nothing to watch, often with the screen in a
    ///     pocket or a hand that is doing something else. A single confirmation
    ///     when the desktop lands is the whole point of having haptics at all.
    ///   * **only the *first* reconnection attempt.** A dropped Wi-Fi link
    ///     retries for as long as the user leaves the app open, and a haptic per
    ///     attempt is a phone buzzing every few seconds in someone's pocket
    ///     until the battery gives out. The information is "the connection
    ///     dropped", and that is true once.
    ///   * **hanging up is not an error.** `.disconnected(nil)` is the user
    ///     closing the session; they already know, and telling them again with
    ///     the platform's failure pattern reads as "something went wrong".
    ///   * **everything else is silent**, and `.framebufferChanged` is why the
    ///     rule is written as an allow-list rather than a deny-list: it arrives
    ///     tens of times a second, and one slip would turn the phone into a
    ///     buzzer for the length of the session.
    public var haptic: SessionHaptic? {
        switch self {
        case .ready:
            return .success
        case .reconnecting(let attempt):
            return attempt == 1 ? .warning : nil
        case .disconnected(let error):
            return error == nil ? nil : .error
        case .connecting, .authenticating, .framebufferChanged, .resized,
             .clipboard, .bell, .cursor:
            return nil
        }
    }
}
