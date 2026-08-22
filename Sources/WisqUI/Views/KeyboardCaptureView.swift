#if os(iOS)
import SwiftUI
import UIKit
import WisqCore

/// Invisible first responder that brings up the system keyboard and forwards what
/// the user types to the guest.
///
/// A real `UITextField` would fight us over autocorrect, undo and text state, so
/// this is a bare `UIKeyInput` instead: characters go straight out as keysyms and
/// nothing is buffered locally.
struct KeyboardCaptureView: UIViewRepresentable {
    let isActive: Bool
    let onText: (String) -> Void
    let onBackspace: () -> Void

    func makeUIView(context: Context) -> KeyCaptureUIView {
        let view = KeyCaptureUIView()
        view.onText = onText
        view.onBackspace = onBackspace
        return view
    }

    func updateUIView(_ view: KeyCaptureUIView, context: Context) {
        view.onText = onText
        view.onBackspace = onBackspace
        if isActive, !view.isFirstResponder {
            view.becomeFirstResponder()
        } else if !isActive, view.isFirstResponder {
            view.resignFirstResponder()
        }
    }
}

final class KeyCaptureUIView: UIView, UIKeyInput {
    var onText: ((String) -> Void)?
    var onBackspace: (() -> Void)?

    override var canBecomeFirstResponder: Bool { true }

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
}
#endif
