import Foundation

/// The raster operation a draw combines its pixels with.
///
/// Every draw message on this channel carries a `rop_descriptor`, and wisq has
/// been throwing it away — `fill` and `copy` always wrote the source over the
/// destination. That is right for the overwhelmingly common descriptor and
/// wrong for the ones that matter most when they appear: a selection rectangle,
/// a text caret and a rubber-band outline are all drawn with `XOR`, precisely
/// so that drawing them twice restores the screen. Ignored, they paint solid
/// and never come off.
///
/// There are two layers here and they are easy to run together.
///
/// The **descriptor** is what the wire carries: eleven flag bits saying which
/// operands to invert, which operation to use, and whether to invert the
/// result. The **operation** is one of the sixteen classic X11 raster ops, each
/// a boolean function of one source bit and one destination bit.
/// `ropd_descriptor_to_rop` in `canvas_base.c` collapses the first onto the
/// second, and the collapse is not a lookup — it is a nest of conditions that
/// notice, for example, that inverting both operands of an `XOR` and then not
/// inverting the result is the same as `XOR` itself.
enum SpiceROP: UInt8, Equatable, Sendable, CaseIterable {
    case clear = 0x0          // 0
    case and = 0x1            // src AND dst
    case andReverse = 0x2     // src AND NOT dst
    case copy = 0x3           // src
    case andInverted = 0x4    // (NOT src) AND dst
    case noop = 0x5           // dst
    case xor = 0x6            // src XOR dst
    case or = 0x7             // src OR dst
    case nor = 0x8            // (NOT src) AND (NOT dst)
    case equiv = 0x9          // (NOT src) XOR dst
    case invert = 0xA         // NOT dst
    case orReverse = 0xB      // src OR (NOT dst)
    case copyInverted = 0xC   // NOT src
    case orInverted = 0xD     // (NOT src) OR dst
    case nand = 0xE           // (NOT src) OR (NOT dst)
    case set = 0xF            // 1

    /// Combines one byte of source with one byte of destination.
    ///
    /// Written out case by case rather than derived from the raw value, even
    /// though the raw value *is* the truth table — bit `3 − (2·src + dst)` of it
    /// is the result for that pair of input bits. The derivation is four lines
    /// and completely opaque; these sixteen are each readable against the
    /// comment beside them. The clever version earns its keep in the tests,
    /// where it is the independent second opinion that says these are right.
    func apply(source: UInt8, destination: UInt8) -> UInt8 {
        switch self {
        case .clear: return 0x00
        case .and: return source & destination
        case .andReverse: return source & ~destination
        case .copy: return source
        case .andInverted: return ~source & destination
        case .noop: return destination
        case .xor: return source ^ destination
        case .or: return source | destination
        case .nor: return ~source & ~destination
        case .equiv: return ~source ^ destination
        case .invert: return ~destination
        case .orReverse: return source | ~destination
        case .copyInverted: return ~source
        case .orInverted: return ~source | destination
        case .nand: return ~source | ~destination
        case .set: return 0xFF
        }
    }

    /// Whether this operation leaves the destination exactly as it was.
    ///
    /// The reference checks for it and returns early. It is worth knowing that
    /// **`descriptor(_:source:destination:)` can never produce it** — no
    /// descriptor maps to `noop` — so the check is unreachable there. It is
    /// kept because the property is about the operation rather than about where
    /// the operation came from, and because a `DRAW_ROP3` message names one of
    /// the 256 ternary ops directly and could.
    var leavesTheDestinationAlone: Bool { self == .noop }

    /// Which of a draw's three operands feeds a side of the operation.
    ///
    /// This exists because the same descriptor is read differently by different
    /// messages. A fill combines its *brush* with the destination; a copy
    /// combines its *source image* with the destination; and `DRAW_OPAQUE`
    /// combines the brush with the *image* — the destination is not an operand
    /// of its rop at all, because the image has already been blitted over it.
    ///
    /// So "invert the source" in the descriptor means "invert the brush" for a
    /// fill. Reading `INVERS_SRC` literally in all three places gives a fill
    /// that inverts nothing and an opaque that inverts the wrong operand.
    enum Input: Equatable, Sendable {
        case source, brush, destination

        /// The descriptor bit that inverts this operand.
        var inverseFlag: UInt16 {
            switch self {
            case .source: return 0x001       // INVERS_SRC
            case .brush: return 0x002        // INVERS_BRUSH
            case .destination: return 0x004  // INVERS_DEST
            }
        }
    }

    static let opPut: UInt16 = 0x008
    static let opOr: UInt16 = 0x010
    static let opAnd: UInt16 = 0x020
    static let opXor: UInt16 = 0x040
    static let opBlackness: UInt16 = 0x080
    static let opWhiteness: UInt16 = 0x100
    static let opInvers: UInt16 = 0x200
    static let inverseResult: UInt16 = 0x400

    /// Collapses a wire descriptor onto one of the sixteen operations.
    ///
    /// A transcription of `ropd_descriptor_to_rop`, and the shape of it is
    /// worth keeping rather than replacing with a truth table, because two of
    /// its properties are surprising enough that a table would hide them:
    ///
    ///   * **the operation bits are tested in order, not exclusively.** A
    ///     descriptor with both `OP_OR` and `OP_AND` set is an `OR`, and one
    ///     with no operation bit at all is a `copy`. Neither is a
    ///     malformed-message case;
    ///   * **four of the outcomes ignore every inversion flag**, `INVERS_RES`
    ///     included: `BLACKNESS`, `WHITENESS`, `INVERS`, and the fall-through
    ///     when no operation bit is set. So `OP_BLACKNESS | INVERS_RES` is
    ///     `clear` rather than `set`, and `INVERS_RES` on its own is `copy`
    ///     rather than `copyInverted`. It reads like an oversight — every other
    ///     path honours the flags — and it is reproduced rather than corrected,
    ///     because the server draws expecting what its own client does. A test
    ///     that assumed the sensible rule instead of this one is what found it.
    static func descriptor(
        _ descriptor: UInt16, source: Input, destination: Input
    ) -> SpiceROP {
        // The two operands are re-labelled first: whichever flag inverts *this
        // message's* source becomes INVERS_SRC, and likewise for the
        // destination. Everything below then reads the two canonical bits.
        var desc = descriptor & ~(Input.source.inverseFlag | Input.destination.inverseFlag)
        if descriptor & source.inverseFlag != 0 { desc |= Input.source.inverseFlag }
        if descriptor & destination.inverseFlag != 0 { desc |= Input.destination.inverseFlag }

        let invertsSource = desc & Input.source.inverseFlag != 0
        let invertsDestination = desc & Input.destination.inverseFlag != 0
        let invertsResult = desc & inverseResult != 0

        if desc & opPut != 0 {
            // The destination is not an operand, so only the source's inversion
            // and the result's matter — and they cancel.
            return invertsSource != invertsResult ? .copyInverted : .copy
        }
        if desc & opOr != 0 {
            switch (invertsResult, invertsSource, invertsDestination) {
            case (true, true, true): return .and              // !(!s | !d) == s & d
            case (true, true, false): return .andReverse      // !(!s | d) == s & !d
            case (true, false, true): return .andInverted     // !(s | !d) == !s & d
            case (true, false, false): return .nor
            case (false, true, true): return .nand            // !s | !d
            case (false, true, false): return .orInverted     // !s | d
            case (false, false, true): return .orReverse      // s | !d
            case (false, false, false): return .or
            }
        }
        if desc & opAnd != 0 {
            switch (invertsResult, invertsSource, invertsDestination) {
            case (true, true, true): return .or               // !(!s & !d) == s | d
            case (true, true, false): return .orReverse       // !(!s & d) == s | !d
            case (true, false, true): return .orInverted      // !(s & !d) == !s | d
            case (true, false, false): return .nand
            case (false, true, true): return .nor             // !s & !d
            case (false, true, false): return .andInverted    // !s & d
            case (false, false, true): return .andReverse     // s & !d
            case (false, false, false): return .and
            }
        }
        if desc & opXor != 0 {
            // Three inversions that each flip the result, so what survives is
            // their parity. The reference writes all eight branches out; this
            // counts them, and the exhaustive test says the two agree.
            let flips = (invertsResult ? 1 : 0) + (invertsSource ? 1 : 0)
                + (invertsDestination ? 1 : 0)
            return flips % 2 == 0 ? .xor : .equiv
        }
        if desc & opBlackness != 0 { return .clear }
        if desc & opWhiteness != 0 { return .set }
        if desc & opInvers != 0 { return .invert }
        return .copy
    }
}
