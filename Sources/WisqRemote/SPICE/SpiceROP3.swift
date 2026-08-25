import Foundation

/// The ternary raster operation: one of 256 boolean functions of three
/// operands — a pattern, a source and a destination.
///
/// `DRAW_ROP3` is the general case that `DRAW_FILL`, `DRAW_COPY` and the three
/// operand-free rasters are all special cases of. Windows' GDI calls the same
/// byte a "ternary raster operation" and gives the common values names —
/// `SRCCOPY` is `0xCC`, `PATCOPY` is `0xF0`, `SRCINVERT` is `0x66`.
///
/// **The opcode is its own truth table**, indexed by the three operand bits:
///
///     result = (opcode >> ((pattern << 2) | (source << 1) | destination)) & 1
///
/// That one line replaces the reference's 256 generated handlers, and it is not
/// a guess. `common/rop3.c` registers each opcode with its formula written out
/// — `ROP3_HANDLERS(DPSoon, ~(*pat | *src | *dest), 0x01)` and 217 more — and
/// every one of those formulas was evaluated over all eight operand
/// combinations and compared against this expression. They agree on all 218.
///
/// **The reference implements 218 of the 256, and the 38 it leaves out are
/// exactly the 38 that ignore at least one of their three operands.** That is
/// measured too, not assumed: the two sets match element for element. They are
/// the ones a server sends as a simpler message instead — `0xCC` as a
/// `DRAW_COPY`, `0xF0` as a `DRAW_FILL`, `0x00` as a `DRAW_BLACKNESS` — and the
/// reference calls `spice_critical("not implemented")` if one arrives anyway.
///
/// wisq evaluates the table, so all 256 work. That is not ambition; it is that
/// a `switch` over 218 cases and a crash on the rest would be more code than
/// the line above and worse.
///
/// **The bit order is not the same as the binary operation's.** `SpiceROP`
/// indexes its four-bit table as `3 − (2·src + dst)`, counting from the top;
/// this one indexes directly. Writing either convention in the other's place
/// gives a mirrored table — which is a picture, and a wrong one. Both are
/// pinned by exhaustive tests against a second derivation.
struct SpiceROP3: Equatable, Sendable {
    let opcode: UInt8

    init(_ opcode: UInt8) { self.opcode = opcode }

    /// Combines one byte of each operand.
    func apply(pattern: UInt8, source: UInt8, destination: UInt8) -> UInt8 {
        var out: UInt8 = 0
        for bit in UInt8(0)..<8 {
            let index = (pattern >> bit & 1) << 2 | (source >> bit & 1) << 1
                | (destination >> bit & 1)
            out |= (opcode >> index & 1) << bit
        }
        return out
    }

    /// Whether this operation leaves the destination exactly as it was — the
    /// ternary `DSTCOPY`, `0xAA`.
    var leavesTheDestinationAlone: Bool { opcode == 0xAA }

    /// Whether the operand takes no part in the result.
    ///
    /// Only used to say something true about the reference in a test, but it is
    /// the honest way to say it: "the 38 it omits" is a list, and "the ones
    /// that ignore an operand" is a property.
    func ignores(_ operand: Operand) -> Bool {
        for first in UInt8(0)..<2 {
            for second in UInt8(0)..<2 {
                let (low, high) = operand.indices(first, second)
                if opcode >> low & 1 != opcode >> high & 1 { return false }
            }
        }
        return true
    }

    enum Operand: CaseIterable, Sendable {
        case pattern, source, destination

        /// The two table indices that differ only in this operand.
        func indices(_ first: UInt8, _ second: UInt8) -> (UInt8, UInt8) {
            switch self {
            case .pattern: return (first << 1 | second, 1 << 2 | first << 1 | second)
            case .source: return (first << 2 | second, first << 2 | 1 << 1 | second)
            case .destination: return (first << 2 | second << 1, first << 2 | second << 1 | 1)
            }
        }
    }
}
