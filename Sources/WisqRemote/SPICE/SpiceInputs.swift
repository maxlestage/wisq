import Foundation
import WisqCore

/// The inputs channel: what the client sends so a guest sees a keyboard and a
/// pointer.
///
/// Encoding only, like `SpiceWire` — no stream, so the mapping from what the
/// app produces to what the wire carries is checked without a server. That
/// mapping is where the work is: `InputEvent` speaks keysyms and absolute
/// framebuffer coordinates, and SPICE wants scancodes and its own button
/// numbering.
enum SpiceInputs {
    enum ClientMessage {
        static let keyDown: UInt16 = 101
        static let keyUp: UInt16 = 102
        static let keyModifiers: UInt16 = 103
        static let mouseMotion: UInt16 = 111
        static let mousePosition: UInt16 = 112
        static let mousePress: UInt16 = 113
        static let mouseRelease: UInt16 = 114
    }

    enum ServerMessage {
        static let initialise: UInt16 = 101
        static let keyModifiers: UInt16 = 102
        static let mouseMotionAck: UInt16 = 111
    }

    /// SPICE numbers its buttons from one, and its wheel is two more buttons
    /// rather than an axis — which is why this is a mapping and not a cast.
    enum Button: Int32 {
        case left = 1
        case middle = 2
        case right = 3
        case up = 4
        case down = 5
    }

    /// The buttons-held mask, which every pointer message carries alongside
    /// whatever it is reporting.
    ///
    /// Only the three real buttons appear: the wheel is pressed and released,
    /// never held, so a wheel bit in this mask would tell the guest a button is
    /// down that the user is not holding.
    static func buttonMask(_ buttons: MouseButtons) -> Int32 {
        var mask: Int32 = 0
        if buttons.contains(.left) { mask |= 1 << 0 }
        if buttons.contains(.middle) { mask |= 1 << 1 }
        if buttons.contains(.right) { mask |= 1 << 2 }
        return mask
    }

    /// Absolute pointer position, which is the mode a touch screen needs: there
    /// is no relative motion to report when a finger simply lands somewhere.
    static func mousePosition(
        x: Int, y: Int, buttons: MouseButtons, display: UInt8 = 0
    ) -> Data {
        // Negative coordinates cannot be expressed — the field is unsigned —
        // and a wrapped one would put the pointer at four billion. Clamped
        // rather than sent, because a pointer in the corner is a small lie and
        // a pointer off the far edge is a broken session.
        var payload = SpiceWire.u32(UInt32(max(0, x)))
        payload += SpiceWire.u32(UInt32(max(0, y)))
        payload += SpiceWire.u32(UInt32(bitPattern: buttonMask(buttons)))
        payload += [display]
        return Data(payload)
    }

    static func mousePress(_ button: Button, buttons: MouseButtons) -> Data {
        Data(
            SpiceWire.u32(UInt32(bitPattern: button.rawValue))
                + SpiceWire.u32(UInt32(bitPattern: buttonMask(buttons)))
        )
    }

    static func mouseRelease(_ button: Button, buttons: MouseButtons) -> Data {
        mousePress(button, buttons: buttons)
    }

    static func key(scancode: UInt32) -> Data {
        Data(SpiceWire.u32(scancode))
    }

    /// What one `InputEvent` becomes on the wire: a type and a payload each.
    ///
    /// Returns a list because one event is not always one message. A wheel
    /// notch is a press and a release, since SPICE has no way to say "scrolled"
    /// on its own — and sending only the press leaves the guest believing a
    /// button is still down.
    static func messages(for event: InputEvent) -> [(type: UInt16, payload: Data)] {
        switch event {
        case let .pointer(x, y, buttons):
            var messages: [(UInt16, Data)] = [
                (ClientMessage.mousePosition, mousePosition(x: x, y: y, buttons: buttons)),
            ]
            for (flag, button) in [
                (MouseButtons.scrollUp, Button.up), (.scrollDown, .down),
            ] where buttons.contains(flag) {
                let held = buttons.subtracting([.scrollUp, .scrollDown])
                messages.append((ClientMessage.mousePress, mousePress(button, buttons: held)))
                messages.append(
                    (ClientMessage.mouseRelease, mouseRelease(button, buttons: held))
                )
            }
            return messages

        case let .key(keysym, down):
            // A key this table does not know sends nothing. A guessed scancode
            // would type the wrong character, which is worse than typing none.
            guard let scancode = SpiceScancode.scancode(forKeysym: keysym) else { return [] }
            return [(down ? ClientMessage.keyDown : ClientMessage.keyUp, key(scancode: scancode))]

        case .clipboard:
            // The clipboard rides the main channel's agent, not this one. It is
            // not silently dropped here so much as not this channel's business.
            return []
        }
    }
}
