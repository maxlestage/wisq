#if os(iOS)
import UIKit
#endif
import WisqRemote

/// Plays the haptic a session event asked for.
///
/// The *decision* — which events are worth one, and which would turn the phone
/// into a buzzer — lives in `WisqRemote.SessionEvent.haptic`, where a Linux
/// runner can test it. This is only the mapping onto the platform.
///
/// **The type exists on every platform; only its body varies.** Most of
/// `WisqUI` is wrapped in `#if os(iOS)` as a whole file, but `SessionModel` is
/// not — it builds for macOS too — so a haptics type that vanished with the
/// platform would take its callers' code with it and leave the calls behind.
/// That is exactly what happened: the first version guarded the file, and the
/// macOS build failed with `cannot find 'SessionHaptics' in scope` while every
/// Linux check stayed green, because Linux does not build `WisqUI` at all.
/// Guarding the *implementation* instead keeps the call sites plain.
@MainActor
enum SessionHaptics {
    #if os(iOS)
    /// Held rather than made per event, and told to get ready.
    ///
    /// A `UINotificationFeedbackGenerator` created and used in the same breath
    /// has to wake the Taptic Engine first, so the tap lands late enough to feel
    /// disconnected from what caused it — which, for a confirmation, is worse
    /// than no tap at all.
    private static let generator = UINotificationFeedbackGenerator()

    /// Warms the engine while the user is waiting for something that will end
    /// in a haptic. Cheap, and it lapses on its own after a moment.
    static func prepare() { generator.prepare() }

    static func play(_ haptic: SessionHaptic) {
        switch haptic {
        case .success: generator.notificationOccurred(.success)
        case .warning: generator.notificationOccurred(.warning)
        case .error: generator.notificationOccurred(.error)
        }
        // A session that just connected may be about to drop; one that just
        // dropped is about to retry. Staying ready costs nothing.
        generator.prepare()
    }
    #else
    /// A Mac has no Taptic Engine, and the trackpad's is not the app's to use
    /// for a connection it is not touching. Nothing to play, and nothing to
    /// apologise for: the status text already says what happened.
    static func prepare() {}
    static func play(_ haptic: SessionHaptic) {}
    #endif
}
