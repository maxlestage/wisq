import Foundation

/// Maps USB HID usage codes (page 0x07) to X11 keysyms.
///
/// A hardware keyboard on iOS reports HID usages; RFB and SPICE both speak
/// keysyms. UTM needs the equivalent table for PS/2 scancodes because SPICE takes
/// scancodes — RFB takes keysyms, so this is the shorter path for the same job.
///
/// Letters map to their unshifted keysym: the guest applies Shift itself, from the
/// modifier keysyms sent alongside.
public enum HIDKeyMap {
    public static func keysym(forHIDUsage usage: Int) -> UInt32? {
        // a…z
        if (0x04...0x1D).contains(usage) {
            return UInt32(0x61 + usage - 0x04)
        }
        // 1…9 then 0, which sits at the end of the run rather than the start.
        if (0x1E...0x26).contains(usage) {
            return UInt32(0x31 + usage - 0x1E)
        }
        if usage == 0x27 { return 0x30 }
        // F1…F12
        if (0x3A...0x45).contains(usage) {
            return Keysym.function(usage - 0x3A + 1)
        }
        return table[usage]
    }

    private static let table: [Int: UInt32] = [
        0x28: Keysym.enter,
        0x29: Keysym.escape,
        0x2A: Keysym.backspace,
        0x2B: Keysym.tab,
        0x2C: 0x20,            // space
        0x2D: 0x2D,            // -
        0x2E: 0x3D,            // =
        0x2F: 0x5B,            // [
        0x30: 0x5D,            // ]
        0x31: 0x5C,            // \
        0x32: 0x5C,            // non-US #, same key on most layouts
        0x33: 0x3B,            // ;
        0x34: 0x27,            // '
        0x35: 0x60,            // `
        0x36: 0x2C,            // ,
        0x37: 0x2E,            // .
        0x38: 0x2F,            // /
        0x39: Keysym.capsLock,

        0x46: 0xFF61,          // Print Screen
        0x47: 0xFF14,          // Scroll Lock
        0x48: 0xFF13,          // Pause
        0x49: Keysym.insert,
        0x4A: Keysym.home,
        0x4B: Keysym.pageUp,
        0x4C: Keysym.delete,
        0x4D: Keysym.end,
        0x4E: Keysym.pageDown,
        0x4F: Keysym.right,
        0x50: Keysym.left,
        0x51: Keysym.down,
        0x52: Keysym.up,

        0x53: 0xFF7F,          // Num Lock
        0x54: 0xFFAF,          // keypad /
        0x55: 0xFFAA,          // keypad *
        0x56: 0xFFAD,          // keypad -
        0x57: 0xFFAB,          // keypad +
        0x58: 0xFF8D,          // keypad Enter
        0x59: 0xFFB1,          // keypad 1
        0x5A: 0xFFB2,
        0x5B: 0xFFB3,
        0x5C: 0xFFB4,
        0x5D: 0xFFB5,
        0x5E: 0xFFB6,
        0x5F: 0xFFB7,
        0x60: 0xFFB8,
        0x61: 0xFFB9,
        0x62: 0xFFB0,          // keypad 0
        0x63: 0xFFAE,          // keypad .
        0x64: 0x5C,            // non-US backslash
        0x65: 0xFF67,          // Menu

        0xE0: Keysym.controlL,
        0xE1: Keysym.shiftL,
        0xE2: Keysym.altL,
        0xE3: Keysym.superL,   // Command
        0xE4: 0xFFE4,          // right Control
        0xE5: 0xFFE2,          // right Shift
        0xE6: 0xFFEA,          // right Alt / AltGr
        0xE7: 0xFFEC,          // right Super
    ]

    /// True for the modifier usages, which must be tracked as held rather than
    /// sent as a press-and-release pair.
    public static func isModifier(hidUsage usage: Int) -> Bool {
        (0xE0...0xE7).contains(usage)
    }
}
