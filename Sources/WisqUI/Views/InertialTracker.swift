#if os(iOS)
import UIKit

/// Gives a gesture momentum after the finger lifts.
///
/// UIKit's physics engine already integrates velocity against a resistance every
/// frame, and `UIDynamicItem` is the interface it drives. Conforming a bare object
/// to it — rather than a view — lets the pointer and the scroll wheel coast with
/// no animation loop of our own. The idea is lifted from UTM's `VMCursor`.
@MainActor
final class InertialTracker: NSObject, UIDynamicItem {
    /// Called with the movement since the last tick, whether the finger or the
    /// physics engine produced it.
    var onDelta: ((CGSize) -> Void)?

    // UIDynamicItem: the animator writes `center` on every frame.
    var bounds = CGRect(x: 0, y: 0, width: 1, height: 1)
    var transform: CGAffineTransform = .identity

    private var storedCenter: CGPoint = .zero
    private let animator = UIDynamicAnimator()

    var center: CGPoint {
        get { storedCenter }
        set {
            let delta = CGSize(width: newValue.x - storedCenter.x, height: newValue.y - storedCenter.y)
            storedCenter = newValue
            if delta.width != 0 || delta.height != 0 {
                onDelta?(delta)
            }
        }
    }

    /// Starts a gesture, cancelling any coasting still under way.
    func begin(at point: CGPoint) {
        animator.removeAllBehaviors()
        storedCenter = point
    }

    func update(to point: CGPoint) {
        center = point
    }

    /// Hands the remaining velocity to the physics engine. Higher `resistance`
    /// stops it sooner.
    func end(velocity: CGPoint, resistance: CGFloat) {
        let behavior = UIDynamicItemBehavior(items: [self])
        behavior.addLinearVelocity(velocity, for: self)
        behavior.resistance = resistance
        animator.addBehavior(behavior)
    }

    func stop() {
        animator.removeAllBehaviors()
    }
}
#endif
