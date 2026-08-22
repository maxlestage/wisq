import Foundation

/// Strips ANSI escape sequences from console output.
///
/// A serial console emits colour codes, cursor moves and clears; a v1 terminal
/// view that renders plain text must drop them rather than print the raw
/// bytes. A real VT100 cell grid can replace this later — the filter keeps the
/// text readable until then.
public enum ANSIFilter {
    public static func strip(_ text: String) -> String {
        var output = String.UnicodeScalarView()
        var scalars = text.unicodeScalars[...]

        while let scalar = scalars.first {
            scalars = scalars.dropFirst()
            guard scalar.value == 0x1B else {
                // Keep printable text and the whitespace that structures it.
                if scalar.value >= 0x20 || scalar == "\n" || scalar == "\t" || scalar.value == 0x08 || scalar == "\r" {
                    output.append(scalar)
                }
                continue
            }
            guard let kind = scalars.first else { break }
            scalars = scalars.dropFirst()
            switch kind {
            case "[":
                // CSI: parameters 0x30–0x3F, intermediates 0x20–0x2F, final 0x40–0x7E.
                while let c = scalars.first, (0x20...0x3F).contains(c.value) {
                    scalars = scalars.dropFirst()
                }
                if scalars.first != nil { scalars = scalars.dropFirst() }
            case "]":
                // OSC: terminated by BEL or ESC \.
                while let c = scalars.first, c.value != 0x07, c.value != 0x1B {
                    scalars = scalars.dropFirst()
                }
                if scalars.first?.value == 0x07 {
                    scalars = scalars.dropFirst()
                } else if scalars.first?.value == 0x1B {
                    scalars = scalars.dropFirst()
                    if scalars.first == "\\" { scalars = scalars.dropFirst() }
                }
            default:
                break   // two-character sequence: ESC already consumed the kind
            }
        }
        return String(String.UnicodeScalarView(output))
    }

    /// Applies carriage returns and backspaces the way a terminal would, so a
    /// guest redrawing its line does not leave ghosts in a plain-text view.
    public static func applyLineEdits(_ text: String) -> String {
        var lines: [[Character]] = [[]]
        var column = 0
        for character in text {
            switch character {
            case "\n":
                lines.append([])
                column = 0
            case "\r":
                column = 0
            case "\u{8}":
                column = max(0, column - 1)
            default:
                var line = lines[lines.count - 1]
                if column < line.count {
                    line[column] = character
                } else {
                    line.append(character)
                }
                lines[lines.count - 1] = line
                column += 1
            }
        }
        return lines.map { String($0) }.joined(separator: "\n")
    }
}
