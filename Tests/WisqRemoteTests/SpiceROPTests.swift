import XCTest
@testable import WisqRemote

/// The raster operation, and the descriptor that names it.
///
/// Everything here is a pure function of small integers, so nothing needs a
/// fixture and nothing needs sampling: the tests below cover every operation
/// against every pair of bytes, and every one of the 2048 descriptors against
/// all three ways a message can label its operands. When a test says "all", it
/// means all.
final class SpiceROPTests: XCTestCase {
    // MARK: - The sixteen operations

    /// **The raw value is the truth table**, and that is the independent second
    /// opinion on the sixteen hand-written cases.
    ///
    /// An X11 raster op's number encodes its result for the four combinations
    /// of one source bit and one destination bit: bit `3 − (2·src + dst)` of the
    /// number is the answer for that pair. `SpiceROP.apply` does not use that —
    /// it spells each case out in bitwise operators, because the derivation is
    /// unreadable and the operators are checkable against the comment beside
    /// them. Here the derivation earns its keep: two independent statements of
    /// the same sixteen functions, compared over every input.
    func testEveryOperationAgreesWithItsOwnTruthTable() {
        for operation in SpiceROP.allCases {
            for source in UInt8.min...UInt8.max {
                for destination in UInt8.min...UInt8.max {
                    let got = operation.apply(source: source, destination: destination)
                    var expected: UInt8 = 0
                    for bit in 0..<8 {
                        let sourceBit = Int(source >> UInt8(bit)) & 1
                        let destinationBit = Int(destination >> UInt8(bit)) & 1
                        let index = 3 - (2 * sourceBit + destinationBit)
                        let result = Int(operation.rawValue) >> index & 1
                        expected |= UInt8(result) << UInt8(bit)
                    }
                    guard got == expected else {
                        return XCTFail(
                            "\(operation) : \(source) sur \(destination) donne \(got), "
                                + "la table dit \(expected)"
                        )
                    }
                }
            }
        }
    }

    /// The two that a caller might reasonably special-case, pinned by name so
    /// that renumbering the enum is a test failure rather than a silent change
    /// of meaning.
    func testTheIdentityAndTheTwoConstants() {
        XCTAssertEqual(SpiceROP.copy.apply(source: 0xA5, destination: 0x3C), 0xA5)
        XCTAssertEqual(SpiceROP.noop.apply(source: 0xA5, destination: 0x3C), 0x3C)
        XCTAssertEqual(SpiceROP.clear.apply(source: 0xA5, destination: 0x3C), 0x00)
        XCTAssertEqual(SpiceROP.set.apply(source: 0xA5, destination: 0x3C), 0xFF)
        XCTAssertTrue(SpiceROP.noop.leavesTheDestinationAlone)
        XCTAssertFalse(SpiceROP.copy.leavesTheDestinationAlone)
    }

    /// Why the descriptor matters at all: XOR twice is the identity, which is
    /// how a selection rectangle or a caret comes off the screen again. Drawn
    /// as a plain copy — which is what wisq did with every descriptor until
    /// now — it goes on and stays on.
    func testXorTwiceRestoresTheDestination() {
        for source in UInt8.min...UInt8.max {
            for destination in UInt8.min...UInt8.max {
                let once = SpiceROP.xor.apply(source: source, destination: destination)
                XCTAssertEqual(SpiceROP.xor.apply(source: source, destination: once), destination)
            }
        }
    }

    // MARK: - The descriptor

    /// The bit values, from `spice-protocol`'s generated header rather than
    /// from the order they happen to appear in the `.proto`.
    private enum Flag {
        static let inversSource: UInt16 = 1 << 0
        static let inversBrush: UInt16 = 1 << 1
        static let inversDestination: UInt16 = 1 << 2
        static let put: UInt16 = 1 << 3
        static let or: UInt16 = 1 << 4
        static let and: UInt16 = 1 << 5
        static let xor: UInt16 = 1 << 6
        static let blackness: UInt16 = 1 << 7
        static let whiteness: UInt16 = 1 << 8
        static let invers: UInt16 = 1 << 9
        static let inversResult: UInt16 = 1 << 10
    }

    func testTheFlagValuesAreTheOnesTheProtocolGenerates() {
        XCTAssertEqual(SpiceROP.Input.source.inverseFlag, Flag.inversSource)
        XCTAssertEqual(SpiceROP.Input.brush.inverseFlag, Flag.inversBrush)
        XCTAssertEqual(SpiceROP.Input.destination.inverseFlag, Flag.inversDestination)
        XCTAssertEqual(SpiceROP.opPut, Flag.put)
        XCTAssertEqual(SpiceROP.opOr, Flag.or)
        XCTAssertEqual(SpiceROP.opAnd, Flag.and)
        XCTAssertEqual(SpiceROP.opXor, Flag.xor)
        XCTAssertEqual(SpiceROP.opBlackness, Flag.blackness)
        XCTAssertEqual(SpiceROP.opWhiteness, Flag.whiteness)
        XCTAssertEqual(SpiceROP.opInvers, Flag.invers)
        XCTAssertEqual(SpiceROP.inverseResult, Flag.inversResult)
    }

    /// What the descriptor *means*, worked out from first principles rather
    /// than from the reference's nest of conditions.
    ///
    /// Invert the operands the flags name, apply the operation, invert the
    /// result if asked. That is the whole semantics, and it is a different
    /// statement from "twenty-eight nested `if`s produce these sixteen
    /// answers" — which is what makes comparing them worth doing.
    ///
    /// `nil` for the three constant operations, because they are the place the
    /// reference stops following its own rule and they are checked separately.
    private func meaning(
        _ descriptor: UInt16, source: SpiceROP.Input, destination: SpiceROP.Input
    ) -> ((Bool, Bool) -> Bool)? {
        let invertSource = descriptor & source.inverseFlag != 0
        let invertDestination = descriptor & destination.inverseFlag != 0
        let invertResult = descriptor & Flag.inversResult != 0

        let operation: ((Bool, Bool) -> Bool)?
        if descriptor & Flag.put != 0 {
            operation = { source, _ in source }
        } else if descriptor & Flag.or != 0 {
            operation = { $0 || $1 }
        } else if descriptor & Flag.and != 0 {
            operation = { $0 && $1 }
        } else if descriptor & Flag.xor != 0 {
            operation = { $0 != $1 }
        } else {
            // The three constant operations, and the fall-through for a
            // descriptor naming no operation at all. All four ignore every
            // inversion flag, so none of them is describable by the rule this
            // function states; they are checked by name instead.
            return nil
        }
        guard let operation else { return nil }

        return { source, destination in
            let result = operation(
                invertSource ? !source : source,
                invertDestination ? !destination : destination
            )
            return invertResult ? !result : result
        }
    }

    /// Every descriptor, against every way a message can label its operands.
    ///
    /// 2048 descriptors × 3 labellings × 4 input pairs. The comparison is on
    /// the *behaviour* of the operation returned, not on its name, because two
    /// different descriptors are allowed to collapse onto the same operation
    /// and often do.
    func testEveryDescriptorMeansWhatItsFlagsSay() {
        let labellings: [(SpiceROP.Input, SpiceROP.Input)] = [
            (.brush, .destination),      // DRAW_FILL
            (.source, .destination),     // DRAW_COPY and DRAW_BLEND
            (.brush, .source),           // DRAW_OPAQUE
        ]
        var checked = 0
        for descriptor in UInt16(0)...UInt16(0x7FF) {
            for (source, destination) in labellings {
                guard let expected = meaning(descriptor, source: source, destination: destination)
                else { continue }
                let operation = SpiceROP.descriptor(
                    descriptor, source: source, destination: destination
                )
                for sourceBit in [false, true] {
                    for destinationBit in [false, true] {
                        let got = operation.apply(
                            source: sourceBit ? 0xFF : 0x00,
                            destination: destinationBit ? 0xFF : 0x00
                        )
                        let want: UInt8 = expected(sourceBit, destinationBit) ? 0xFF : 0x00
                        guard got == want else {
                            return XCTFail(
                                "descripteur \(String(descriptor, radix: 2)) "
                                    + "(\(source) sur \(destination)) : "
                                    + "\(operation) donne \(got) pour "
                                    + "(\(sourceBit), \(destinationBit)), attendu \(want)"
                            )
                        }
                    }
                }
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 3000, "le test n'a presque rien parcouru")
    }

    /// **The three constant operations ignore every inversion flag**, including
    /// the one that inverts the result.
    ///
    /// `OP_BLACKNESS | INVERS_RES` is `clear`, not `set`. That reads like an
    /// oversight in the reference — every other operation honours the flag —
    /// and it is reproduced rather than corrected, because the server draws
    /// expecting this client to do what its own client does.
    func testTheConstantOperationsIgnoreTheInversionFlags() {
        let everyInversion = Flag.inversSource | Flag.inversBrush
            | Flag.inversDestination | Flag.inversResult
        for extra in [UInt16(0), everyInversion] {
            XCTAssertEqual(
                SpiceROP.descriptor(Flag.blackness | extra, source: .source, destination: .destination),
                .clear, "noir avec \(extra)"
            )
            XCTAssertEqual(
                SpiceROP.descriptor(Flag.whiteness | extra, source: .source, destination: .destination),
                .set
            )
            XCTAssertEqual(
                SpiceROP.descriptor(Flag.invers | extra, source: .source, destination: .destination),
                .invert
            )
        }
    }

    /// The operation bits are tested in order and are not exclusive, and a
    /// descriptor naming no operation at all is a plain copy. Both are normal
    /// messages rather than malformed ones.
    func testSeveralOperationBitsTakeTheFirstAndNoneMeansCopy() {
        XCTAssertEqual(
            SpiceROP.descriptor(Flag.or | Flag.and, source: .source, destination: .destination),
            .or, "PUT, OR, AND, XOR : le premier gagne"
        )
        XCTAssertEqual(
            SpiceROP.descriptor(Flag.and | Flag.xor, source: .source, destination: .destination),
            .and
        )
        XCTAssertEqual(
            SpiceROP.descriptor(0, source: .source, destination: .destination), .copy
        )
        // **And the fall-through ignores the inversion flags**, exactly as the
        // three constant operations do. This assertion said `copyInverted`
        // when it was written, from the reasonable-sounding rule that
        // INVERS_RES always applies; the reference's last line is a bare
        // `return SPICE_ROP_COPY` that never looks at a flag. The test was
        // wrong and the transcription was right, which is the order those two
        // are supposed to be discovered in.
        for flags in [Flag.inversResult, Flag.inversSource, Flag.inversDestination,
                      Flag.inversResult | Flag.inversSource] {
            XCTAssertEqual(
                SpiceROP.descriptor(flags, source: .source, destination: .destination),
                .copy, "sans bit d'opération : copie, quels que soient les drapeaux"
            )
        }
    }

    /// **Which operand the descriptor calls "source" depends on the message.**
    ///
    /// A fill's rop combines the brush with the destination, so `INVERS_BRUSH`
    /// is what inverts its source. Reading `INVERS_SRC` literally gives a fill
    /// that inverts nothing at all — and a descriptor of `PUT | INVERS_BRUSH`,
    /// which means "paint the complement of the brush", would paint the brush.
    func testTheSameDescriptorMeansDifferentThingsToDifferentMessages() {
        let descriptor = Flag.put | Flag.inversBrush

        XCTAssertEqual(
            SpiceROP.descriptor(descriptor, source: .brush, destination: .destination),
            .copyInverted, "pour un remplissage, INVERS_BRUSH inverse la source"
        )
        XCTAssertEqual(
            SpiceROP.descriptor(descriptor, source: .source, destination: .destination),
            .copy, "pour une copie, INVERS_BRUSH ne désigne aucun de ses opérandes"
        )

        // And DRAW_OPAQUE, whose rop combines the brush with the *image*: the
        // destination is not an operand of it at all.
        let inversSource = Flag.put | Flag.inversSource
        XCTAssertEqual(
            SpiceROP.descriptor(inversSource, source: .brush, destination: .source),
            .copy, "INVERS_SRC désigne ici la destination du rop, que PUT ignore"
        )
        XCTAssertEqual(
            SpiceROP.descriptor(inversSource, source: .source, destination: .destination),
            .copyInverted
        )
    }

    /// No descriptor produces `noop`.
    ///
    /// The reference checks for it and returns early, so that branch is
    /// unreachable from a descriptor. Worth pinning rather than asserting from
    /// reading: it is the kind of claim that is easy to make and cheap to
    /// check, and 2048 × 3 is every case there is.
    func testNoDescriptorCanAskForNothingToHappen() {
        let labellings: [(SpiceROP.Input, SpiceROP.Input)] = [
            (.brush, .destination), (.source, .destination), (.brush, .source),
        ]
        for descriptor in UInt16(0)...UInt16(0x7FF) {
            for (source, destination) in labellings {
                XCTAssertFalse(
                    SpiceROP.descriptor(descriptor, source: source, destination: destination)
                        .leavesTheDestinationAlone,
                    "descripteur \(descriptor)"
                )
            }
        }
    }
}
