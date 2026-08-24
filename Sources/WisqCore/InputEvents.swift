import Foundation

/// Mouse buttons as a bitmask, matching the RFB pointer-event layout.
public struct MouseButtons: OptionSet, Hashable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let left       = MouseButtons(rawValue: 1 << 0)
    public static let middle     = MouseButtons(rawValue: 1 << 1)
    public static let right      = MouseButtons(rawValue: 1 << 2)
    public static let scrollUp   = MouseButtons(rawValue: 1 << 3)
    public static let scrollDown = MouseButtons(rawValue: 1 << 4)
    public static let scrollLeft = MouseButtons(rawValue: 1 << 5)
    public static let scrollRight = MouseButtons(rawValue: 1 << 6)
}

/// Input to deliver to the guest. Protocol backends translate these to their own wire format.
public enum InputEvent: Hashable, Sendable {
    /// Absolute pointer position in framebuffer coordinates, plus the buttons held down.
    case pointer(x: Int, y: Int, buttons: MouseButtons)
    /// X11 keysym.
    ///
    /// This said "as used by both RFB and SPICE", which is wrong: RFB takes
    /// keysyms, SPICE takes PC AT scancodes. A backend that forwarded one of
    /// these to a SPICE guest unchanged would type nothing recognisable —
    /// `SpiceScancode` is the conversion, and this comment used to say it was
    /// unnecessary.
    case key(keysym: UInt32, down: Bool)
    /// Text pasted from the device clipboard, latin-1 as the RFB spec requires.
    case clipboard(String)
}

/// The subset of X11 keysyms the on-screen key bar and hardware keyboard need.
public enum Keysym {
    public static let backspace: UInt32 = 0xFF08
    public static let tab: UInt32       = 0xFF09
    public static let enter: UInt32     = 0xFF0D
    public static let escape: UInt32    = 0xFF1B
    public static let insert: UInt32    = 0xFF63
    public static let delete: UInt32    = 0xFFFF
    public static let home: UInt32      = 0xFF50
    public static let end: UInt32       = 0xFF57
    public static let pageUp: UInt32    = 0xFF55
    public static let pageDown: UInt32  = 0xFF56
    public static let left: UInt32      = 0xFF51
    public static let up: UInt32        = 0xFF52
    public static let right: UInt32     = 0xFF53
    public static let down: UInt32      = 0xFF54
    public static let shiftL: UInt32    = 0xFFE1
    public static let controlL: UInt32  = 0xFFE3
    public static let altL: UInt32      = 0xFFE9
    public static let superL: UInt32    = 0xFFEB
    public static let capsLock: UInt32  = 0xFFE5

    /// F1…F12.
    public static func function(_ n: Int) -> UInt32 {
        precondition((1...12).contains(n), "F keys run from 1 to 12")
        return UInt32(0xFFBE + n - 1)
    }

    /// Keysym for a printable character. Latin-1 maps to itself; anything else
    /// uses the Unicode range defined by the X protocol.
    public static func character(_ scalar: Unicode.Scalar) -> UInt32 {
        if scalar.value < 0x100 { return scalar.value }
        return 0x0100_0000 + scalar.value
    }
}
