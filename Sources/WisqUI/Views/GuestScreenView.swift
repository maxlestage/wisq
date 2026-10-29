#if os(iOS)
import SwiftUI
import UIKit
import WisqVM

/// **L'écran de la machine PC** : ce que le noyau peint par `simpledrm`, et ce
/// qu'un bureau Linux dessine dessus.
///
/// L'image est relue dix fois par seconde au plus, et seulement quand sa
/// révision a bougé (voir `X86Framebuffer.revision`) : une image immobile ne
/// coûte rien à la batterie.
///
/// **Le doigt est une souris PS/2**, comme un pavé tactile : glisser déplace
/// le pointeur de l'invité, toucher clique, un appui long fait le clic droit.
/// Le pointeur n'est pas dessiné ici : c'est l'invité qui le dessine, à
/// l'endroit où il croit qu'il est.
struct GuestScreenView: View {
    let screen: X86Framebuffer
    let onPointer: (_ dx: Int, _ dy: Int, _ buttons: UInt8) -> Void

    @State private var image: CGImage?
    @State private var shownRevision: UInt64 = .max
    @State private var lastTranslation: CGSize = .zero
    /// Ce que le doigt a parcouru sans faire encore un pixel de l'invité :
    /// sans ce reste, un glissement lent n'avancerait jamais.
    @State private var remainder: CGSize = .zero

    var body: some View {
        GeometryReader { geometry in
            let scale = min(geometry.size.width / CGFloat(screen.width),
                            geometry.size.height / CGFloat(screen.height))
            ZStack {
                Color.black
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.medium)
                        .scaledToFit()
                } else {
                    Text("L'invité n'a encore rien dessiné sur son écran.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { click(1) }
            .onLongPressGesture(minimumDuration: 0.5) { click(2) }
            .simultaneousGesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        let step = CGSize(width: value.translation.width - lastTranslation.width,
                                          height: value.translation.height - lastTranslation.height)
                        lastTranslation = value.translation
                        move(step, scale: max(scale, 0.01))
                    }
                    .onEnded { _ in
                        lastTranslation = .zero
                        remainder = .zero
                    }
            )
            .accessibilityLabel("Écran de la machine")
            .accessibilityHint("Glisser déplace le pointeur, toucher clique, un appui long fait le clic droit.")
        }
        .task {
            while !Task.isCancelled {
                refresh()
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    private func move(_ step: CGSize, scale: CGFloat) {
        // Des points de l'iPhone aux pixels de l'invité.
        let x = step.width / scale + remainder.width
        let y = step.height / scale + remainder.height
        let dx = Int(x.rounded(.towardZero)), dy = Int(y.rounded(.towardZero))
        remainder = CGSize(width: x - CGFloat(dx), height: y - CGFloat(dy))
        guard dx != 0 || dy != 0 else { return }
        onPointer(dx, dy, 0)
    }

    private func click(_ button: UInt8) {
        onPointer(0, 0, button)
        onPointer(0, 0, 0)
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
#endif
