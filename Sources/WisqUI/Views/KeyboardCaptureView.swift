#if os(iOS)
import SwiftUI
import UIKit
import WisqCore

/// Invisible first responder that carries both keyboards.
///
/// It stays first responder for the whole session so a hardware keyboard's presses
/// reach us; an empty `inputView` keeps the software keyboard off screen until it
/// is actually asked for. A real `UITextField` would fight us over autocorrect,
/// undo and text state, so this is a bare `UIKeyInput` instead: characters go
/// straight out as keysyms and nothing is buffered locally.
struct KeyboardCaptureView: UIViewRepresentable {
    /// Whether the on-screen keyboard should be visible.
    let showsSoftwareKeyboard: Bool
    let onText: (String) -> Void
    let onBackspace: () -> Void
    /// Hardware key edges, already translated to X11 keysyms.
    let onKey: (UInt32, Bool) -> Void
    /// Maps the Command key to Super rather than Control.
    let commandIsSuper: Bool

    func makeUIView(context: Context) -> KeyCaptureUIView {
        let view = KeyCaptureUIView()
        apply(to: view)
        view.becomeFirstResponder()
        return view
    }

    func updateUIView(_ view: KeyCaptureUIView, context: Context) {
        apply(to: view)
        if !view.isFirstResponder {
            view.becomeFirstResponder()
        }
    }

    private func apply(to view: KeyCaptureUIView) {
        view.onText = onText
        view.onBackspace = onBackspace
        view.onKey = onKey
        view.commandIsSuper = commandIsSuper
        view.showsSoftwareKeyboard = showsSoftwareKeyboard
    }
}

final class KeyCaptureUIView: UIView, UIKeyInput {
    var onText: ((String) -> Void)?
    var onBackspace: (() -> Void)?
    var onKey: ((UInt32, Bool) -> Void)?
    var commandIsSuper = true

    /// Swapping `inputView` between nil and an empty view is what lets us stay
    /// first responder — and keep receiving hardware keys — with no keyboard on
    /// screen.
    var showsSoftwareKeyboard = false {
        didSet {
            guard showsSoftwareKeyboard != oldValue, isFirstResponder else { return }
            reloadInputViews()
        }
    }

    private let emptyInputView = UIView(frame: .zero)

    override var inputView: UIView? {
        showsSoftwareKeyboard ? nil : emptyInputView
    }

    override var canBecomeFirstResponder: Bool { true }

    // MARK: - Software keyboard

    var hasText: Bool { true }

    func insertText(_ text: String) { onText?(text) }

    func deleteBackward() { onBackspace?() }

    // The guest owns the text, so none of iOS's editing assistance applies.
    var autocorrectionType: UITextAutocorrectionType {
        get { .no } set { _ = newValue }
    }

    var autocapitalizationType: UITextAutocapitalizationType {
        get { .none } set { _ = newValue }
    }

    var spellCheckingType: UITextSpellCheckingType {
        get { .no } set { _ = newValue }
    }

    var smartQuotesType: UITextSmartQuotesType {
        get { .no } set { _ = newValue }
    }

    var smartDashesType: UITextSmartDashesType {
        get { .no } set { _ = newValue }
    }

    var smartInsertDeleteType: UITextSmartInsertDeleteType {
        get { .no } set { _ = newValue }
    }

    var keyboardType: UIKeyboardType {
        get { .asciiCapable } set { _ = newValue }
    }

    // MARK: - Hardware keyboard

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !forward(presses, down: true) {
            super.pressesBegan(presses, with: event)
        }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !forward(presses, down: false) {
            super.pressesEnded(presses, with: event)
        }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        // Release whatever was held; a stuck modifier in the guest is unrecoverable
        // from the phone.
        _ = forward(presses, down: false)
        super.pressesCancelled(presses, with: event)
    }

    /// Returns true when every press was handled, so the responder chain stops here.
    private func forward(_ presses: Set<UIPress>, down: Bool) -> Bool {
        var handled = false
        for press in presses {
            guard let usage = press.key?.keyCode.rawValue,
                  var keysym = HIDKeyMap.keysym(forHIDUsage: usage) else { continue }
            if !commandIsSuper, usage == 0xE3 || usage == 0xE7 {
                keysym = Keysym.controlL
            }
            onKey?(keysym, down)
            handled = true
        }
        return handled
    }
}
#endif
