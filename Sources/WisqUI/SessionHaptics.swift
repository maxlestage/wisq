#if os(iOS)
import UIKit
import WisqRemote

/// Plays the haptic a session event asked for.
///
/// The *decision* — which events are worth one, and which would turn the phone
/// into a buzzer — lives in `WisqRemote.SessionEvent.haptic`, where a Linux
/// runner can test it. This is only the mapping onto the platform, which has
/// nothing to get wrong.
///
/// The generator is held rather than made per event, and told to get ready. A
/// `UINotificationFeedbackGenerator` created and used in the same breath has to
/// wake the Taptic Engine first, so the tap lands late enough to feel
/// disconnected from what caused it — which for a confirmation is worse than no
/// tap at all.
@MainActor
enum SessionHaptics {
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
}
#endif
