#if os(iOS)
import SwiftUI
import UIKit
import WisqVM

/// **L'écran de la machine PC** : ce que le noyau peint par `simpledrm`, et ce
/// qu'un bureau Linux dessine dessus.
///
/// L'image est relue trente fois par seconde au plus, et seulement quand sa
/// révision a bougé (voir `X86Framebuffer.revision`) : une image immobile ne
/// coûte rien à la batterie. Dix fois par seconde suffisaient à une console ;
/// un bureau, où le pointeur et les fenêtres bougent sous le doigt, saccadait.
///
/// **Le doigt est une souris PS/2**, comme un pavé tactile : glisser déplace
/// le pointeur de l'invité, toucher clique, un appui long fait le clic droit.
/// Le pointeur n'est pas dessiné ici : c'est l'invité qui le dessine, à
/// l'endroit où il croit qu'il est.
///
/// **Pincer zoome, deux doigts déplacent la vue** : voir `ScreenZoom`. Un
/// doigt reste la souris, zoom ou pas.
struct GuestScreenView: View {
    let screen: X86Framebuffer
    let onPointer: (_ dx: Int, _ dy: Int, _ buttons: UInt8) -> Void

    @State private var image: CGImage?
    @State private var shownRevision: UInt64 = .max

    var body: some View {
        GuestScreenCanvas(
            image: image, guestWidth: screen.width, guestHeight: screen.height, onPointer: onPointer)
            .overlay {
                if image == nil {
                    Text("L'invité n'a encore rien dessiné sur son écran.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .allowsHitTesting(false)
                }
            }
            .background(Color.black)
            .accessibilityElement()
            .accessibilityLabel("Écran de la machine")
            .accessibilityHint("Glisser un doigt déplace le pointeur, toucher clique, un appui long fait le clic droit. Pincer zoome, glisser à deux doigts déplace la vue.")
            .task {
                while !Task.isCancelled {
                    refresh()
                    try? await Task.sleep(nanoseconds: 33_000_000)
                }
            }
    }

    private func refresh() {
        let revision = screen.revision
        guard revision != shownRevision else { return }
        shownRevision = revision
        image = Self.makeImage(screen)
    }

    /// XRGB8888 petit-boutien : en mémoire B, G, R, X — ce que Core Graphics
    /// lit sans conversion en « premier octet ignoré, ordre 32 bits petit ».
    static func makeImage(_ screen: X86Framebuffer) -> CGImage? {
        let bytes = screen.snapshot()
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue)
        return CGImage(
            width: screen.width, height: screen.height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: screen.bytesPerRow, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info,
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

/// L'image dans une vue qui défile : c'est `UIScrollView` qui sait pincer et
/// déplacer à deux doigts, avec l'inertie et les bornes qu'on attend sur un
/// iPhone. SwiftUI ne dit pas combien de doigts glissent, et il le faut pour
/// garder un doigt à la souris.
private struct GuestScreenCanvas: UIViewRepresentable {
    let image: CGImage?
    let guestWidth: Int
    let guestHeight: Int
    let onPointer: (_ dx: Int, _ dy: Int, _ buttons: UInt8) -> Void

    func makeUIView(context: Context) -> GuestScreenScrollView {
        let view = GuestScreenScrollView()
        view.onPointer = onPointer
        return view
    }

    func updateUIView(_ view: GuestScreenScrollView, context: Context) {
        view.onPointer = onPointer
        view.show(image, width: guestWidth, height: guestHeight)
    }
}

final class GuestScreenScrollView: UIScrollView, UIScrollViewDelegate {
    var onPointer: ((_ dx: Int, _ dy: Int, _ buttons: UInt8) -> Void)?

    private let canvas = UIImageView()
    private var shownImage: CGImage?
    /// La taille de l'écran de l'invité, en pixels : celle du canevas avant
    /// zoom, si bien que `zoomScale` est le nombre de points par pixel.
    private var guestSize: CGSize = .zero
    /// Un écran neuf s'ajuste à la vue dès qu'elle a une taille.
    private var needsFit = true
    private var pointer = ScreenPointer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        delegate = self
        bouncesZoom = false
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        // Deux doigts déplacent la vue ; un seul est à la souris.
        panGestureRecognizer.minimumNumberOfTouches = 2
        canvas.contentMode = .scaleToFill
        addSubview(canvas)

        let drag = UIPanGestureRecognizer(target: self, action: #selector(handleDrag(_:)))
        drag.maximumNumberOfTouches = 1
        addGestureRecognizer(drag)
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        addGestureRecognizer(tap)
        let press = UILongPressGestureRecognizer(target: self, action: #selector(handlePress(_:)))
        press.minimumPressDuration = 0.5
        addGestureRecognizer(press)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(_ image: CGImage?, width: Int, height: Int) {
        let size = CGSize(width: width, height: height)
        if size != guestSize, width > 0, height > 0 {
            // Le cadre du canevas se pose sans zoom : il est en pixels, et le
            // zoom est une transformation que la vue qui défile lui applique.
            minimumZoomScale = 1
            maximumZoomScale = 1
            zoomScale = 1
            guestSize = size
            canvas.frame = CGRect(origin: .zero, size: size)
            contentSize = size
            needsFit = true
            fitContent()
        }
        if image !== shownImage {
            shownImage = image
            canvas.image = image.map { UIImage(cgImage: $0) }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        fitContent()
    }

    /// Les bornes du zoom pour la vue d'aujourd'hui. Qui regardait l'écran
    /// entier le garde entier quand la vue change — le clavier qui sort ou
    /// rentre, le téléphone qu'on tourne ; qui avait zoomé garde son zoom.
    private func fitContent() {
        guard let fit = ScreenZoom.fit(
            guestWidth: Int(guestSize.width), guestHeight: Int(guestSize.height),
            viewWidth: Double(bounds.width), viewHeight: Double(bounds.height))
        else { return }
        let wasFitted = zoomScale <= minimumZoomScale + 0.0001
        minimumZoomScale = CGFloat(fit)
        maximumZoomScale = CGFloat(fit * ScreenZoom.maximum)
        if needsFit || wasFitted || zoomScale < minimumZoomScale {
            zoomScale = minimumZoomScale
        } else if zoomScale > maximumZoomScale {
            zoomScale = maximumZoomScale
        }
        needsFit = false
        center()
    }

    /// Ce qui reste de la vue autour d'un écran plus petit qu'elle se
    /// partage des deux côtés.
    private func center() {
        let scaled = CGSize(width: guestSize.width * zoomScale, height: guestSize.height * zoomScale)
        contentInset = UIEdgeInsets(
            top: max(0, (bounds.height - scaled.height) / 2),
            left: max(0, (bounds.width - scaled.width) / 2),
            bottom: 0,
            right: 0)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { canvas }

    func scrollViewDidZoom(_ scrollView: UIScrollView) { center() }

    // MARK: - La souris

    @objc private func handleDrag(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .changed:
            let travel = gesture.translation(in: self)
            gesture.setTranslation(.zero, in: self)
            if let step = pointer.move(
                dx: Double(travel.x), dy: Double(travel.y), pointsPerPixel: Double(zoomScale)) {
                onPointer?(step.dx, step.dy, 0)
            }
        case .ended, .cancelled, .failed:
            pointer.lift()
        default:
            break
        }
    }

    @objc private func handleTap() { click(1) }

    @objc private func handlePress(_ gesture: UILongPressGestureRecognizer) {
        if gesture.state == .began { click(2) }
    }

    private func click(_ button: UInt8) {
        onPointer?(0, 0, button)
        onPointer?(0, 0, 0)
    }
}
#endif
