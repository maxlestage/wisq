import Foundation
import WisqCore

/// X11 keysyms to PC AT scancodes, set 1 — what SPICE's inputs channel takes.
///
/// RFB takes keysyms; SPICE takes scancodes. `InputEvent.key` carries a keysym
/// because that is what the app's keyboard layer produces, and its own comment
/// used to claim keysyms were "as used by both RFB and SPICE". They are not,
/// and a session that forwarded them unchanged would type nothing recognisable.
/// This table is the difference.
///
/// Letters map without regard to case: `a` and `A` are the same key, and the
/// guest applies Shift from the modifier sent alongside — the same rule
/// `HIDKeyMap` already follows for the layer above.
enum SpiceScancode {
    /// Keys that need the `0xE0` prefix, which SPICE carries in the high byte
    /// of the same word rather than as a separate message. Forgetting it turns
    /// the arrow keys into the numeric keypad, which is the kind of bug that
    /// looks like a broken keyboard rather than a protocol error.
    private static let extendedPrefix: UInt32 = 0xE0 << 8

    private static let letters: [Character: UInt32] = [
        "a": 0x1E, "b": 0x30, "c": 0x2E, "d": 0x20, "e": 0x12, "f": 0x21,
        "g": 0x22, "h": 0x23, "i": 0x17, "j": 0x24, "k": 0x25, "l": 0x26,
        "m": 0x32, "n": 0x31, "o": 0x18, "p": 0x19, "q": 0x10, "r": 0x13,
        "s": 0x1F, "t": 0x14, "u": 0x16, "v": 0x2F, "w": 0x11, "x": 0x2D,
        "y": 0x15, "z": 0x2C,
    ]

    /// The digit row, in the order the keyboard has them rather than numeric
    /// order: `1` is 0x02 and `0` sits at the end, not the beginning.
    private static let digits: [Character: UInt32] = [
        "1": 0x02, "2": 0x03, "3": 0x04, "4": 0x05, "5": 0x06,
        "6": 0x07, "7": 0x08, "8": 0x09, "9": 0x0A, "0": 0x0B,
    ]

    private static let punctuation: [Character: UInt32] = [
        "-": 0x0C, "=": 0x0D, "[": 0x1A, "]": 0x1B, ";": 0x27,
        "'": 0x28, "`": 0x29, "\\": 0x2B, ",": 0x33, ".": 0x34, "/": 0x35,
        " ": 0x39,
    ]

    private static let named: [UInt32: UInt32] = [
        Keysym.escape: 0x01, Keysym.backspace: 0x0E, Keysym.tab: 0x0F,
        Keysym.enter: 0x1C,
        Keysym.shiftL: 0x2A, Keysym.controlL: 0x1D, Keysym.altL: 0x38,
        0xFFBE: 0x3B, 0xFFBF: 0x3C, 0xFFC0: 0x3D, 0xFFC1: 0x3E,
        0xFFC2: 0x3F, 0xFFC3: 0x40, 0xFFC4: 0x41, 0xFFC5: 0x42,
        0xFFC6: 0x43, 0xFFC7: 0x44, 0xFFC8: 0x57, 0xFFC9: 0x58,
    ]

    private static let extended: [UInt32: UInt32] = [
        Keysym.insert: 0x52, Keysym.delete: 0x53, Keysym.home: 0x47,
        Keysym.end: 0x4F, Keysym.pageUp: 0x49, Keysym.pageDown: 0x51,
        Keysym.up: 0x48, Keysym.down: 0x50, Keysym.left: 0x4B,
        Keysym.right: 0x4D, Keysym.superL: 0x5B,
    ]

    /// The scancode SPICE expects, or nil for a key this table does not know.
    ///
    /// Nil rather than a fallback on purpose. A guessed scancode types the
    /// wrong character, which is worse than typing nothing: the user sees a
    /// keyboard that lies rather than one that is incomplete.
    static func scancode(forKeysym keysym: UInt32) -> UInt32? {
        if let code = extended[keysym] { return extendedPrefix | code }
        if let code = named[keysym] { return code }
        // Printable ASCII keysyms are their own character, which is what makes
        // the three tables above lookups rather than a switch.
        guard keysym >= 0x20, keysym <= 0x7E,
              let character = Unicode.Scalar(keysym).map(Character.init) else { return nil }
        let lowered = Character(character.lowercased())
        return letters[lowered] ?? digits[character] ?? punctuation[character]
            ?? shiftedPunctuation[character]
    }

    /// The unshifted key a shifted symbol lives on. `?` is Shift and `/`, and a
    /// guest holding Shift needs the `/` scancode, not a code of its own.
    private static let shiftedPunctuation: [Character: UInt32] = [
        "!": 0x02, "@": 0x03, "#": 0x04, "$": 0x05, "%": 0x06,
        "^": 0x07, "&": 0x08, "*": 0x09, "(": 0x0A, ")": 0x0B,
        "_": 0x0C, "+": 0x0D, "{": 0x1A, "}": 0x1B, ":": 0x27,
        "\"": 0x28, "~": 0x29, "|": 0x2B, "<": 0x33, ">": 0x34, "?": 0x35,
    ]
}
