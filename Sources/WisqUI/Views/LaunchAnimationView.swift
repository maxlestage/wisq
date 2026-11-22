#if os(iOS)
import SwiftUI
import WisqCore
import WisqVM

/// **Le démarrage animé de l'application.**
///
/// La marque se monte pièce par pièce — la plaque, la fenêtre sur une machine
/// ailleurs, les trois pas du lien, le téléphone —, le mot-symbole arrive,
/// quatre lignes d'un journal de démarrage s'écrivent, puis la signature :
/// « Conçu et développé par Maxime Nathan Lestage ». Un peu plus de deux
/// secondes, et un toucher suffit à passer.
///
/// **Le dessin est celui de l'icône et du site** (`crates/wisq-site/src/logo.rs`),
/// aux mêmes coordonnées dans la même boîte de 240 : une seule marque, pas
/// une variante de plus.
///
/// **« Réduire les animations » est respecté** : la marque entière, la
/// signature, et rien qui bouge, le temps de la lire.
struct LaunchAnimationView: View {
    let onFinished: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Combien de pièces de la marque sont posées (0 à 4).
    @State private var pieces = 0
    @State private var wordmark = false
    /// Combien de lignes du journal sont écrites.
    @State private var lines = 0
    @State private var signature = false
    /// Le lien qui pulse une fois la marque posée.
    @State private var pulse = false
    @State private var finished = false

    /// Le journal : ce que wisq sait faire, et sur quoi il tourne. Vrai, pas
    /// décoratif — c'est la plateforme, dite dès l'ouverture.
    private var journal: [String] {
        [
            "wisq ▚ démarrage",
            "cœurs : " + GuestArchitecture.runnable.map(\.name).joined(separator: " · "),
            "hôte : " + HostPlatform.current.summary,
            "prêt.",
        ]
    }

    var body: some View {
        ZStack {
            LaunchPalette.background.ignoresSafeArea()
            VStack(spacing: 28) {
                Spacer()
                markView
                wordmarkView
                journalView
                Spacer()
                signatureView
            }
            .padding(.horizontal, 24)
        }
        .foregroundStyle(.white)
        .contentShape(Rectangle())
        .onTapGesture { finish() }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("wisq, conçu et développé par \(AppCredits.author). Touchez pour continuer.")
        .task { await play() }
    }

    private var markView: some View {
        let glow: Double = pieces >= 4 ? 0.45 : 0
        return WisqMark(pieces: pieces, pulse: pulse)
            .frame(width: 148, height: 148)
            .shadow(color: LaunchPalette.glow.opacity(glow), radius: 28)
    }

    /// Le mot-symbole, comme sur le site : « wisq » et son quadrant.
    private var wordmarkView: some View {
        let scale: CGFloat = wordmark ? 1 : 0.94
        return HStack(spacing: 6) {
            Text("wisq")
            Text("▚").foregroundStyle(LaunchPalette.markEnd)
        }
        .font(.system(size: 44, weight: .bold, design: .rounded))
        .opacity(wordmark ? 1 : 0)
        .scaleEffect(scale)
    }

    private var journalView: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(0..<journal.count, id: \.self) { index in
                journalLine(index)
            }
        }
        .font(.system(.footnote, design: .monospaced))
        .foregroundStyle(LaunchPalette.terminal)
        .frame(maxWidth: 300, alignment: .leading)
    }

    private func journalLine(_ index: Int) -> some View {
        let written = index < lines
        return Text(written ? journal[index] : " ")
            .opacity(written ? 1 : 0)
    }

    private var signatureView: some View {
        let lift: CGFloat = signature ? 0 : 12
        return VStack(spacing: 6) {
            Text(AppCredits.role.uppercased())
                .font(.caption2.weight(.semibold))
                .tracking(2)
                .foregroundStyle(Color.white.opacity(0.55))
            // Le prénom et le nom dans les couleurs de la marque, le second
            // prénom dans celle du texte : la signature du site.
            HStack(spacing: 5) {
                Text("Maxime").foregroundStyle(LaunchPalette.markStart)
                Text("Nathan")
                Text("Lestage").foregroundStyle(LaunchPalette.markEnd)
            }
            .font(.title3.weight(.bold))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            Text(AppCredits.crafted)
                .font(.caption)
                .foregroundStyle(Color.white.opacity(0.45))
        }
        .opacity(signature ? 1 : 0)
        .offset(y: lift)
        .padding(.bottom, 24)
    }

    /// Le déroulé, pas à pas. Chaque attente est un `Task.sleep` : la tâche
    /// de la vue s'annule seule quand elle disparaît.
    private func play() async {
        if reduceMotion {
            pieces = 4
            wordmark = true
            lines = journal.count
            signature = true
            try? await Task.sleep(for: .milliseconds(1400))
            finish()
            return
        }
        for piece in 1...4 {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.72)) { pieces = piece }
            try? await Task.sleep(for: .milliseconds(piece == 3 ? 260 : 170))
        }
        withAnimation(.easeOut(duration: 0.3)) { wordmark = true }
        withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true }
        for line in 1...journal.count {
            try? await Task.sleep(for: .milliseconds(150))
            withAnimation(.easeOut(duration: 0.12)) { lines = line }
        }
        withAnimation(.easeOut(duration: 0.45)) { signature = true }
        try? await Task.sleep(for: .milliseconds(1100))
        finish()
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        onFinished()
    }
}

/// Les couleurs de la marque, fixes comme sur le site : un logo qui change
/// avec le thème n'est pas un logo.
enum LaunchPalette {
    static let background = LinearGradient(
        colors: [Color(hex: 0x171D26), Color(hex: 0x0B0D10)],
        startPoint: .topLeading, endPoint: .bottomTrailing)
    static let plateStart = Color(hex: 0x171D26)
    static let plateEnd = Color(hex: 0x0B0D10)
    static let markStart = Color(hex: 0xA8A2FF)
    static let markEnd = Color(hex: 0x6F64FF)
    static let link = Color(hex: 0x8B83FF)
    static let glow = Color(hex: 0x6F64FF)
    static let terminal = Color(hex: 0xA8E6B4)
}

extension Color {
    /// Une couleur écrite comme sur le site, `0xRRGGBB`.
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

/// **La marque de wisq**, dessinée aux coordonnées du site dans une boîte de
/// 240 et mise à l'échelle. `pieces` dit combien de pièces sont posées :
/// 1 la plaque, 2 la fenêtre, 3 le lien, 4 le téléphone.
///
/// **Une fonction par pièce, et chaque nombre typé.** Écrite d'un seul bloc,
/// la vue faisait renoncer le compilateur d'Apple (« unable to type-check
/// this expression in reasonable time ») : des ternaires qui mêlent `0` et
/// `-18 * unit` dans une chaîne de modificateurs lui laissent trop de types à
/// essayer. La CI Linux ne compile pas `WisqUI` et ne pouvait pas le voir.
struct WisqMark: View {
    var pieces = 4
    var pulse = false

    /// Les trois pas du lien : leur centre sur la diagonale, et leur opacité
    /// (0,38 + pas/2), comme `LIEN` dans `logo.rs`.
    private static let link: [(center: CGFloat, opacity: Double)] = [
        (114.56, 0.46), (120, 0.63), (125.44, 0.8),
    ]

    var body: some View {
        GeometryReader { geometry in
            let side: CGFloat = min(geometry.size.width, geometry.size.height)
            layers(unit: side / 240)
                .frame(width: side, height: side, alignment: .topLeading)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }

    private var markGradient: LinearGradient {
        LinearGradient(colors: [LaunchPalette.markStart, LaunchPalette.markEnd],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private var plateGradient: LinearGradient {
        LinearGradient(colors: [LaunchPalette.plateStart, LaunchPalette.plateEnd],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private func layers(unit: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            plate(unit: unit)
            window(unit: unit)
            ForEach(0..<3, id: \.self) { index in
                linkStep(index, unit: unit)
            }
            phone(unit: unit)
        }
    }

    /// La plaque.
    private func plate(unit: CGFloat) -> some View {
        let shown = pieces >= 1
        let side: CGFloat = 240 * unit
        let radius: CGFloat = 54 * unit
        let border: CGFloat = 1.5 * unit
        let scale: CGFloat = shown ? 1 : 0.86
        let outline = RoundedRectangle(cornerRadius: radius, style: .continuous)
            .strokeBorder(LaunchPalette.link.opacity(0.16), lineWidth: border)
        return RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(plateGradient)
            .overlay(outline)
            .frame(width: side, height: side)
            .opacity(shown ? 1 : 0)
            .scaleEffect(scale)
    }

    /// En haut à gauche : une machine ailleurs, donc une fenêtre.
    private func window(unit: CGFloat) -> some View {
        let shown = pieces >= 2
        let size: CGFloat = 72 * unit
        let bar: CGFloat = 19 * unit
        let shift: CGFloat = shown ? 0 : -18 * unit
        let origin: CGFloat = 40 * unit + shift
        return ZStack(alignment: .topLeading) {
            Rectangle().fill(markGradient)
            Rectangle().fill(LaunchPalette.plateEnd.opacity(0.3))
                .frame(height: bar)
            titleDot(unit: unit, x: 10)
            titleDot(unit: unit, x: 22)
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 13 * unit, style: .continuous))
        .offset(x: origin, y: origin)
        .opacity(shown ? 1 : 0)
    }

    /// Une pastille de la barre de titre, au milieu exact de ses 19 de haut.
    private func titleDot(unit: CGFloat, x: CGFloat) -> some View {
        let size: CGFloat = 6 * unit
        return Circle()
            .fill(LaunchPalette.plateEnd.opacity(0.42))
            .frame(width: size, height: size)
            .offset(x: x * unit, y: 6.5 * unit)
    }

    /// Un des trois pas du lien, à travers l'écart.
    private func linkStep(_ index: Int, unit: CGFloat) -> some View {
        let step = Self.link[index]
        let opacity: Double = pulse ? min(1, step.opacity + 0.2) : step.opacity
        let size: CGFloat = 5 * unit
        let origin: CGFloat = (step.center - 2.5) * unit
        let scale: CGFloat = pulse ? 1.25 : 1
        let delay = Double(index) * 0.07
        return Circle()
            .fill(LaunchPalette.link.opacity(opacity))
            .frame(width: size, height: size)
            .scaleEffect(scale)
            .offset(x: origin, y: origin)
            .opacity(pieces >= 3 ? 1 : 0)
            .animation(.easeOut(duration: 0.2).delay(delay), value: pieces)
    }

    /// En bas à droite : le téléphone dans votre main, écran compris.
    private func phone(unit: CGFloat) -> some View {
        let shown = pieces >= 4
        let size: CGFloat = 72 * unit
        let shift: CGFloat = shown ? 0 : 18 * unit
        let origin: CGFloat = 128 * unit + shift
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 13 * unit, style: .continuous)
                .fill(markGradient)
            RoundedRectangle(cornerRadius: 7 * unit, style: .continuous)
                .fill(LaunchPalette.plateEnd.opacity(0.32))
                .frame(width: 34 * unit, height: 50 * unit)
                .offset(x: 19 * unit, y: 11 * unit)
            Capsule()
                .fill(LaunchPalette.plateEnd.opacity(0.5))
                .frame(width: 14 * unit, height: 2.8 * unit)
                .offset(x: 29 * unit, y: 54 * unit)
        }
        .frame(width: size, height: size)
        .offset(x: origin, y: origin)
        .opacity(shown ? 1 : 0)
    }
}
#endif
