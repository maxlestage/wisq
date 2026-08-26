import Foundation

/// A VT100-family cell grid: the console as full-screen programs assume it.
///
/// The previous console stripped escape sequences and replayed carriage
/// returns — readable for a boot log, and not a terminal. An editor, a pager
/// or `top` does not print lines: it addresses cells, clears regions, scrolls
/// a window and repaints in place, and a view with no cells to apply that to
/// shows the repaints as a growing smear of text. This grid gives those
/// sequences their cells.
///
/// What it implements is the dialect Linux console programs actually emit —
/// cursor addressing, erases, insert/delete of lines and characters, the
/// scroll region, the alternate screen, save/restore cursor, and SGR
/// attributes (recorded per cell, so a renderer can show them; the plain-text
/// projection ignores them). What it deliberately does not do: respond to
/// queries (DSR would need a back-channel to the guest), and reflow on
/// resize (real terminals do not either).
///
/// Two behaviours are worth naming because getting them wrong is invisible
/// until a real program runs:
///
/// - **Deferred wrap.** Writing the 80th column does not move to the next
///   line; the wrap happens only when another printable character follows.
///   Without this, a program that writes exactly 80 characters and then CR LF
///   ends up one line further than it painted, and every full-width repaint
///   walks the screen down.
/// - **Scrollback is what leaves the top.** Lines pushed off the main screen
///   by scrolling become history; the alternate screen — where editors live —
///   never feeds it, which is why quitting vim gives the shell back instead
///   of dumping the last frame into the log.
///
/// The parser is incremental: a sequence split across two chunks is still one
/// sequence, because the state lives in the struct rather than in a pass over
/// the whole history.
public struct TerminalGrid: Sendable {
    public struct Attributes: Equatable, Sendable {
        public var bold = false
        public var underline = false
        public var inverse = false
        /// 0–7 standard, 8–15 bright; nil is the default colour.
        public var foreground: UInt8?
        public var background: UInt8?

        public init() {}
        public var isDefault: Bool { self == Attributes() }
    }

    public struct Cell: Equatable, Sendable {
        public var scalar: Unicode.Scalar
        public var attributes: Attributes

        static let blank = Cell(scalar: " ", attributes: Attributes())
    }

    public let columns: Int
    public let rows: Int
    /// Lines kept once they scroll off the top; beyond this the oldest drop.
    public let scrollbackLines: Int

    private var screen: [[Cell]]
    private var savedMainScreen: [[Cell]]?
    private var scrollback: [String] = []

    private var cursorRow = 0
    private var cursorColumn = 0
    /// One saved cursor **per screen**, which is what real terminals keep.
    ///
    /// There used to be a single slot, and two independent features wrote to
    /// it: `ESC 7`/`ESC 8` (DECSC/DECRC), and the cursor that `?1049` saves on
    /// its way into the alternate screen. A shell that saved its cursor, ran
    /// something full-screen, and restored afterwards got back the position the
    /// editor was at when it started — so the prompt repainted in the wrong
    /// place after quitting vim. The mirror leaked the other way too: a save
    /// made inside the alternate screen survived onto the main one.
    ///
    /// The accessor below reads and writes the slot of whichever screen is
    /// current, which is exactly the rule, and it lets every existing call site
    /// keep saying `savedCursor`. `setAlternateScreen` relies on its own
    /// ordering for `?1049`: it saves before switching in and restores after
    /// switching back, so both touch the main screen's slot — where a shell
    /// left it.
    private var savedCursorMain: (row: Int, column: Int, attributes: Attributes)?
    private var savedCursorAlternate: (row: Int, column: Int, attributes: Attributes)?

    private var savedCursor: (row: Int, column: Int, attributes: Attributes)? {
        get { isAlternateScreen ? savedCursorAlternate : savedCursorMain }
        set {
            if isAlternateScreen {
                savedCursorAlternate = newValue
            } else {
                savedCursorMain = newValue
            }
        }
    }
    private var attributes = Attributes()
    private var wrapPending = false
    private var scrollTop = 0
    private var scrollBottom: Int
    public private(set) var isCursorVisible = true
    public private(set) var isAlternateScreen = false

    private enum State {
        case text
        case escape
        /// ESC ( or ESC ) — charset designation; the next byte completes it.
        case charset
        case csi
        case osc
        case oscEscape
    }

    private var state = State.text
    /// Collected CSI parameter and intermediate bytes. Bounded: a hostile
    /// guest must not grow parser state without limit.
    private var csiBuffer: [Unicode.Scalar] = []
    private static let csiBufferLimit = 64

    public init(columns: Int = 80, rows: Int = 24, scrollbackLines: Int = 2000) {
        self.columns = max(1, columns)
        self.rows = max(1, rows)
        self.scrollbackLines = max(0, scrollbackLines)
        self.screen = Array(
            repeating: Array(repeating: Cell.blank, count: self.columns),
            count: self.rows
        )
        self.scrollBottom = self.rows - 1
    }

    // MARK: - What the view reads

    public var cursor: (row: Int, column: Int) { (cursorRow, cursorColumn) }

    /// Scrollback plus the visible screen, as plain text. Trailing blanks are
    /// trimmed — per line, and for the screen's unused bottom — so a fresh
    /// grid is empty rather than 24 blank lines, and a boot log reads exactly
    /// as it always did.
    public var text: String {
        var lines = scrollback
        lines.append(contentsOf: visibleScreenLines())
        return lines.joined(separator: "\n")
    }

    /// The visible grid only — what a screen-shaped renderer draws.
    public var screenText: String {
        visibleScreenLines(trimTrailingEmptyLines: false).joined(separator: "\n")
    }

    public func cell(atRow row: Int, column: Int) -> Cell? {
        guard (0..<rows).contains(row), (0..<columns).contains(column) else { return nil }
        return screen[row][column]
    }

    private func visibleScreenLines(trimTrailingEmptyLines: Bool = true) -> [String] {
        var lines = screen.map { row -> String in
            var scalars = String.UnicodeScalarView()
            for cell in row { scalars.append(cell.scalar) }
            let line = String(scalars)
            // Blank cells are storage, not content.
            return String(line.reversed().drop { $0 == " " }.reversed())
        }
        if trimTrailingEmptyLines {
            // Keep everything up to the cursor: an empty line the cursor sits
            // on is where the next prompt goes, and dropping it makes the
            // console appear to swallow input.
            while lines.count > cursorRow + 1, lines.last?.isEmpty == true {
                lines.removeLast()
            }
        }
        return lines
    }

    // MARK: - Input

    public mutating func append(_ data: Data) {
        append(String(decoding: data, as: UTF8.self))
    }

    public mutating func append(_ text: String) {
        for scalar in text.unicodeScalars {
            consume(scalar)
        }
    }

    public mutating func removeAll() {
        screen = Array(repeating: Array(repeating: Cell.blank, count: columns), count: rows)
        savedMainScreen = nil
        scrollback.removeAll()
        cursorRow = 0
        cursorColumn = 0
        savedCursorMain = nil
        savedCursorAlternate = nil
        attributes = Attributes()
        wrapPending = false
        scrollTop = 0
        scrollBottom = rows - 1
        isCursorVisible = true
        isAlternateScreen = false
        state = .text
        csiBuffer.removeAll()
    }

    // MARK: - Parser

    private mutating func consume(_ scalar: Unicode.Scalar) {
        switch state {
        case .escape:
            handleEscape(scalar)
        case .charset:
            state = .text          // designation byte consumed, nothing to do
        case .csi:
            if (0x20...0x3F).contains(scalar.value) {
                if csiBuffer.count < Self.csiBufferLimit { csiBuffer.append(scalar) }
            } else {
                state = .text
                handleCSI(final: scalar)
                csiBuffer.removeAll(keepingCapacity: true)
            }
        case .osc:
            switch scalar.value {
            case 0x07: state = .text
            case 0x1B: state = .oscEscape
            default: break
            }
        case .oscEscape:
            state = scalar == "\\" ? .text : .osc
        case .text:
            handleText(scalar)
        }
    }

    private mutating func handleText(_ scalar: Unicode.Scalar) {
        switch scalar.value {
        case 0x1B:
            state = .escape
        case 0x0A, 0x0B, 0x0C:
            // LF returns the column too. On real hardware that translation is
            // the kernel tty's job (ONLCR turns \n into \r\n before the
            // UART); this grid sits where a bare \n still reaches it, and a
            // console that staircases its boot log serves nobody. ESC D keeps
            // the column, which is the whole point of having both.
            cursorColumn = 0
            lineFeed()
        case 0x0D:
            cursorColumn = 0
            wrapPending = false
        case 0x08:
            if cursorColumn > 0 { cursorColumn -= 1 }
            wrapPending = false
        case 0x09:
            // To the next multiple-of-8 stop, never past the last column.
            wrapPending = false
            cursorColumn = min(columns - 1, (cursorColumn / 8 + 1) * 8)
        case 0x07:
            break  // BEL: a phone console has no bell worth ringing
        case 0x00..<0x20, 0x7F:
            break
        default:
            put(scalar)
        }
    }

    private mutating func put(_ scalar: Unicode.Scalar) {
        if wrapPending {
            wrapPending = false
            cursorColumn = 0
            lineFeed()
        }
        screen[cursorRow][cursorColumn] = Cell(scalar: scalar, attributes: attributes)
        if cursorColumn == columns - 1 {
            wrapPending = true
        } else {
            cursorColumn += 1
        }
    }

    private mutating func lineFeed() {
        wrapPending = false
        if cursorRow == scrollBottom {
            scrollUp(1)
        } else if cursorRow < rows - 1 {
            cursorRow += 1
        }
    }

    private mutating func handleEscape(_ scalar: Unicode.Scalar) {
        state = .text
        switch scalar {
        case "[":
            state = .csi
            csiBuffer.removeAll(keepingCapacity: true)
        case "]":
            state = .osc
        case "(", ")":
            state = .charset
        case "7":
            savedCursor = (cursorRow, cursorColumn, attributes)
        case "8":
            if let saved = savedCursor {
                cursorRow = min(saved.row, rows - 1)
                cursorColumn = min(saved.column, columns - 1)
                attributes = saved.attributes
                wrapPending = false
            }
        case "D":
            lineFeed()
        case "E":
            cursorColumn = 0
            lineFeed()
        case "M":
            // Reverse index: up, scrolling the region down at its top.
            wrapPending = false
            if cursorRow == scrollTop {
                scrollDown(1)
            } else if cursorRow > 0 {
                cursorRow -= 1
            }
        case "c":
            let scrollbackKept = scrollback
            removeAll()
            scrollback = scrollbackKept
        default:
            break  // two-character sequence this grid has no behaviour for
        }
    }

    // MARK: - CSI

    private mutating func handleCSI(final: Unicode.Scalar) {
        let raw = String(String.UnicodeScalarView(csiBuffer))
        let isPrivate = raw.hasPrefix("?")
        let parameters = (isPrivate ? String(raw.dropFirst()) : raw)
            .split(separator: ";", omittingEmptySubsequences: false)
            .map { Int($0) ?? 0 }

        func parameter(_ index: Int, default defaultValue: Int) -> Int {
            guard index < parameters.count, parameters[index] != 0 else { return defaultValue }
            return parameters[index]
        }

        if isPrivate {
            handlePrivateMode(final: final, parameters: parameters)
            return
        }

        switch final {
        case "A":
            moveCursor(row: cursorRow - parameter(0, default: 1), column: cursorColumn)
        case "B", "e":
            moveCursor(row: cursorRow + parameter(0, default: 1), column: cursorColumn)
        case "C", "a":
            moveCursor(row: cursorRow, column: cursorColumn + parameter(0, default: 1))
        case "D":
            moveCursor(row: cursorRow, column: cursorColumn - parameter(0, default: 1))
        case "E":
            moveCursor(row: cursorRow + parameter(0, default: 1), column: 0)
        case "F":
            moveCursor(row: cursorRow - parameter(0, default: 1), column: 0)
        case "G", "`":
            moveCursor(row: cursorRow, column: parameter(0, default: 1) - 1)
        case "d":
            moveCursor(row: parameter(0, default: 1) - 1, column: cursorColumn)
        case "H", "f":
            moveCursor(row: parameter(0, default: 1) - 1, column: parameter(1, default: 1) - 1)
        case "J":
            eraseInDisplay(mode: parameters.first ?? 0)
        case "K":
            eraseInLine(mode: parameters.first ?? 0)
        case "L":
            insertLines(parameter(0, default: 1))
        case "M":
            deleteLines(parameter(0, default: 1))
        case "@":
            insertCharacters(parameter(0, default: 1))
        case "P":
            deleteCharacters(parameter(0, default: 1))
        case "X":
            eraseCharacters(parameter(0, default: 1))
        case "S":
            scrollUp(parameter(0, default: 1))
        case "T":
            scrollDown(parameter(0, default: 1))
        case "m":
            applyGraphics(parameters.isEmpty ? [0] : parameters)
        case "r":
            setScrollRegion(
                top: parameter(0, default: 1) - 1,
                bottom: parameter(1, default: rows) - 1
            )
        default:
            break  // queries and modes this grid has no behaviour for
        }
    }

    private mutating func handlePrivateMode(final: Unicode.Scalar, parameters: [Int]) {
        let enable: Bool
        switch final {
        case "h": enable = true
        case "l": enable = false
        default: return
        }
        for mode in parameters {
            switch mode {
            case 25:
                isCursorVisible = enable
            case 47, 1047, 1049:
                setAlternateScreen(enable, saveCursor: mode == 1049)
            default:
                break
            }
        }
    }

    // MARK: - Operations

    private mutating func moveCursor(row: Int, column: Int) {
        cursorRow = min(max(0, row), rows - 1)
        cursorColumn = min(max(0, column), columns - 1)
        wrapPending = false
    }

    private mutating func eraseInDisplay(mode: Int) {
        wrapPending = false
        switch mode {
        case 0:
            eraseInLine(mode: 0)
            for row in (cursorRow + 1)..<rows { clearRow(row) }
        case 1:
            eraseInLine(mode: 1)
            for row in 0..<cursorRow { clearRow(row) }
        case 2, 3:
            for row in 0..<rows { clearRow(row) }
            if mode == 3 { scrollback.removeAll() }
        default:
            break
        }
    }

    private mutating func eraseInLine(mode: Int) {
        wrapPending = false
        switch mode {
        case 0:
            for column in cursorColumn..<columns { screen[cursorRow][column] = .blank }
        case 1:
            for column in 0...cursorColumn { screen[cursorRow][column] = .blank }
        case 2:
            clearRow(cursorRow)
        default:
            break
        }
    }

    private mutating func clearRow(_ row: Int) {
        screen[row] = Array(repeating: .blank, count: columns)
    }

    /// Region scroll up: the top line leaves — into scrollback when it is the
    /// real top of the main screen — and a blank line enters at the bottom.
    private mutating func scrollUp(_ count: Int) {
        for _ in 0..<min(count, scrollBottom - scrollTop + 1) {
            if !isAlternateScreen, scrollTop == 0, scrollbackLines > 0 {
                var scalars = String.UnicodeScalarView()
                for cell in screen[0] { scalars.append(cell.scalar) }
                let line = String(scalars)
                scrollback.append(String(line.reversed().drop { $0 == " " }.reversed()))
                if scrollback.count > scrollbackLines {
                    scrollback.removeFirst(scrollback.count - scrollbackLines)
                }
            }
            screen.remove(at: scrollTop)
            screen.insert(Array(repeating: .blank, count: columns), at: scrollBottom)
        }
    }

    private mutating func scrollDown(_ count: Int) {
        for _ in 0..<min(count, scrollBottom - scrollTop + 1) {
            screen.remove(at: scrollBottom)
            screen.insert(Array(repeating: .blank, count: columns), at: scrollTop)
        }
    }

    private mutating func insertLines(_ count: Int) {
        guard (scrollTop...scrollBottom).contains(cursorRow) else { return }
        wrapPending = false
        for _ in 0..<min(count, scrollBottom - cursorRow + 1) {
            screen.remove(at: scrollBottom)
            screen.insert(Array(repeating: .blank, count: columns), at: cursorRow)
        }
    }

    private mutating func deleteLines(_ count: Int) {
        guard (scrollTop...scrollBottom).contains(cursorRow) else { return }
        wrapPending = false
        for _ in 0..<min(count, scrollBottom - cursorRow + 1) {
            screen.remove(at: cursorRow)
            screen.insert(Array(repeating: .blank, count: columns), at: scrollBottom)
        }
    }

    private mutating func insertCharacters(_ count: Int) {
        wrapPending = false
        for _ in 0..<min(count, columns - cursorColumn) {
            screen[cursorRow].removeLast()
            screen[cursorRow].insert(.blank, at: cursorColumn)
        }
    }

    private mutating func deleteCharacters(_ count: Int) {
        wrapPending = false
        for _ in 0..<min(count, columns - cursorColumn) {
            screen[cursorRow].remove(at: cursorColumn)
            screen[cursorRow].append(.blank)
        }
    }

    private mutating func eraseCharacters(_ count: Int) {
        wrapPending = false
        for column in cursorColumn..<min(cursorColumn + count, columns) {
            screen[cursorRow][column] = .blank
        }
    }

    private mutating func setScrollRegion(top: Int, bottom: Int) {
        let top = min(max(0, top), rows - 1)
        let bottom = min(max(0, bottom), rows - 1)
        guard top < bottom else { return }
        scrollTop = top
        scrollBottom = bottom
        moveCursor(row: 0, column: 0)
    }

    private mutating func setAlternateScreen(_ enable: Bool, saveCursor: Bool) {
        guard enable != isAlternateScreen else { return }
        wrapPending = false
        if enable {
            if saveCursor { savedCursor = (cursorRow, cursorColumn, attributes) }
            savedMainScreen = screen
            screen = Array(repeating: Array(repeating: Cell.blank, count: columns), count: rows)
            isAlternateScreen = true
            // A fresh alternate screen starts with nothing saved on it; a slot
            // left from a previous visit is not this program's.
            savedCursorAlternate = nil
            moveCursor(row: 0, column: 0)
        } else {
            screen = savedMainScreen ?? screen
            savedMainScreen = nil
            isAlternateScreen = false
            if saveCursor, let saved = savedCursor {
                cursorRow = min(saved.row, rows - 1)
                cursorColumn = min(saved.column, columns - 1)
                attributes = saved.attributes
            }
        }
        // Full-screen programs set their own region; leaving one behind on
        // exit would make the shell scroll inside the editor's window.
        scrollTop = 0
        scrollBottom = rows - 1
    }

    private mutating func applyGraphics(_ parameters: [Int]) {
        var index = 0
        while index < parameters.count {
            let code = parameters[index]
            switch code {
            case 0: attributes = Attributes()
            case 1: attributes.bold = true
            case 4: attributes.underline = true
            case 7: attributes.inverse = true
            case 22: attributes.bold = false
            case 24: attributes.underline = false
            case 27: attributes.inverse = false
            case 30...37: attributes.foreground = UInt8(code - 30)
            case 39: attributes.foreground = nil
            case 40...47: attributes.background = UInt8(code - 40)
            case 49: attributes.background = nil
            case 90...97: attributes.foreground = UInt8(code - 90 + 8)
            case 100...107: attributes.background = UInt8(code - 100 + 8)
            case 38, 48:
                // Extended colour: 5;n (256) or 2;r;g;b. Parsed so the
                // parameters are consumed, mapped down to the nearest of the
                // sixteen this grid stores.
                let isForeground = code == 38
                if index + 1 < parameters.count, parameters[index + 1] == 5,
                   index + 2 < parameters.count {
                    let value = UInt8(clamping: parameters[index + 2])
                    let mapped = value < 16 ? value : UInt8(value % 8)
                    if isForeground { attributes.foreground = mapped } else { attributes.background = mapped }
                    index += 2
                } else if index + 1 < parameters.count, parameters[index + 1] == 2 {
                    index += 4  // r, g, b consumed; colour dropped
                }
            default:
                break
            }
            index += 1
        }
    }
}
