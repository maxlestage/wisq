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
/// **Le doigt pointe là où il touche**, quand l'invité a pris la tablette
/// (`VirtioTablet`) : toucher clique à cet endroit, un appui long y fait le
/// clic droit, glisser y traîne avec le bouton enfoncé — une fenêtre, une
/// sélection. **Sinon, le doigt est une souris PS/2**, comme un pavé tactile :
/// glisser déplace le pointeur, toucher clique où il est. Le pointeur n'est
/// pas dessiné ici : c'est l'invité qui le dessine.
///
/// **Pincer zoome, deux doigts déplacent la vue** : voir `ScreenZoom`. Un
/// doigt reste la souris, zoom ou pas.
struct GuestScreenView: View {
    let screen: X86Framebuffer
    /// Un toucher absolu, de 0 à 1 ; faux quand la tablette n'est pas prise.
    var onTouch: (_ x: Double, _ y: Double, _ buttons: UInt8) -> Bool = { _, _, _ in false }
    let onPointer: (_ dx: Int, _ dy: Int, _ buttons: UInt8) -> Void

    @State private var image: CGImage?
    @State private var shownRevision: UInt64 = .max

    var body: some View {
        // La taille de l'image, pas celle de l'écran lue à part : le pilote de
        // la carte change de résolution (`X86BochsDisplay`), et l'image dit
        // celle qu'elle a vraiment.
        GuestScreenCanvas(
            image: image, guestWidth: image?.width ?? screen.width,
            guestHeight: image?.height ?? screen.height, onTouch: onTouch, onPointer: onPointer)
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
            .accessibilityHint("Toucher clique à cet endroit, un appui long fait le clic droit, glisser un doigt traîne. Pincer zoome, glisser à deux doigts déplace la vue.")
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
    ///
    /// Le mode et ses pixels sont pris ensemble (`frame`) : une résolution qui
    /// change entre les deux lectures ferait une image de travers.
    static func makeImage(_ screen: X86Framebuffer) -> CGImage? {
        let (mode, pixels) = screen.frame()
        guard let provider = CGDataProvider(data: pixels as CFData) else { return nil }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue)
        return CGImage(
            width: mode.width, height: mode.height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: mode.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info,
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
    let onTouch: (_ x: Double, _ y: Double, _ buttons: UInt8) -> Bool
    let onPointer: (_ dx: Int, _ dy: Int, _ buttons: UInt8) -> Void

    func makeUIView(context: Context) -> GuestScreenScrollView {
        let view = GuestScreenScrollView()
        view.onTouch = onTouch
        view.onPointer = onPointer
        return view
    }

    func updateUIView(_ view: GuestScreenScrollView, context: Context) {
        view.onTouch = onTouch
        view.onPointer = onPointer
        view.show(image, width: guestWidth, height: guestHeight)
    }
}

final class GuestScreenScrollView: UIScrollView, UIScrollViewDelegate {
    var onTouch: ((_ x: Double, _ y: Double, _ buttons: UInt8) -> Bool)?
    var onPointer: ((_ dx: Int, _ dy: Int, _ buttons: UInt8) -> Void)?
    /// Le glissement en cours passe par la tablette (décidé à son début).
    private var draggingAbsolute = false
    /// Le dernier endroit touché sur l'écran : un doigt qui sort de l'écran
    /// en glissant relâche le bouton là, pas dans un coin.
    private var lastSpot: (x: Double, y: Double)?

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
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
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

    /// Le doigt, de 0 à 1 sur l'écran de l'invité, ou nil hors de l'écran.
    private func place(_ gesture: UIGestureRecognizer) -> (x: Double, y: Double)? {
        let at = gesture.location(in: canvas)
        return ScreenTouch.fraction(x: Double(at.x), y: Double(at.y),
                                    width: Double(guestSize.width), height: Double(guestSize.height))
    }

    /// Un toucher absolu ; faux si la tablette n'est pas prise.
    private func touch(_ gesture: UIGestureRecognizer, _ buttons: UInt8) -> Bool {
        guard let spot = place(gesture) ?? (draggingAbsolute ? lastSpot : nil), let onTouch else { return false }
        lastSpot = spot
        return onTouch(spot.x, spot.y, buttons)
    }

    @objc private func handleDrag(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            // Le bouton enfoncé là où le doigt s'est posé, et tenu.
            draggingAbsolute = touch(gesture, 0) && touch(gesture, 1)
        case .changed where draggingAbsolute:
            _ = touch(gesture, 1)
        case .ended where draggingAbsolute, .cancelled where draggingAbsolute, .failed where draggingAbsolute:
            // Relâché là où le doigt est, ou au dernier endroit de l'écran.
            _ = touch(gesture, 0)
            draggingAbsolute = false
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

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        // Là où le doigt a touché ; sinon, là où est le pointeur.
        if touch(gesture, 0), touch(gesture, 1), touch(gesture, 0) { return }
        click(1)
    }

    @objc private func handlePress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        if touch(gesture, 0), touch(gesture, 2), touch(gesture, 0) { return }
        click(2)
    }

    private func click(_ button: UInt8) {
        onPointer?(0, 0, button)
        onPointer?(0, 0, 0)
    }
}
#endif
