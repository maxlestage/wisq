import Foundation

/// A plain-text console a guest can write to as fast as it likes.
///
/// The obvious way to render a serial console is to keep every byte the guest
/// ever printed and, on each arrival, derive the visible text from scratch:
/// strip the escapes, then replay every carriage return and backspace from the
/// beginning. That is work proportional to the whole history per chunk, so a
/// chatty guest makes the console quadratic — the emulator stays fast while the
/// interface stops responding, which reads to the user as the VM being slow.
///
/// This applies each chunk once, to the tail. Two things follow from being
/// incremental rather than a re-derivation, and both are improvements:
///
/// - The escape parser keeps its state between chunks, so a sequence split
///   across two writes is still recognised. Stripping chunk by chunk cannot do
///   that; it prints the tail of the sequence as text.
/// - Completed lines are immutable, so the history has a bound in lines rather
///   than growing until something truncates it mid-character.
///
/// Column arithmetic is in Unicode scalars: a serial console addresses cells,
/// and the guests this runs are ASCII. A real VT100 grid can replace this.
public struct ConsoleBuffer: Sendable {
    /// Lines kept before the oldest are dropped. A phone screen shows tens;
    /// the rest is scrollback, and unbounded scrollback is a leak.
    public let maxLines: Int

    private var completed: [String] = []
    private var current: [Unicode.Scalar] = []
    private var column = 0
    private var state = State.text

    private enum State {
        case text
        /// ESC seen; the next scalar says what kind of sequence this is.
        case escape
        /// CSI: parameters and intermediates until a final byte 0x40–0x7E.
        case csi
        /// OSC: anything until BEL, or ESC \.
        case osc
        /// Inside OSC, an ESC was seen; a following backslash ends it.
        case oscEscape
    }

    public init(maxLines: Int = 2000) {
        self.maxLines = maxLines
    }

    /// Everything currently visible, oldest line first.
    public var text: String {
        var out = completed
        out.append(String(String.UnicodeScalarView(current)))
        return out.joined(separator: "\n")
    }

    public var lineCount: Int { completed.count + 1 }

    public mutating func append(_ data: Data) {
        append(String(decoding: data, as: UTF8.self))
    }

    public mutating func append(_ text: String) {
        for scalar in text.unicodeScalars {
            consume(scalar)
        }
    }

    public mutating func removeAll() {
        completed.removeAll()
        current.removeAll()
        column = 0
        state = .text
    }

    private mutating func consume(_ scalar: Unicode.Scalar) {
        switch state {
        case .escape:
            switch scalar {
            case "[": state = .csi
            case "]": state = .osc
            default: state = .text      // two-character sequence, both consumed
            }
            return

        case .csi:
            // Parameters 0x30–0x3F and intermediates 0x20–0x2F continue the
            // sequence; anything else is the final byte and ends it.
            if !(0x20...0x3F).contains(scalar.value) { state = .text }
            return

        case .osc:
            if scalar.value == 0x07 { state = .text }
            else if scalar.value == 0x1B { state = .oscEscape }
            return

        case .oscEscape:
            state = scalar == "\\" ? .text : .osc
            return

        case .text:
            break
        }

        switch scalar.value {
        case 0x1B:
            state = .escape
        case 0x0A:
            endLine()
        case 0x0D:
            column = 0
        case 0x08:
            column = max(0, column - 1)
        case 0x09:
            // Tabs are kept: the guest uses them to align, and a plain-text
            // view honours them.
            write("\t")
        default:
            // Drop the remaining control characters; they are cursor and mode
            // control this view has no cells to apply them to.
            if scalar.value >= 0x20 { write(scalar) }
        }
    }

    private mutating func write(_ scalar: Unicode.Scalar) {
        if column < current.count {
            current[column] = scalar
        } else {
            // A guest that moves right past the end leaves blanks, not a gap.
            while current.count < column { current.append(" ") }
            current.append(scalar)
        }
        column += 1
    }

    private mutating func endLine() {
        completed.append(String(String.UnicodeScalarView(current)))
        current.removeAll(keepingCapacity: true)
        column = 0
        if completed.count > maxLines {
            completed.removeFirst(completed.count - maxLines)
        }
    }
}
