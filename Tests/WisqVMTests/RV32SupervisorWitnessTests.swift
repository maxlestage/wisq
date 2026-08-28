import XCTest

@testable import WisqVM

/// The machine's supervisory surface: the CSRs a booting kernel does not touch,
/// and the five faults a working guest never takes.
///
/// This closes the sweep opened next door. Of the hundred and six decoder arms
/// measured, forty-three were held by nothing; `RV32ArithmeticWitnessTests`
/// covered nineteen of them, and these are the remaining twenty-four. They fall
/// into one shape: **the machine talking about itself**.
///
/// That is why the kernel misses them. It boots to a login prompt by executing
/// arithmetic, taking timer interrupts and dropping to user mode — so it reads
/// `mstatus` and `mepc` constantly and never once reads `misa`, writes `mtval`,
/// or runs off the end of its own RAM. The instructions here are the ones a
/// guest reaches for when something has gone wrong, or when it wants to know
/// what machine it is on. A test that only boots a healthy kernel cannot see
/// either.
///
/// No defect found; the twenty-four read correctly. What was missing was the
/// witness, and each is checked the only way that counts — by making its arm a
/// no-op and confirming this file goes red.
final class RV32SupervisorWitnessTests: XCTestCase {
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
        core.extraflags |= 3          // machine mode, like the reset state
        core.mtvec = Self.trapVector
    }

    override func tearDown() {
        core = nil
        ram.deallocate()
    }

    private static let trapVector = RV32Core.ramBase + 0x800

    // MARK: - Encoders

    /// `csr | rs1 | funct3 | rd | 1110011`. The immediate forms put a 5-bit
    /// literal where the register number goes, which is the whole reason they
    /// need their own funct3.
    private func system(_ csr: UInt32, _ rs1: UInt32, _ funct3: UInt32, _ rd: Int) -> UInt32 {
        (csr << 20) | (rs1 << 15) | (funct3 << 12) | (UInt32(rd) << 7) | 0x73
    }

    private func csrrw(_ rd: Int, _ csr: UInt32, _ rs1: Int) -> UInt32 {
        system(csr, UInt32(rs1), 1, rd)
    }
    private func csrrs(_ rd: Int, _ csr: UInt32, _ rs1: Int) -> UInt32 {
        system(csr, UInt32(rs1), 2, rd)
    }
    private func csrrc(_ rd: Int, _ csr: UInt32, _ rs1: Int) -> UInt32 {
        system(csr, UInt32(rs1), 3, rd)
    }
    private func csrrwi(_ rd: Int, _ csr: UInt32, _ imm: UInt32) -> UInt32 {
        system(csr, imm, 5, rd)
    }
    private func csrrci(_ rd: Int, _ csr: UInt32, _ imm: UInt32) -> UInt32 {
        system(csr, imm, 7, rd)
    }

    private func lw(_ rd: Int, _ offset: Int32, _ rs1: Int) -> UInt32 {
        (UInt32(bitPattern: offset) << 20) | (UInt32(rs1) << 15) | (2 << 12) | (UInt32(rd) << 7)
            | 0x03
    }
    private func sw(_ rs2: Int, _ offset: Int32, _ rs1: Int) -> UInt32 {
        let imm = UInt32(bitPattern: offset)
        return ((imm >> 5) << 25) | (UInt32(rs2) << 20) | (UInt32(rs1) << 15) | (2 << 12)
            | ((imm & 0x1F) << 7) | 0x23
    }
    private func jalr(_ rd: Int, _ rs1: Int, _ offset: Int32) -> UInt32 {
        (UInt32(bitPattern: offset) << 20) | (UInt32(rs1) << 15) | (UInt32(rd) << 7) | 0x67
    }
    /// `AMOADD.W`, used here only to reach the RV32A address check.
    private func amoadd(_ rd: Int, _ rs2: Int, _ rs1: Int) -> UInt32 {
        (UInt32(rs2) << 20) | (UInt32(rs1) << 15) | (2 << 12) | (UInt32(rd) << 7) | 0x2F
    }

    @discardableResult
    private func execute(
        _ instruction: UInt32, _ registers: [Int: UInt32] = [:]
    ) -> RV32StepResult {
        ram.storeBytes(of: instruction, toByteOffset: 0, as: UInt32.self)
        for (index, value) in registers { core.regs[index] = value }
        core.pc = RV32Core.ramBase
        return core.step(elapsedMicroseconds: 0, count: 1)
    }

    private var trapped: Bool { core.pc == Self.trapVector }

    // MARK: - Reading the CSRs the kernel never asks about

    /// A pure read is `CSRRS rd, csr, x0`: setting no bits, so the write-back
    /// leaves the register alone and only the old value reaches `rd`.
    ///
    /// Each CSR is given a value distinct from every other, because the failure
    /// this guards against is not "the read returns nothing" but "the read
    /// returns the neighbour" — a mistyped number in a switch is invisible when
    /// every register holds the same thing.
    func testEachMachineRegisterReadsBackItsOwnValue() {
        core.mtvec = 0x1111_1000       // must stay aligned enough to be a vector
        core.mie = 0x2222_2222
        core.mip = 0x3333_3333
        core.mtval = 0x4444_4444
        core.mcause = 0x5555_5555
        core.mepc = 0x6666_6666
        core.mscratch = 0x7777_7777

        let expected: [(UInt32, UInt32, String)] = [
            (0x305, 0x1111_1000, "mtvec"),
            (0x304, 0x2222_2222, "mie"),
            (0x344, 0x3333_3333, "mip"),
            (0x343, 0x4444_4444, "mtval"),
            (0x342, 0x5555_5555, "mcause"),
            (0x341, 0x6666_6666, "mepc"),
            (0x340, 0x7777_7777, "mscratch"),
        ]
        for (number, value, name) in expected {
            execute(csrrs(3, number, 0))
            XCTAssertEqual(core.regs[3], value, "lecture de \(name)")
        }
    }

    /// The two read-only identity registers. Their values are not arbitrary —
    /// `misa` says RV32 with the I, M and A extensions, which is exactly the
    /// machine this interpreter is — and a guest that reads something else may
    /// decide it is on hardware it cannot use.
    func testTheIdentityRegistersDescribeThisMachine() {
        execute(csrrs(3, 0x301, 0))
        XCTAssertEqual(core.regs[3], 0x4040_1101, "misa : RV32, I + M + A")

        execute(csrrs(3, 0xF11, 0))
        XCTAssertEqual(core.regs[3], 0xFF0F_F0FF, "mvendorid")
    }

    /// `cycle` is not a stored register: it counts what the hart has retired,
    /// so reading it twice with work in between must give two different answers.
    /// A constant would satisfy any test that read it once.
    func testTheCycleCounterAdvancesWithRetiredInstructions() {
        execute(csrrs(3, 0xC00, 0))
        let first = core.regs[3]

        // Retire a handful of instructions, then ask again.
        for _ in 0..<5 { execute(csrrs(0, 0xC00, 0)) }
        execute(csrrs(4, 0xC00, 0))

        XCTAssertGreaterThan(core.regs[4], first, "le compteur avance")
        XCTAssertEqual(core.regs[4] - first, 6, "d'exactement une par instruction retirée")
    }

    /// An unknown CSR reads as zero rather than trapping. This is the half of
    /// the rule that is not a refusal: a guest probing for a register this
    /// machine does not have gets a quiet zero and carries on.
    func testAnUnknownRegisterReadsZeroWithoutTrapping() {
        execute(csrrs(3, 0x7A0, 0), [3: 0xDEAD_BEEF])
        XCTAssertEqual(core.regs[3], 0, "un CSR inconnu vaut zéro")
        XCTAssertFalse(trapped, "et ne piège pas")
    }

    // MARK: - Writing them

    /// The write side of the same table, and the same reason for distinct
    /// values: a write that landed in the neighbouring register would pass any
    /// test that only checked its own.
    func testEachMachineRegisterIsWrittenThroughItsOwnNumber() {
        execute(csrrw(0, 0x344, 1), [1: 0xAAAA_AAAA])
        XCTAssertEqual(core.mip, 0xAAAA_AAAA, "écriture de mip")

        execute(csrrw(0, 0x342, 1), [1: 0xBBBB_BBBB])
        XCTAssertEqual(core.mcause, 0xBBBB_BBBB, "écriture de mcause")

        execute(csrrw(0, 0x343, 1), [1: 0xCCCC_CCCC])
        XCTAssertEqual(core.mtval, 0xCCCC_CCCC, "écriture de mtval")

        // Et les voisines n'ont pas bougé — sauf le bit 7 de mip, qui
        // n'appartient pas à l'écriture : c'est MTIP, que le hart republie à
        // chaque pas d'après l'horloge. Une assertion qui l'exigeait intact
        // mesurait le minuteur en croyant mesurer le CSR.
        XCTAssertEqual(core.mip & ~(1 << 7), 0xAAAA_AAAA & ~(1 << 7))
        XCTAssertEqual(core.mcause, 0xBBBB_BBBB)
    }

    /// And that bit, on its own, with its timing. The write lands whole — the
    /// hart republishes `MTIP` from the clock at the *top* of a step, not at the
    /// bottom — so the guest's value survives the instruction that wrote it and
    /// is overruled by the next one. Both halves matter: a handler that set the
    /// bit and then read it back would see its own value, and a handler that
    /// relied on it staying set would be wrong one instruction later.
    func testTheTimerOverrulesTheGuestsPendingBitOnTheFollowingStep() {
        execute(csrrw(0, 0x344, 1), [1: 0xFFFF_FFFF])
        XCTAssertEqual(core.mip, 0xFFFF_FFFF, "l'écriture passe entière")

        execute(csrrs(0, 0x340, 0))
        XCTAssertEqual(core.mip & (1 << 7), 0, "au pas suivant, MTIP retombe : rien n'est armé")
        XCTAssertEqual(core.mip | (1 << 7), 0xFFFF_FFFF, "et le reste du registre reste écrit")
    }

    /// A read-only register is not an error either: writing `misa` is accepted
    /// and discarded, which is what the spec asks for and what keeps a guest
    /// that scribbles on it from dying.
    func testWritingAReadOnlyRegisterIsIgnoredRatherThanRefused() {
        execute(csrrw(0, 0x301, 1), [1: 0])
        XCTAssertFalse(trapped)
        execute(csrrs(3, 0x301, 0))
        XCTAssertEqual(core.regs[3], 0x4040_1101, "misa n'a pas changé")
    }

    // MARK: - The six micro-operations

    /// `CSRRW` replaces, `CSRRS` sets bits, `CSRRC` clears them — and all three
    /// hand back what was there before, which is what makes them usable as an
    /// atomic read-modify-write.
    func testTheRegisterFormsReplaceSetAndClear() {
        core.mscratch = 0b1100
        execute(csrrw(3, 0x340, 1), [1: 0b0011])
        XCTAssertEqual(core.mscratch, 0b0011, "CSRRW remplace")
        XCTAssertEqual(core.regs[3], 0b1100, "et rend l'ancienne valeur")

        core.mscratch = 0b1100
        execute(csrrs(3, 0x340, 1), [1: 0b0011])
        XCTAssertEqual(core.mscratch, 0b1111, "CSRRS ajoute les bits")
        XCTAssertEqual(core.regs[3], 0b1100)

        core.mscratch = 0b1111
        execute(csrrc(3, 0x340, 1), [1: 0b0011])
        XCTAssertEqual(core.mscratch, 0b1100, "CSRRC retire les bits")
        XCTAssertEqual(core.regs[3], 0b1111)
    }

    /// The immediate forms read their operand from the register *field* rather
    /// than the register, so `CSRRWI x3, mscratch, 5` writes five — not
    /// whatever `x5` happens to hold. Loading `x5` with something else is what
    /// makes this test able to tell the two apart.
    func testTheImmediateFormsUseTheFieldAndNotTheRegisterItNames() {
        core.mscratch = 0
        execute(csrrwi(3, 0x340, 5), [5: 0xDEAD_BEEF])
        XCTAssertEqual(core.mscratch, 5, "CSRRWI écrit le littéral 5")

        core.mscratch = 0b1_1111
        execute(csrrci(3, 0x340, 0b0_0101), [5: 0xDEAD_BEEF])
        XCTAssertEqual(core.mscratch, 0b1_1010, "CSRRCI efface les bits du littéral")
        XCTAssertEqual(core.regs[3], 0b1_1111, "et rend l'ancienne valeur")
    }

    // MARK: - The five faults

    /// Running off the end of RAM. A guest that jumps into nothing must land in
    /// its own trap handler, not walk out of the emulator's buffer.
    func testAProgramCounterPastTheEndOfRAMTraps() {
        core.pc = RV32Core.ramBase &+ ramSize &+ 0x40
        _ = core.step(elapsedMicroseconds: 0, count: 1)
        XCTAssertEqual(core.mcause, 1, "défaut d'accès à l'instruction")
        XCTAssertTrue(trapped, "et le curseur part au vecteur")
    }

    /// A misaligned program counter is a different cause from an unreachable
    /// one, and a handler that told them apart by the cause would be misled by
    /// an implementation that collapsed the two.
    func testAMisalignedProgramCounterTrapsWithItsOwnCause() {
        core.pc = RV32Core.ramBase &+ 2
        _ = core.step(elapsedMicroseconds: 0, count: 1)
        XCTAssertEqual(core.mcause, 0, "PC désaligné")
        XCTAssertTrue(trapped)
    }

    /// A load and a store past the end of RAM: two causes, told apart because a
    /// handler decides whether the faulting access was a read or a write from
    /// nothing else.
    func testALoadAndAStorePastRAMTrapWithDifferentCauses() {
        let outside = RV32Core.ramBase &+ ramSize &+ 0x100

        execute(lw(3, 0, 1), [1: outside])
        XCTAssertEqual(core.mcause, 5, "défaut de chargement")
        XCTAssertTrue(trapped)

        core.mcause = 0
        execute(sw(2, 0, 1), [1: outside, 2: 42])
        XCTAssertEqual(core.mcause, 7, "défaut de rangement")
        XCTAssertTrue(trapped)
    }

    /// The atomics do their own bounds check, on their own line, and it is the
    /// one the sweep found held by nothing — the ordinary load and store
    /// checks sit elsewhere in the file and cover neither.
    func testAnAtomicPastRAMTrapsToo() {
        execute(amoadd(3, 2, 1), [1: RV32Core.ramBase &+ ramSize &+ 0x100, 2: 1])
        XCTAssertEqual(core.mcause, 7, "l'accès atomique hors RAM est un défaut de rangement")
        XCTAssertTrue(trapped)
    }

    /// **What `mtval` is for.** On a fault that has an address, it carries the
    /// address; on one that does not, it carries the program counter. A handler
    /// reading it needs to know which, and an implementation that always wrote
    /// the PC would look right to any test that only ever faulted on an illegal
    /// instruction.
    func testTheFaultRegisterCarriesTheAddressOnlyWhenThereIsOne() {
        let outside = RV32Core.ramBase &+ ramSize &+ 0x100

        execute(lw(3, 0, 1), [1: outside])
        XCTAssertEqual(core.mtval, outside, "un défaut d'adresse porte l'adresse")

        execute(0xFFFF_FFFF)
        XCTAssertEqual(core.mcause, 2, "instruction illégale")
        XCTAssertEqual(core.mtval, RV32Core.ramBase, "et celui-là porte le curseur")
    }

    // MARK: - The instructions that stop the hart

    /// `EBREAK`. Its cause is what a debugger watches for, and it is one number
    /// away from the two `ECALL` causes on either side of it.
    func testBreakpointTrapsWithItsOwnCause() {
        execute(0x0010_0073)
        XCTAssertEqual(core.mcause, 3, "EBREAK")
        XCTAssertTrue(trapped)
    }

    /// `WFI` does three things at once, and the sweep found the first held by
    /// nothing: it parks the hart, it opens the interrupt gate so the timer can
    /// wake it, and it steps past itself so the hart does not re-park on resume.
    /// A hart that returned `.waiting` without recording it would run this
    /// instruction again, for ever.
    func testWaitForInterruptParksTheHartAndOpensTheGate() {
        let outcome = execute(0x1050_0073)
        XCTAssertEqual(outcome, .waiting)
        XCTAssertEqual(core.extraflags & 4, 4, "le hart est endormi")
        XCTAssertEqual(core.mstatus & 8, 8, "et les interruptions sont ouvertes")
        XCTAssertEqual(core.pc, RV32Core.ramBase + 4, "le curseur a dépassé l'instruction")

        // Et il reste endormi tant que rien ne le réveille.
        XCTAssertEqual(core.step(elapsedMicroseconds: 0, count: 1), .waiting)
    }

    /// The timer is the only thing that can wake it, and it does: a step whose
    /// virtual clock passes `mtimecmp` clears the sleep flag.
    func testTheTimerWakesASleepingHart() {
        core.timermatchl = 100
        _ = execute(0x1050_0073)
        XCTAssertEqual(core.extraflags & 4, 4)

        _ = core.step(elapsedMicroseconds: 1_000, count: 1)
        XCTAssertEqual(core.extraflags & 4, 0, "le minuteur a réveillé le hart")
    }

    // MARK: - Two small rules with no other cover

    /// `JALR` clears the low bit of its computed target. An odd address is not
    /// an error the spec wants reported — it is one the instruction is defined
    /// to round away, and the misaligned-PC trap above is what would fire
    /// instead if it did not.
    func testJumpAndLinkRegisterClearsTheLowBitOfItsTarget() {
        execute(jalr(1, 2, 5), [2: RV32Core.ramBase &+ 0x40])
        XCTAssertEqual(core.pc, RV32Core.ramBase &+ 0x44, "0x45 arrondi à 0x44")
        XCTAssertEqual(core.regs[1], RV32Core.ramBase &+ 4, "et l'adresse de retour est posée")
        XCTAssertFalse(trapped, "pas de piège pour un bit de poids faible")
    }

    /// A fence is a no-op here — one hart, no reordering to undo — but a no-op
    /// that writes its destination register is not a no-op. The encoding has a
    /// destination field, and the instruction must leave it alone.
    func testAFenceLeavesItsDestinationRegisterAlone() {
        let fence: UInt32 = (1 << 7) | 0x0F         // rd = x1
        execute(fence, [1: 0xFEED_FACE])
        XCTAssertEqual(core.regs[1], 0xFEED_FACE, "la barrière n'écrit pas rd")
        XCTAssertFalse(trapped)
    }
}
