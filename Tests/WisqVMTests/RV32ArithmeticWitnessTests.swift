import XCTest

@testable import WisqVM

/// The instructions a booting kernel computes with but never puts under strain.
///
/// A sweep of `RV32Core`'s decoder — a hundred and six arms, each turned into a
/// no-op one at a time — sorted them by what caught it:
///
/// | tenu par | bras |
/// | --- | --- |
/// | un test unitaire | 17 |
/// | le démarrage du noyau, jusqu'à la bannière | 23 |
/// | le démarrage du noyau, jusqu'à l'invite de connexion | 23 |
/// | **rien** | **43** |
///
/// The third row is the assertion added next door in `LinuxBootTests`, and it
/// is the same lesson as the last two slices read the other way round: coverage
/// follows what a test *traverses*, so widening where the boot stops looking
/// converted twenty-three arms without touching the emulator.
///
/// What it could not convert is this file. These are arms a kernel booting to a
/// login prompt genuinely never exercises — not the plumbing it leans on, but
/// the edges the ISA specifies and ordinary code never reaches: division by
/// zero, the one signed quotient that overflows, the three signednesses of a
/// high-word multiply, the four atomic min/max that differ only in how they
/// read a sign bit. Nothing here is exotic; each is a line of the RISC-V spec
/// with a required answer, and each was one wrong character away from being
/// silently wrong in a guest's arithmetic.
///
/// No defect found. Every arm read correctly. What was missing was the witness.
final class RV32ArithmeticWitnessTests: XCTestCase {
    private final class NullBus: RV32Bus {
        func mmioLoad(_ address: UInt32) -> UInt32 { 0 }
        func mmioStore(_ address: UInt32, _ value: UInt32) -> UInt32? { nil }
    }

    private var ram: UnsafeMutableRawPointer!
    private var bus: NullBus!
    private var core: RV32Core!
    private let ramSize: UInt32 = 1 << 20

    override func setUp() {
        ram = .allocate(byteCount: Int(ramSize), alignment: 8)
        ram.initializeMemory(as: UInt8.self, repeating: 0, count: Int(ramSize))
        bus = NullBus()
        core = RV32Core(ram: ram, ramSize: ramSize, bus: bus)
        core.extraflags |= 3
    }

    override func tearDown() {
        core = nil
        ram.deallocate()
    }

    // MARK: - Encoders

    /// `funct7 | rs2 | rs1 | funct3 | rd | 0110011`.
    private func rtype(
        _ funct7: UInt32, _ rs2: Int, _ rs1: Int, _ funct3: UInt32, _ rd: Int
    ) -> UInt32 {
        (funct7 << 25) | (UInt32(rs2) << 20) | (UInt32(rs1) << 15) | (funct3 << 12)
            | (UInt32(rd) << 7) | 0x33
    }

    /// RV32M shares the R-type shape and is told apart by funct7 = 1.
    private func muldiv(_ funct3: UInt32, _ rd: Int, _ rs1: Int, _ rs2: Int) -> UInt32 {
        rtype(1, rs2, rs1, funct3, rd)
    }

    /// `funct5 | aq | rl | rs2 | rs1 | 010 | rd | 0101111`. Word-width only.
    private func amo(_ funct5: UInt32, _ rd: Int, _ rs2: Int, _ rs1: Int) -> UInt32 {
        (funct5 << 27) | (UInt32(rs2) << 20) | (UInt32(rs1) << 15) | (2 << 12)
            | (UInt32(rd) << 7) | 0x2F
    }

    /// Runs one instruction written at the reset address, with the registers
    /// placed directly rather than materialised — the subject is the arm, not
    /// the four instructions it would take to build a constant.
    private func execute(_ instruction: UInt32, _ registers: [Int: UInt32] = [:]) {
        ram.storeBytes(of: instruction, toByteOffset: 0, as: UInt32.self)
        for (index, value) in registers { core.regs[index] = value }
        core.pc = RV32Core.ramBase
        _ = core.step(elapsedMicroseconds: 0, count: 1)
    }

    private var trapped: Bool { core.pc != RV32Core.ramBase + 4 }

    // MARK: - The three high-word multiplies

    /// `MULH`, `MULHSU` and `MULHU` differ only in which operand carries a sign,
    /// which is invisible until an operand's top bit is set. One input pair
    /// separates all three: −65536 × 0x8000_0000 is a different number depending
    /// on how many of those two you read as negative.
    ///
    /// The operands are chosen so that all three answers are non-zero. An
    /// earlier version used −1 × 0x8000_0000, whose signed high word is zero —
    /// and a `MULH` that computed nothing at all would have written zero too.
    /// The counter-check caught it: a probe that cannot tell the arm from its
    /// absence proves nothing about the arm.
    func testTheThreeHighMultipliesDisagreeOnTheSameOperands() {
        let minusSixtyFourK: UInt32 = 0xFFFF_0000
        let topBit: UInt32 = 0x8000_0000

        execute(muldiv(1, 3, 1, 2), [1: minusSixtyFourK, 2: topBit])
        XCTAssertEqual(core.regs[3], 0x0000_8000, "MULH : (−2¹⁶) × (−2³¹) = +2⁴⁷")

        execute(muldiv(2, 3, 1, 2), [1: minusSixtyFourK, 2: topBit])
        XCTAssertEqual(core.regs[3], 0xFFFF_8000, "MULHSU : (−2¹⁶) × 2³¹ = −2⁴⁷")

        execute(muldiv(3, 3, 1, 2), [1: minusSixtyFourK, 2: topBit])
        XCTAssertEqual(core.regs[3], 0x7FFF_8000, "MULHU : les deux non signés, 2⁶³ − 2⁴⁷")
    }

    /// And the ordinary case, so a witness that only ever saw the edge would not
    /// pass an implementation that got the common path wrong.
    func testHighMultiplyOnSmallPositivesIsZero() {
        execute(muldiv(1, 3, 1, 2), [1: 3, 2: 5])
        XCTAssertEqual(core.regs[3], 0, "15 tient dans le mot bas")
        execute(muldiv(0, 3, 1, 2), [1: 3, 2: 5])
        XCTAssertEqual(core.regs[3], 15, "et c'est MUL qui le porte")
    }

    // MARK: - Division, and the two answers the spec had to invent

    /// RISC-V has no divide-by-zero trap: the quotient is all-ones and the
    /// program carries on. A guest that expected a fault would hang; one that
    /// expected this keeps running, which is why the spec chose it.
    func testDivisionByZeroAnswersAllOnesWithoutTrapping() {
        execute(muldiv(4, 3, 1, 2), [1: 7, 2: 0])
        XCTAssertEqual(core.regs[3], 0xFFFF_FFFF, "DIV par zéro")
        XCTAssertFalse(trapped, "et surtout : pas de piège")

        execute(muldiv(5, 3, 1, 2), [1: 7, 2: 0])
        XCTAssertEqual(core.regs[3], 0xFFFF_FFFF, "DIVU par zéro, même réponse")
        XCTAssertFalse(trapped)
    }

    /// The remainder's answer for a zero divisor is the dividend — a different
    /// choice from the quotient's, and the one a naive implementation gets
    /// wrong by reusing the all-ones it just wrote next door.
    func testRemainderByZeroAnswersTheDividend() {
        // A dividend with no small round value in it: the point is that the
        // answer is *this* number and not some other constant the arm might
        // have been left holding.
        let dividend: UInt32 = 0x1234_5678

        execute(muldiv(6, 3, 1, 2), [1: dividend, 2: 0])
        XCTAssertEqual(core.regs[3], dividend, "REM par zéro rend le dividende")
        XCTAssertFalse(trapped)

        execute(muldiv(7, 3, 1, 2), [1: dividend, 2: 0])
        XCTAssertEqual(core.regs[3], dividend, "REMU aussi")
        XCTAssertFalse(trapped)
    }

    /// The one signed division whose true quotient does not fit in the result.
    /// On a host that divides for us this is not a wrong answer, it is a
    /// hardware trap — so the guard is what stands between a guest's arithmetic
    /// and the process dying.
    func testTheOverflowingSignedDivisionIsAnsweredNotTrapped() {
        let intMin: UInt32 = 0x8000_0000
        let minusOne: UInt32 = 0xFFFF_FFFF

        execute(muldiv(4, 3, 1, 2), [1: intMin, 2: minusOne])
        XCTAssertEqual(core.regs[3], intMin, "DIV : le quotient déborde, la réponse est le dividende")
        XCTAssertFalse(trapped)

        execute(muldiv(6, 3, 1, 2), [1: intMin, 2: minusOne])
        XCTAssertEqual(core.regs[3], 0, "REM du même couple : zéro")
        XCTAssertFalse(trapped)
    }

    /// The half that is not an edge: signed division rounds toward zero and
    /// keeps the sign of the dividend, which is what `%` means here and not what
    /// a modulo would give.
    func testSignedDivisionRoundsTowardZeroAndTheRemainderFollowsTheDividend() {
        execute(muldiv(4, 3, 1, 2), [1: UInt32(bitPattern: -7), 2: 2])
        XCTAssertEqual(Int32(bitPattern: core.regs[3]), -3, "−7 / 2 = −3, pas −4")

        execute(muldiv(6, 3, 1, 2), [1: UInt32(bitPattern: -7), 2: 2])
        XCTAssertEqual(Int32(bitPattern: core.regs[3]), -1, "et le reste garde le signe du dividende")

        execute(muldiv(7, 3, 1, 2), [1: UInt32(bitPattern: -7), 2: 2])
        XCTAssertEqual(core.regs[3], 1, "REMU lit les mêmes bits comme un très grand positif")
    }

    // MARK: - SLT, which is not SLTU

    /// The comparison the boot exercises is the unsigned one; the signed twin
    /// beside it was held by nothing. They disagree on exactly the inputs that
    /// matter — anything with the top bit set.
    func testSetLessThanReadsTheSignAndItsUnsignedTwinDoesNot() {
        let minusOne: UInt32 = 0xFFFF_FFFF
        execute(rtype(0, 2, 1, 2, 3), [1: minusOne, 2: 1])
        XCTAssertEqual(core.regs[3], 1, "SLT : −1 < 1")

        execute(rtype(0, 2, 1, 3, 3), [1: minusOne, 2: 1])
        XCTAssertEqual(core.regs[3], 0, "SLTU : 0xFFFF_FFFF n'est pas < 1")
    }

    // MARK: - The atomics the kernel does not reach

    private let cell: UInt32 = 0x1000
    private var address: UInt32 { RV32Core.ramBase + cell }
    private func memory() -> UInt32 { ram.load(fromByteOffset: Int(cell), as: UInt32.self) }
    private func setMemory(_ value: UInt32) {
        ram.storeBytes(of: value, toByteOffset: Int(cell), as: UInt32.self)
    }

    /// `AMOXOR.W`: the cell takes the exclusive-or, the register takes what the
    /// cell held. Both halves, because an implementation that forgot the second
    /// would look right to anything that only re-read memory.
    func testAtomicXorSwapsInTheOldValueWhileWritingTheNewOne() {
        setMemory(0b1100)
        execute(amo(4, 3, 2, 1), [1: address, 2: 0b1010])
        XCTAssertEqual(memory(), 0b0110, "la cellule reçoit le ou-exclusif")
        XCTAssertEqual(core.regs[3], 0b1100, "et le registre l'ancienne valeur")
    }

    /// The four atomic min/max differ only in whether the top bit means *large*
    /// or *negative*. One pair of operands separates all four, and getting the
    /// signedness backwards is the classic way to write them.
    ///
    /// Each is asked twice, because half the answers are the register operand —
    /// and an arm that computed nothing would leave the register operand in
    /// place and store exactly that. The second case is the one where the cell
    /// has to win, which no amount of doing nothing achieves. The counter-check
    /// found `AMOMAX` and `AMOMINU` surviving on the first case alone.
    func testTheFourAtomicMinMaxSplitOnTheSignBit() {
        let minusOne: UInt32 = 0xFFFF_FFFF

        // Le registre l'emporte : le signe décide lequel des quatre le fait.
        setMemory(minusOne)
        execute(amo(16, 3, 2, 1), [1: address, 2: 1])
        XCTAssertEqual(memory(), minusOne, "AMOMIN signé : −1 est le plus petit")

        setMemory(minusOne)
        execute(amo(24, 3, 2, 1), [1: address, 2: 1])
        XCTAssertEqual(memory(), 1, "AMOMINU non signé : 1 est le plus petit")

        setMemory(minusOne)
        execute(amo(20, 3, 2, 1), [1: address, 2: 1])
        XCTAssertEqual(memory(), 1, "AMOMAX signé : 1 est le plus grand")

        setMemory(minusOne)
        execute(amo(28, 3, 2, 1), [1: address, 2: 1])
        XCTAssertEqual(memory(), minusOne, "AMOMAXU non signé : 0xFFFF_FFFF est le plus grand")

        // La cellule l'emporte : aucun de ces quatre ne peut y arriver en ne
        // faisant rien, puisque ne rien faire écrit le registre.
        setMemory(3)
        execute(amo(16, 3, 2, 1), [1: address, 2: 8])
        XCTAssertEqual(memory(), 3, "AMOMIN : la cellule était la plus petite")

        setMemory(3)
        execute(amo(24, 3, 2, 1), [1: address, 2: 8])
        XCTAssertEqual(memory(), 3, "AMOMINU de même")

        setMemory(8)
        execute(amo(20, 3, 2, 1), [1: address, 2: 3])
        XCTAssertEqual(memory(), 8, "AMOMAX : la cellule était la plus grande")

        setMemory(8)
        execute(amo(28, 3, 2, 1), [1: address, 2: 3])
        XCTAssertEqual(memory(), 8, "AMOMAXU de même")
    }

    /// And each of them still returns what the cell held, which is the half of
    /// an atomic that makes it worth being one.
    func testAnAtomicMinStillReturnsTheOldValue() {
        setMemory(9)
        execute(amo(24, 3, 2, 1), [1: address, 2: 4])
        XCTAssertEqual(memory(), 4)
        XCTAssertEqual(core.regs[3], 9, "la valeur d'avant, pas celle d'après")
    }

    // MARK: - Store-conditional, the half its neighbour's name promised

    /// `testLrScPairSucceedsAndStaleScFails` next door checks the success. The
    /// failure it names is what the sweep found held by nothing: make the
    /// reservation check answer *success* unconditionally and that test stays
    /// green.
    ///
    /// A store-conditional on an address nobody reserved must fail, and failing
    /// means two things at once — a non-zero result *and* memory left alone.
    func testAStoreConditionalOnAnUnreservedAddressFailsAndWritesNothing() {
        setMemory(0xDEAD)
        // LR on one cell, SC on another: the reservation does not carry over.
        execute(amo(2, 4, 0, 1), [1: RV32Core.ramBase + 0x2000])
        execute(amo(3, 3, 2, 1), [1: address, 2: 77])

        XCTAssertEqual(core.regs[3], 1, "un SC sans réservation correspondante échoue")
        XCTAssertEqual(memory(), 0xDEAD, "et n'écrit rien")
    }

    /// The same store-conditional after the matching load-reserved: it is the
    /// contrast that makes the failure above mean something.
    func testTheSameStoreConditionalSucceedsAfterItsOwnLoadReserved() {
        setMemory(0xDEAD)
        execute(amo(2, 4, 0, 1), [1: address])
        XCTAssertEqual(core.regs[4], 0xDEAD, "LR rend la valeur")
        XCTAssertEqual(memory(), 0xDEAD, "et n'écrit pas")

        execute(amo(3, 3, 2, 1), [1: address, 2: 77])
        XCTAssertEqual(core.regs[3], 0, "le SC apparié réussit")
        XCTAssertEqual(memory(), 77)
    }
}
