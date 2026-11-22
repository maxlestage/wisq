#if os(iOS)
import SwiftUI
import WisqVM

/// **Le petit système de design de wisq** : l'accent, les rayons, les
/// espacements et les pièces qui reviennent d'un écran à l'autre — le badge
/// d'une machine, la pastille de son état, les puces de ses réglages, les
/// touches de la barre. Définis une fois ici, pour que deux écrans ne
/// dessinent pas la même chose de deux façons.
///
/// Les couleurs sont celles du système (`secondarySystemGroupedBackground`,
/// `tertiarySystemFill`…), qui suivent le mode sombre et le contraste
/// augmenté sans qu'on ait à les redire ; seules les teintes des badges sont à
/// wisq, et elles viennent de `MachineBadge`, que la CI Linux juge.
enum Design {
    /// L'accent de l'application : celui de la barre, des boutons principaux,
    /// des modificateurs tenus.
    static let accent = Color.indigo

    enum Radius {
        /// Une puce, une touche.
        static let small: CGFloat = 10
        /// Un badge de 48 points.
        static let badge: CGFloat = 13
        /// Une carte.
        static let card: CGFloat = 20
    }

    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
    }

    /// Le fond d'une carte posée sur une liste groupée.
    static let cardFill = Color(uiColor: .secondarySystemGroupedBackground)
    /// Le fond d'une puce, d'une touche, d'un champ.
    static let chipFill = Color(uiColor: .tertiarySystemFill)

    /// La teinte d'une distribution.
    static func tint(_ distribution: MachineBadge.Distribution) -> Color {
        let (red, green, blue) = distribution.tint
        return Color(red: red, green: green, blue: blue)
    }

    /// La couleur de la pastille d'un état.
    static func color(_ state: MachineState) -> Color {
        switch state {
        case .sessionSaved: return .green
        case .stopped: return .secondary
        case .neverStarted: return accent
        }
    }
}

/// **Le badge d'une machine** : un carré arrondi à la teinte de sa
/// distribution, son symbole en blanc, et un petit écran en coin quand c'est
/// un bureau. Décoratif pour VoiceOver : la ligne qui le porte dit déjà la
/// distribution en toutes lettres.
struct DistributionBadge: View {
    let distribution: MachineBadge.Distribution
    var desktop = false
    var size: CGFloat = 48

    var body: some View {
        let tint = Design.tint(distribution)
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(LinearGradient(colors: [tint.opacity(0.82), tint], startPoint: .topLeading,
                                 endPoint: .bottomTrailing))
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: distribution.symbol)
                    .font(.system(size: size * 0.44, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .overlay(alignment: .bottomTrailing) {
                if desktop {
                    Image(systemName: "display")
                        .font(.system(size: size * 0.2, weight: .bold))
                        .foregroundStyle(tint)
                        .padding(size * 0.07)
                        .background(Circle().fill(.white))
                        .offset(x: size * 0.1, y: size * 0.1)
                }
            }
            .accessibilityHidden(true)
    }
}

/// **La pastille d'un état** : « Session sauvée », « Éteinte »…
struct StatePill: View {
    let state: MachineState

    var body: some View {
        let color = Design.color(state)
        Label(state.word, systemImage: state.symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, Design.Space.s)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.14)))
    }
}

/// **Une puce** : une petite étiquette ou le visage d'un menu de réglage.
struct ChipLabel: View {
    let text: String
    let symbol: String
    var color: Color = .primary

    var body: some View {
        Label {
            Text(text).lineLimit(1).truncationMode(.middle)
        } icon: {
            Image(systemName: symbol)
        }
        .font(.footnote.weight(.medium))
        .foregroundStyle(color)
        .padding(.horizontal, Design.Space.m)
        .padding(.vertical, 7)
        .background(Capsule().fill(Design.chipFill))
        .contentShape(Capsule())
    }
}

extension View {
    /// Une carte : le fond groupé du système, un rayon continu.
    func card(padding: CGFloat = Design.Space.l) -> some View {
        self.padding(padding)
            .background(RoundedRectangle(cornerRadius: Design.Radius.card, style: .continuous)
                .fill(Design.cardFill))
    }

    /// Une rangée de liste qui porte une carte : pas de fond ni de séparateur
    /// à elle, la carte est le fond.
    func cardRow() -> some View {
        self.listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: Design.Space.s / 2 + 2, leading: Design.Space.l,
                                      bottom: Design.Space.s / 2 + 2, trailing: Design.Space.l))
    }
}

/// **Une touche de la barre** : une capsule nette, sans bordure, qui
/// s'enfonce sous le doigt ; teintée de l'accent quand elle est tenue (un
/// modificateur collant).
struct KeyCapStyle: ButtonStyle {
    var held = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .medium, design: .rounded))
            .foregroundStyle(held ? Color.white : Color.primary)
            .frame(minWidth: 42, minHeight: 36)
            .padding(.horizontal, 6)
            .background(
                RoundedRectangle(cornerRadius: Design.Radius.small, style: .continuous)
                    .fill(held ? Design.accent : Design.chipFill)
                    .shadow(color: .black.opacity(configuration.isPressed ? 0 : 0.12), radius: 0, y: 1))
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .animation(.snappy(duration: 0.12), value: configuration.isPressed)
    }
}

/// **Des vues côte à côte, qui passent à la ligne** quand la largeur
/// manque : les puces d'une carte, en grand texte comme en petit.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                                      proposal: ProposedViewSize(width: min(size.width, bounds.width),
                                                                 height: size.height))
                x += min(size.width, bounds.width) + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    /// Les rangées : une vue va à la ligne quand elle ne tient plus sur la
    /// rangée en cours ; une vue plus large que tout est bornée à la largeur.
    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(ProposedViewSize(width: width, height: nil))
            let itemWidth = min(size.width, width)
            if !row.indices.isEmpty, row.width + spacing + itemWidth > width {
                rows.append(row)
                row = Row()
            }
            row.width += (row.indices.isEmpty ? 0 : spacing) + itemWidth
            row.height = max(row.height, size.height)
            row.indices.append(index)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}
#endif
