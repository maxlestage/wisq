#if os(iOS)
import SwiftUI
import UIKit
import WisqCore
import WisqRemote

/// The remote screen: a zoomable canvas backed by the session's framebuffer, with
/// the touch model that makes a desktop usable on a phone.
///
/// One finger always drives the pointer. What two and three fingers do is a
/// setting, because the right answer depends on whether the desktop fits on
/// screen — panning a view that has nowhere to pan is wasted, and scrolling a
/// guest you cannot see all of is worse.
public struct RemoteDisplayView: UIViewRepresentable {
    let model: SessionModel
    /// Raised when a three-finger swipe asks for the keyboard.
    var onKeyboardRequest: ((Bool) -> Void)?

    public init(model: SessionModel, onKeyboardRequest: ((Bool) -> Void)? = nil) {
        self.model = model
        self.onKeyboardRequest = onKeyboardRequest
    }

    public func makeUIView(context: Context) -> RemoteDisplayScrollView {
        let view = RemoteDisplayScrollView()
        view.configure(model: model)
        view.onKeyboardRequest = onKeyboardRequest
        return view
    }

    public func updateUIView(_ view: RemoteDisplayScrollView, context: Context) {
        view.onKeyboardRequest = onKeyboardRequest
        // `frameGeneration` is read here so SwiftUI re-invokes us on every update.
        view.refresh(generation: model.frameGeneration, size: model.size)
    }
}

/// Scroll view that owns zooming and panning; the canvas inside owns the pixels.
public final class RemoteDisplayScrollView: UIScrollView, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    /// Resistance handed to the physics engine when a gesture ends. The pointer
    /// coasts further than the scroll wheel, which should stop close to the finger.
    private static let cursorResistance: CGFloat = 50
    private static let scrollResistance: CGFloat = 10
    /// Travel, in points, that makes one wheel notch.
    private static let pointsPerScrollNotch: CGFloat = 40

    var onKeyboardRequest: ((Bool) -> Void)?

    private let canvas = RemoteCanvasView()
    private weak var model: SessionModel?
    private var lastGeneration: UInt64 = .max
    private var lastSize: CGSize = .zero

    private let cursorInertia = InertialTracker()
    private let scrollInertia = InertialTracker()
    private var scrollRemainder: CGFloat = 0

    private var onePan: UIPanGestureRecognizer!
    private var twoPan: UIPanGestureRecognizer!
    private var threePan: UIPanGestureRecognizer!
    private var tap: UITapGestureRecognizer!
    private var twoTap: UITapGestureRecognizer!
    private var longPress: UILongPressGestureRecognizer!
    private var swipeUp: UISwipeGestureRecognizer!
    private var swipeDown: UISwipeGestureRecognizer!

    public override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        delegate = self
        maximumZoomScale = 8
        minimumZoomScale = 1
        bouncesZoom = false
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        addSubview(canvas)
        installGestures()
        installInertia()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(model: SessionModel) {
        self.model = model
        canvas.model = model
        applySettings(model.machine.input)
    }

    func refresh(generation: UInt64, size: CGSize) {
        if size != lastSize, size.width > 0, size.height > 0 {
            lastSize = size
            canvas.frame = CGRect(origin: .zero, size: size)
            contentSize = size
            fitContent()
        }
        guard generation != lastGeneration else { return }
        lastGeneration = generation
        canvas.redraw()
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        fitContent()
        model?.viewportChanged(to: bounds.size)
    }

    /// Scales the desktop so it fits the device screen and centres what is left over.
    private func fitContent() {
        guard lastSize.width > 0, lastSize.height > 0, bounds.width > 0, bounds.height > 0 else { return }
        let scale = min(bounds.width / lastSize.width, bounds.height / lastSize.height)
        minimumZoomScale = scale
        if zoomScale < scale { zoomScale = scale }

        let scaled = CGSize(width: lastSize.width * zoomScale, height: lastSize.height * zoomScale)
        contentInset = UIEdgeInsets(
            top: max(0, (bounds.height - scaled.height) / 2),
            left: max(0, (bounds.width - scaled.width) / 2),
            bottom: 0,
            right: 0
        )
    }

    public func viewForZooming(in scrollView: UIScrollView) -> UIView? { canvas }

    public func scrollViewDidZoom(_ scrollView: UIScrollView) { fitContent() }

    // MARK: - Setup

    private func installGestures() {
        onePan = UIPanGestureRecognizer(target: self, action: #selector(handleOnePan))
        onePan.maximumNumberOfTouches = 1
        onePan.cancelsTouchesInView = false

        twoPan = UIPanGestureRecognizer(target: self, action: #selector(handleTwoPan))
        twoPan.minimumNumberOfTouches = 2
        twoPan.maximumNumberOfTouches = 2

        threePan = UIPanGestureRecognizer(target: self, action: #selector(handleThreePan))
        threePan.minimumNumberOfTouches = 3
        threePan.maximumNumberOfTouches = 3

        tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        twoTap = UITapGestureRecognizer(target: self, action: #selector(handleTwoTap))
        twoTap.numberOfTouchesRequired = 2

        longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress))
        longPress.minimumPressDuration = 0.45

        swipeUp = UISwipeGestureRecognizer(target: self, action: #selector(handleSwipe))
        swipeUp.direction = .up
        swipeUp.numberOfTouchesRequired = 3
        swipeDown = UISwipeGestureRecognizer(target: self, action: #selector(handleSwipe))
        swipeDown.direction = .down
        swipeDown.numberOfTouchesRequired = 3

        for recognizer in [onePan, twoPan, threePan, tap, twoTap, longPress, swipeUp, swipeDown] as [UIGestureRecognizer] {
            recognizer.delegate = self
            canvas.addGestureRecognizer(recognizer)
        }
    }

    private func installInertia() {
        cursorInertia.onDelta = { [weak self] delta in
            self?.model?.movePointer(by: delta)
            self?.canvas.updateCursor()
        }
        scrollInertia.onDelta = { [weak self] delta in
            guard let self else { return }
            scrollRemainder += delta.height
            let notches = Int(scrollRemainder / Self.pointsPerScrollNotch)
            if notches != 0 {
                model?.scroll(vertical: notches)
                scrollRemainder -= CGFloat(notches) * Self.pointsPerScrollNotch
            }
        }
    }

    /// Wires the gesture set to the machine's settings. The scroll view's own pan
    /// is only enabled when some gesture is actually assigned to moving the screen.
    private func applySettings(_ input: InputSettings) {
        twoPan.isEnabled = input.twoFingerPanAction != .none && input.twoFingerPanAction != .moveScreen
        threePan.isEnabled = input.threeFingerPanAction != .none && input.threeFingerPanAction != .moveScreen
        twoTap.isEnabled = input.twoFingerTapAction != .none
        longPress.isEnabled = input.longPressAction != .none
        swipeUp.isEnabled = input.threeFingerSwipeShowsKeyboard
        swipeDown.isEnabled = input.threeFingerSwipeShowsKeyboard

        if input.twoFingerPanAction == .moveScreen {
            isScrollEnabled = true
            panGestureRecognizer.minimumNumberOfTouches = 2
        } else if input.threeFingerPanAction == .moveScreen {
            isScrollEnabled = true
            panGestureRecognizer.minimumNumberOfTouches = 3
        } else {
            // Pinch still works; only dragging the view is off.
            isScrollEnabled = false
        }
    }

    // MARK: - Gesture handlers

    @objc private func handleOnePan(_ gesture: UIPanGestureRecognizer) {
        guard let model else { return }
        let point = gesture.location(in: canvas)

        switch model.machine.input.pointerMode {
        case .directTouch:
            model.movePointer(to: point)
        case .trackpad:
            drive(cursorInertia, with: gesture, point: point,
                  resistance: Self.cursorResistance, allowInertia: model.machine.input.inertia)
        }
    }

    @objc private func handleTwoPan(_ gesture: UIPanGestureRecognizer) {
        perform(model?.machine.input.twoFingerPanAction ?? .none, pan: gesture)
    }

    @objc private func handleThreePan(_ gesture: UIPanGestureRecognizer) {
        perform(model?.machine.input.threeFingerPanAction ?? .none, pan: gesture)
    }

    private func perform(_ action: GestureAction, pan gesture: UIPanGestureRecognizer) {
        guard let model else { return }
        switch action {
        case .scrollWheel:
            drive(scrollInertia, with: gesture, point: gesture.location(in: canvas),
                  resistance: Self.scrollResistance, allowInertia: model.machine.input.inertia)
        case .dragCursor:
            if gesture.state == .began {
                model.setButton(.left, down: true)
                feedback(.medium)
            }
            drive(cursorInertia, with: gesture, point: gesture.location(in: canvas),
                  resistance: 0, allowInertia: false)
            if gesture.state == .ended || gesture.state == .cancelled {
                model.setButton(.left, down: false)
            }
        case .none, .moveScreen, .leftClick, .rightClick, .middleClick, .showKeyboard:
            break
        }
    }

    /// Feeds a pan into an inertial tracker, handing the leftover velocity to the
    /// physics engine when the finger lifts.
    private func drive(
        _ tracker: InertialTracker,
        with gesture: UIPanGestureRecognizer,
        point: CGPoint,
        resistance: CGFloat,
        allowInertia: Bool
    ) {
        switch gesture.state {
        case .began:
            tracker.begin(at: point)
        case .changed:
            tracker.update(to: point)
        case .ended:
            tracker.update(to: point)
            if allowInertia {
                tracker.end(velocity: gesture.velocity(in: canvas), resistance: resistance)
            }
        case .cancelled, .failed:
            tracker.stop()
        default:
            break
        }
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard let model else { return }
        cursorInertia.stop()
        if model.machine.input.pointerMode == .directTouch {
            model.click(.left, at: gesture.location(in: canvas))
        } else {
            model.click(.left)
        }
        feedback(.light)
    }

    @objc private func handleTwoTap(_ gesture: UITapGestureRecognizer) {
        guard let model else { return }
        performDiscrete(model.machine.input.twoFingerTapAction, at: gesture.location(in: canvas))
    }

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard let model else { return }
        let action = model.machine.input.longPressAction

        if action == .dragCursor {
            // Press-and-hold to drag: the button follows the gesture's lifetime.
            switch gesture.state {
            case .began:
                model.setButton(.left, down: true)
                feedback(.medium)
            case .ended, .cancelled:
                model.setButton(.left, down: false)
            default:
                break
            }
            return
        }

        guard gesture.state == .began else { return }
        performDiscrete(action, at: gesture.location(in: canvas))
    }

    private func performDiscrete(_ action: GestureAction, at point: CGPoint) {
        guard let model else { return }
        let target = model.machine.input.pointerMode == .directTouch ? point : nil
        switch action {
        case .leftClick:
            model.click(.left, at: target)
        case .rightClick:
            model.click(.right, at: target)
        case .middleClick:
            model.click(.middle, at: target)
        case .showKeyboard:
            onKeyboardRequest?(true)
        case .none, .dragCursor, .moveScreen, .scrollWheel:
            return
        }
        feedback(.medium)
    }

    @objc private func handleSwipe(_ gesture: UISwipeGestureRecognizer) {
        onKeyboardRequest?(gesture.direction == .up)
    }

    private func feedback(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        guard model?.machine.input.hapticFeedback == true else { return }
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }

    // MARK: - Gesture arbitration
    //
    // Without this the recognisers fight: a two-finger tap also reads as a tap,
    // and a long press fires under every tap that lingers.

    public func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRequireFailureOf other: UIGestureRecognizer
    ) -> Bool {
        if gestureRecognizer === tap, other === twoTap { return true }
        if gestureRecognizer === longPress, other === tap || other === twoTap { return true }
        if gestureRecognizer === twoPan, other === swipeUp || other === swipeDown { return true }
        if gestureRecognizer === threePan, other === swipeUp || other === swipeDown { return true }
        if gestureRecognizer === onePan, other === longPress { return false }
        return false
    }

    public func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        // A drag started by a long press has to keep moving the pointer.
        if gestureRecognizer === onePan, other === longPress { return true }
        if gestureRecognizer === longPress, other === onePan { return true }
        // Panning the view and pinching it are one continuous gesture.
        if other === pinchGestureRecognizer || gestureRecognizer === pinchGestureRecognizer { return true }
        return false
    }
}

/// Draws the framebuffer, plus the virtual cursor in trackpad mode.
///
/// The pixels live in a sublayer rather than in `draw(_:)`: handing Core Animation
/// a `CGImage` per frame avoids a full re-rasterisation of a 1080p desktop on every
/// update, and it leaves the cursor free to move without touching the pixels.
final class RemoteCanvasView: UIView {
    weak var model: SessionModel?

    private let imageLayer = CALayer()
    private let cursorLayer = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = true
        backgroundColor = .black
        isUserInteractionEnabled = true

        imageLayer.magnificationFilter = .nearest
        imageLayer.minificationFilter = .trilinear
        layer.addSublayer(imageLayer)

        cursorLayer.fillColor = UIColor.clear.cgColor
        cursorLayer.strokeColor = UIColor.white.cgColor
        cursorLayer.lineWidth = 2
        cursorLayer.shadowColor = UIColor.black.cgColor
        cursorLayer.shadowOpacity = 0.7
        cursorLayer.shadowRadius = 2
        cursorLayer.shadowOffset = .zero
        cursorLayer.isHidden = true
        layer.addSublayer(cursorLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Layer geometry changes must not animate; the desktop would smear.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = bounds
        cursorLayer.frame = bounds
        CATransaction.commit()
    }

    func redraw() {
        guard let framebuffer = model?.framebuffer else { return }
        let image = RemoteCanvasView.makeImage(from: framebuffer)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = image
        updateCursor()
        CATransaction.commit()
    }

    func updateCursor() {
        guard let model, model.machine.input.pointerMode == .trackpad, model.status.isLive else {
            cursorLayer.isHidden = true
            return
        }
        cursorLayer.isHidden = false
        let radius: CGFloat = 9
        let origin = CGPoint(x: model.pointer.x - radius, y: model.pointer.y - radius)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cursorLayer.path = UIBezierPath(
            ovalIn: CGRect(origin: origin, size: CGSize(width: radius * 2, height: radius * 2))
        ).cgPath
        CATransaction.commit()
    }

    /// Wraps the BGRA snapshot in a `CGImage`. The pixel layout matches
    /// `byteOrder32Little` + `noneSkipFirst`, so there is no per-frame conversion.
    static func makeImage(from framebuffer: Framebuffer) -> CGImage? {
        let (width, height, pixels) = framebuffer.snapshot()
        guard width > 0, height > 0, !pixels.isEmpty,
              let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }

        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue)
                .union(.byteOrder32Little),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
}
#endif
