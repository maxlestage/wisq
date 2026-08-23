#if os(iOS)
import SwiftUI
import WisqCore

/// The row of keys a desktop needs and a phone keyboard does not have.
/// Modifiers are sticky: tap Ctrl, then a letter, and the pair is sent together.
struct KeyBarView: View {
    let model: SessionModel
    @State private var showFunctionKeys = false

    var body: some View {
        VStack(spacing: 6) {
            if showFunctionKeys {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(1...12, id: \.self) { index in
                            key("F\(index)") { model.press(Keysym.function(index)) }
                        }
                    }
                    .padding(.horizontal, 10)
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    modifier("esc", keysym: Keysym.escape, sticky: false)
                    modifier("tab", keysym: Keysym.tab, sticky: false)
                    modifier("ctrl", keysym: Keysym.controlL, sticky: true)
                    modifier("alt", keysym: Keysym.altL, sticky: true)
                    modifier("⇧", keysym: Keysym.shiftL, sticky: true)
                    modifier("⌘", keysym: Keysym.superL, sticky: true)

                    Divider().frame(height: 26)

                    key("↑") { model.press(Keysym.up) }
                    key("↓") { model.press(Keysym.down) }
                    key("←") { model.press(Keysym.left) }
                    key("→") { model.press(Keysym.right) }

                    Divider().frame(height: 26)

                    key("home") { model.press(Keysym.home) }
                    key("end") { model.press(Keysym.end) }
                    key("pg↑") { model.press(Keysym.pageUp) }
                    key("pg↓") { model.press(Keysym.pageDown) }
                    key("del") { model.press(Keysym.delete) }

                    Button {
                        showFunctionKeys.toggle()
                    } label: {
                        Text("Fn")
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .frame(minWidth: 40, minHeight: 34)
                    }
                    .buttonStyle(.bordered)
                    .tint(showFunctionKeys ? .indigo : .secondary)
                }
                .padding(.horizontal, 10)
            }
        }
        .padding(.vertical, 6)
        .background(.ultraThinMaterial)
    }

    private func key(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .frame(minWidth: 40, minHeight: 34)
        }
        .buttonStyle(.bordered)
    }

    private func modifier(_ label: String, keysym: UInt32, sticky: Bool) -> some View {
        Button {
            if sticky {
                model.toggleModifier(keysym)
            } else {
                model.press(keysym)
            }
        } label: {
            Text(label)
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .frame(minWidth: 44, minHeight: 34)
        }
        .buttonStyle(.bordered)
        .tint(sticky && model.isModifierHeld(keysym) ? .indigo : .secondary)
    }
}
#endif
