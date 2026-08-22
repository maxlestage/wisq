#if os(iOS)
import SwiftUI
import UIKit
import WisqCore
import WisqRemote

/// The remote screen: a zoomable canvas backed by the session's framebuffer, with
/// the touch model that makes a desktop usable on a phone.
///
/// Gesture layout, chosen so nothing is ambiguous:
///   - one finger   → moves the pointer (absolute in direct-touch, relative in trackpad)
///   - one tap      → left click
///   - two-finger tap → right click
///   - long press   → right click
///   - two fingers  → scrolls the guest when fully zoomed out, pans the view otherwise
///   - pinch        → zoom
public struct RemoteDisplayView: UIViewRepresentable {
    let model: SessionModel

    public init(model: SessionModel) {
        self.model = model
    }

    public func makeUIView(context: Context) -> RemoteDisplayScrollView {
        let view = RemoteDisplayScrollView()
        view.configure(model: model)
        return view
    }

    public func updateUIView(_ view: RemoteDisplayScrollView, context: Context) {
        // `frameGeneration` is read here so SwiftUI re-invokes us on every update.
        view.refresh(generation: model.frameGeneration, size: model.size)
    }
}

/// Scroll view that owns zooming and panning; the canvas inside owns the pixels.
public final class RemoteDisplayScrollView: UIScrollView, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    private let canvas = RemoteCanvasView()
    private weak var model: SessionModel?
    private var lastGeneration: UInt64 = .max
    private var lastSize: CGSize = .zero

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
        // One finger belongs to the pointer, never to panning the view.
        panGestureRecognizer.minimumNumberOfTouches = 2
        addSubview(canvas)
        installGestures()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(model: SessionModel) {
        self.model = model
        canvas.model = model
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

    // MARK: - Gestures

    private func installGestures() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        canvas.addGestureRecognizer(tap)

        let twoFingerTap = UITapGestureRecognizer(target: self, action: #selector(handleTwoFingerTap))
        twoFingerTap.numberOfTouchesRequired = 2
        canvas.addGestureRecognizer(twoFingerTap)

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress))
        longPress.minimumPressDuration = 0.45
        canvas.addGestureRecognizer(longPress)

        let drag = UIPanGestureRecognizer(target: self, action: #selector(handleDrag))
        drag.maximumNumberOfTouches = 1
        canvas.addGestureRecognizer(drag)

        let wheel = UIPanGestureRecognizer(target: self, action: #selector(handleWheel))
        wheel.minimumNumberOfTouches = 2
        wheel.maximumNumberOfTouches = 2
        wheel.delegate = self
        canvas.addGestureRecognizer(wheel)
    }

    /// Two fingers scroll the guest only when there is nothing to pan, otherwise the
    /// scroll view's own pan wins and the user moves around the desktop.
    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer.view === canvas,
              gestureRecognizer is UIPanGestureRecognizer,
              gestureRecognizer.numberOfTouches == 2 else { return true }
        return zoomScale <= minimumZoomScale + 0.001
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard let model else { return }
        if model.machine.input.pointerMode == .directTouch {
            model.click(.left, at: gesture.location(in: canvas))
        } else {
            model.click(.left)
        }
        feedback(.light)
    }

    @objc private func handleTwoFingerTap(_ gesture: UITapGestureRecognizer) {
        guard let model, model.machine.input.longPressRightClick else { return }
        model.click(.right)
        feedback(.medium)
    }

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard let model, model.machine.input.longPressRightClick, gesture.state == .began else { return }
        if model.machine.input.pointerMode == .directTouch {
            model.click(.right, at: gesture.location(in: canvas))
        } else {
            model.click(.right)
        }
        feedback(.medium)
    }

    private var lastDragPoint: CGPoint = .zero

    @objc private func handleDrag(_ gesture: UIPanGestureRecognizer) {
        guard let model else { return }
        let point = gesture.location(in: canvas)

        switch model.machine.input.pointerMode {
        case .directTouch:
            model.movePointer(to: point)
        case .trackpad:
            switch gesture.state {
            case .began:
                lastDragPoint = point
            case .changed:
                model.movePointer(by: CGSize(width: point.x - lastDragPoint.x, height: point.y - lastDragPoint.y))
                lastDragPoint = point
                canvas.updateCursor()
            default:
                break
            }
        }
    }

    private var wheelAccumulator: CGFloat = 0

    @objc private func handleWheel(_ gesture: UIPanGestureRecognizer) {
        guard let model else { return }
        switch gesture.state {
        case .began:
            wheelAccumulator = 0
        case .changed:
            wheelAccumulator += gesture.translation(in: canvas).y
            gesture.setTranslation(.zero, in: canvas)
            // One notch per 40 points of travel, the same feel as a trackpad.
            let notches = Int(wheelAccumulator / 40)
            if notches != 0 {
                model.scroll(vertical: notches)
                wheelAccumulator -= CGFloat(notches) * 40
            }
        default:
            break
        }
    }

    private func feedback(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        guard model?.machine.input.hapticFeedback == true else { return }
        UIImpactFeedbackGenerator(style: style).impactOccurred()
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
        cursorLayer.path = UIBezierPath(
            ovalIn: CGRect(origin: origin, size: CGSize(width: radius * 2, height: radius * 2))
        ).cgPath
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
