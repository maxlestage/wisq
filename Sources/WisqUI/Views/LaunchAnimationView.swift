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
                WisqMark(pieces: pieces, pulse: pulse)
                    .frame(width: 148, height: 148)
                    .shadow(color: LaunchPalette.glow.opacity(pieces >= 4 ? 0.45 : 0), radius: 28)
                // Le mot-symbole, comme sur le site : « wisq » et son quadrant.
                HStack(spacing: 6) {
                    Text("wisq")
                    Text("▚").foregroundStyle(LaunchPalette.markEnd)
                }
                .font(.system(size: 44, weight: .bold, design: .rounded))
                .opacity(wordmark ? 1 : 0)
                .scaleEffect(wordmark ? 1 : 0.94)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(journal.enumerated()), id: \.offset) { index, line in
                        Text(index < lines ? line : " ")
                            .opacity(index < lines ? 1 : 0)
                    }
                }
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(LaunchPalette.terminal)
                .frame(maxWidth: 300, alignment: .leading)
                .accessibilityHidden(true)
                Spacer()
                VStack(spacing: 6) {
                    Text(AppCredits.role.uppercased())
                        .font(.caption2.weight(.semibold))
                        .tracking(2)
                        .foregroundStyle(.white.opacity(0.55))
                    // Le prénom et le nom dans les couleurs de la marque, le
                    // second prénom dans celle du texte : la signature du site.
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
                        .foregroundStyle(.white.opacity(0.45))
                }
                .opacity(signature ? 1 : 0)
                .offset(y: signature ? 0 : 12)
                .accessibilityElement(children: .combine)
                .padding(.bottom, 24)
            }
            .padding(.horizontal, 24)
        }
        .foregroundStyle(.white)
        .contentShape(Rectangle())
        .onTapGesture { finish() }
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("wisq, conçu et développé par \(AppCredits.author). Touchez pour continuer.")
        .task { await play() }
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
            let side = min(geometry.size.width, geometry.size.height)
            let unit = side / 240
            let mark = LinearGradient(colors: [LaunchPalette.markStart, LaunchPalette.markEnd],
                                      startPoint: .topLeading, endPoint: .bottomTrailing)
            ZStack(alignment: .topLeading) {
                // La plaque.
                RoundedRectangle(cornerRadius: 54 * unit, style: .continuous)
                    .fill(LinearGradient(colors: [LaunchPalette.plateStart, LaunchPalette.plateEnd],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay(
                        RoundedRectangle(cornerRadius: 54 * unit, style: .continuous)
                            .strokeBorder(LaunchPalette.link.opacity(0.16), lineWidth: 1.5 * unit))
                    .frame(width: side, height: side)
                    .opacity(pieces >= 1 ? 1 : 0)
                    .scaleEffect(pieces >= 1 ? 1 : 0.86)

                // En haut à gauche : une machine ailleurs, donc une fenêtre.
                ZStack(alignment: .topLeading) {
                    Rectangle().fill(mark)
                    Rectangle().fill(LaunchPalette.plateEnd.opacity(0.3))
                        .frame(height: 19 * unit)
                    Circle().fill(LaunchPalette.plateEnd.opacity(0.42))
                        .frame(width: 6 * unit, height: 6 * unit)
                        .offset(x: 10 * unit, y: 6.5 * unit)
                    Circle().fill(LaunchPalette.plateEnd.opacity(0.42))
                        .frame(width: 6 * unit, height: 6 * unit)
                        .offset(x: 22 * unit, y: 6.5 * unit)
                }
                .frame(width: 72 * unit, height: 72 * unit)
                .clipShape(RoundedRectangle(cornerRadius: 13 * unit, style: .continuous))
                .offset(x: 40 * unit, y: 40 * unit)
                .opacity(pieces >= 2 ? 1 : 0)
                .offset(x: pieces >= 2 ? 0 : -18 * unit, y: pieces >= 2 ? 0 : -18 * unit)

                // Les trois pas du lien, à travers l'écart.
                ForEach(0..<3, id: \.self) { index in
                    let step = Self.link[index]
                    Circle()
                        .fill(LaunchPalette.link.opacity(pulse ? min(1, step.opacity + 0.2) : step.opacity))
                        .frame(width: 5 * unit, height: 5 * unit)
                        .scaleEffect(pulse ? 1.25 : 1)
                        .offset(x: (step.center - 2.5) * unit, y: (step.center - 2.5) * unit)
                        .opacity(pieces >= 3 ? 1 : 0)
                        .animation(.easeOut(duration: 0.2).delay(Double(index) * 0.07), value: pieces)
                }

                // En bas à droite : le téléphone dans votre main, écran compris.
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 13 * unit, style: .continuous).fill(mark)
                    RoundedRectangle(cornerRadius: 7 * unit, style: .continuous)
                        .fill(LaunchPalette.plateEnd.opacity(0.32))
                        .frame(width: 34 * unit, height: 50 * unit)
                        .offset(x: 19 * unit, y: 11 * unit)
                    Capsule().fill(LaunchPalette.plateEnd.opacity(0.5))
                        .frame(width: 14 * unit, height: 2.8 * unit)
                        .offset(x: 29 * unit, y: 54 * unit)
                }
                .frame(width: 72 * unit, height: 72 * unit)
                .offset(x: 128 * unit, y: 128 * unit)
                .opacity(pieces >= 4 ? 1 : 0)
                .offset(x: pieces >= 4 ? 0 : 18 * unit, y: pieces >= 4 ? 0 : 18 * unit)
            }
            .frame(width: side, height: side, alignment: .topLeading)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}
#endif
