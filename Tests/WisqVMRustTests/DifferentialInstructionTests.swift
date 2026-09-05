import Foundation
import WisqVM
import WisqVMRust
import XCTest

/// The two cores, compared on instructions chosen rather than on a kernel boot.
///
/// `DifferentialBootTests` compares them exactly — same retired count, same
/// console bytes, byte-identical snapshots — but only over what a Linux kernel
/// happens to execute on its way to a login prompt and a shell command. A sweep
/// measured how far that reaches: of the hundred and six arms in the decoder,
/// sabotaging the Swift core makes the comparison notice sixty-six, the compiler
/// catch six, and **thirty-two nothing at all**. A Swift core that got
/// `AMOMINU`, division by zero or the contents of `mtval` wrong would still be
/// declared in agreement with the Rust one.
///
/// The thirty-two are the same shape as ever: what a healthy kernel has no
/// reason to traverse. So this file does not boot anything. Each case is a
/// handful of hand-encoded words, loaded into both cores, run to the same
/// budget, and compared two ways.
///
/// **How a wrong program is caught.** Comparing two cores answers "do they
/// agree", never "are they right" — two identical mistakes agree, and so does a
/// program that traps on its first instruction. So every guest here *emits a
/// byte to the UART*, chosen so that the expected value is distinctive, and the
/// test asserts that byte as well as the agreement. A mis-encoded program then
/// prints nothing, or the wrong thing, instead of quietly passing.
///
/// **Why this can exist now.** A guest that parks itself used to make `run`
/// spin for ever, so a differential harness could not safely be handed
/// arbitrary programs. Both cores now return when a parked hart cannot be woken
/// — see `ParkedHartTests` — which is what makes a bounded budget enough.
final class DifferentialInstructionTests: XCTestCase {
    private final class Console: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes = Data()
        func append(_ chunk: Data) { lock.lock(); bytes.append(chunk); lock.unlock() }
        var snapshot: Data { lock.lock(); defer { lock.unlock() }; return bytes }
    }

    // MARK: - Encoders
    //
    // Duplicated from the witness files in `Tests/WisqVMTests` rather than
    // shared: that target and this one are separate, and adding a product to
    // the package manifest so two test files can share eight one-line functions
    // is a worse trade than the eight lines.

    private static let uart: UInt32 = 0x1000_0000

    private func lui(_ rd: Int, _ imm20: UInt32) -> UInt32 {
        (imm20 << 12) | (UInt32(rd) << 7) | 0x37
    }
    private func addi(_ rd: Int, _ rs1: Int, _ imm: Int32) -> UInt32 {
        (UInt32(bitPattern: imm) << 20) | (UInt32(rs1) << 15) | (UInt32(rd) << 7) | 0x13
    }
    private func rtype(
        _ funct7: UInt32, _ rs2: Int, _ rs1: Int, _ funct3: UInt32, _ rd: Int
    ) -> UInt32 {
        (funct7 << 25) | (UInt32(rs2) << 20) | (UInt32(rs1) << 15) | (funct3 << 12)
            | (UInt32(rd) << 7) | 0x33
    }
    private func muldiv(_ funct3: UInt32, _ rd: Int, _ rs1: Int, _ rs2: Int) -> UInt32 {
        rtype(1, rs2, rs1, funct3, rd)
    }
    private func amo(_ funct5: UInt32, _ rd: Int, _ rs2: Int, _ rs1: Int) -> UInt32 {
        (funct5 << 27) | (UInt32(rs2) << 20) | (UInt32(rs1) << 15) | (2 << 12)
            | (UInt32(rd) << 7) | 0x2F
    }
    private func csr(_ number: UInt32, _ rs1: UInt32, _ funct3: UInt32, _ rd: Int) -> UInt32 {
        (number << 20) | (rs1 << 15) | (funct3 << 12) | (UInt32(rd) << 7) | 0x73
    }
    private func store(_ width: UInt32, _ rs2: Int, _ offset: Int32, _ rs1: Int) -> UInt32 {
        let imm = UInt32(bitPattern: offset)
        return ((imm >> 5) << 25) | (UInt32(rs2) << 20) | (UInt32(rs1) << 15) | (width << 12)
            | ((imm & 0x1F) << 7) | 0x23
    }
    /// `beq x0, x0, 0` — spins here, quietly, for the rest of the budget.
    private let spin: UInt32 = 0x0000_0063

    /// Emits the low byte of `register` to the UART, then spins. `x1` must
    /// already hold the UART's address.
    private func emitAndSpin(_ register: Int) -> [UInt32] {
        [store(0, register, 0, 1), spin]
    }

    private func image(_ program: [UInt32]) -> Data {
        var data = Data()
        for word in program {
            withUnsafeBytes(of: word.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    // MARK: - The comparison

    /// Runs one program through both cores and holds them to the same answer.
    ///
    /// Three assertions, and each catches something the others do not: the byte
    /// says the program ran and computed what it was meant to; the retired count
    /// says they took the same number of instructions to get there; the snapshot
    /// says every register, every CSR and every byte of RAM match — which is the
    /// only one that would notice a divergence the program does not print.
    private func bothCoresAgree(
        _ label: String,
        _ program: [UInt32],
        emits expected: UInt8,
        budget: UInt64 = 8192,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let bytes = image(program)
        let swiftConsole = Console()
        let rustConsole = Console()
        let swiftMachine = LinuxMachine { swiftConsole.append($0) }
        let rustMachine = RustLinuxMachine { rustConsole.append($0) }

        do {
            try swiftMachine.load(kernelImage: bytes)
            try rustMachine.loadOnTheSameBoard(kernelImage: bytes)
        } catch {
            return XCTFail("\(label) : chargement impossible — \(error)", file: file, line: line)
        }

        swiftMachine.run(instructionBudget: budget)
        rustMachine.run(instructionBudget: budget)

        XCTAssertEqual(
            Array(swiftConsole.snapshot), [expected],
            "\(label) : le cœur Swift doit émettre l'octet attendu", file: file, line: line
        )
        XCTAssertEqual(
            swiftConsole.snapshot, rustConsole.snapshot,
            "\(label) : les deux cœurs doivent émettre les mêmes octets", file: file, line: line
        )
        XCTAssertEqual(
            swiftMachine.retiredInstructions, rustMachine.retiredInstructions,
            "\(label) : même nombre d'instructions retirées", file: file, line: line
        )
        XCTAssertEqual(
            swiftMachine.snapshot(), rustMachine.snapshot(),
            "\(label) : l'état des deux machines doit être identique octet pour octet",
            file: file, line: line
        )
    }

    /// `lui x1, 0x10000` — the UART, which every program below writes to.
    private var uartInX1: UInt32 { lui(1, Self.uart >> 12) }

    // MARK: - The multiplier's three signednesses

    func testTheHighMultipliesAgree() {
        // x2 = -65536, x3 = 0x8000_0000. The three high words differ, and each
        // low byte is distinctive.
        let setup = [
            uartInX1,
            lui(2, 0xFFFF_0000 >> 12),          // x2 = 0xFFFF_0000
            lui(3, 0x8000_0000 >> 12),          // x3 = 0x8000_0000
        ]
        // MULH → 0x0000_8000, MULHSU → 0xFFFF_8000, MULHU → 0x7FFF_8000. Their
        // low bytes are all 0x00, so the byte emitted is byte 1, isolated with a
        // shift — otherwise the three would be indistinguishable on the wire.
        for (funct3, expected, name) in [
            (UInt32(1), UInt8(0x80), "MULH"),
            (UInt32(2), UInt8(0x80), "MULHSU"),
            (UInt32(3), UInt8(0x80), "MULHU"),
        ] {
            bothCoresAgree(
                name,
                setup + [
                    muldiv(funct3, 4, 2, 3),
                    // srli x4, x4, 8 — bring byte 1 down where `sb` can see it.
                    (8 << 20) | (4 << 15) | (5 << 12) | (4 << 7) | 0x13,
                ] + emitAndSpin(4),
                emits: expected
            )
        }
    }

    /// The byte above is the same for all three, which proves they ran but not
    /// that they differ. The snapshot is what separates them — so this asks the
    /// question the byte cannot: three programs, three different machine states.
    func testTheHighMultipliesDoNotAgreeWithEachOther() {
        let setup = [uartInX1, lui(2, 0xFFFF_0000 >> 12), lui(3, 0x8000_0000 >> 12)]
        var states: [Data] = []
        for funct3 in [UInt32(1), UInt32(2), UInt32(3)] {
            let machine = LinuxMachine { _ in }
            try? machine.load(
                kernelImage: image(setup + [muldiv(funct3, 4, 2, 3)] + emitAndSpin(4)))
            machine.run(instructionBudget: 8192)
            states.append(machine.snapshot())
        }
        XCTAssertNotEqual(states[0], states[1], "MULH et MULHSU doivent différer")
        XCTAssertNotEqual(states[1], states[2], "MULHSU et MULHU doivent différer")
        XCTAssertNotEqual(states[0], states[2], "MULH et MULHU doivent différer")
    }

    // MARK: - Division's invented answers

    func testDivisionByZeroAgrees() {
        // 7 / 0 = all ones; its low byte is 0xFF, which no other case here emits.
        bothCoresAgree(
            "DIV par zéro",
            [uartInX1, addi(2, 0, 7), addi(3, 0, 0), muldiv(4, 4, 2, 3)] + emitAndSpin(4),
            emits: 0xFF
        )
        bothCoresAgree(
            "DIVU par zéro",
            [uartInX1, addi(2, 0, 7), addi(3, 0, 0), muldiv(5, 4, 2, 3)] + emitAndSpin(4),
            emits: 0xFF
        )
    }

    func testRemainderByZeroAgrees() {
        // The remainder's answer is the dividend, which is a different choice
        // from the quotient's and the one an implementation gets wrong by
        // reusing the all-ones it just wrote next door.
        bothCoresAgree(
            "REM par zéro",
            [uartInX1, addi(2, 0, 0x5B), addi(3, 0, 0), muldiv(6, 4, 2, 3)] + emitAndSpin(4),
            emits: 0x5B
        )
        bothCoresAgree(
            "REMU par zéro",
            [uartInX1, addi(2, 0, 0x5B), addi(3, 0, 0), muldiv(7, 4, 2, 3)] + emitAndSpin(4),
            emits: 0x5B
        )
    }

    func testTheOverflowingSignedDivisionAgrees() {
        // INT_MIN / -1: the one signed quotient that does not fit. The answer is
        // the dividend, so the low byte is zero; the remainder's is zero too, so
        // the two are told apart by the snapshot rather than the byte.
        let setup = [uartInX1, lui(2, 0x8000_0000 >> 12), addi(3, 0, -1)]
        bothCoresAgree("DIV débordant", setup + [muldiv(4, 4, 2, 3)] + emitAndSpin(4), emits: 0)
        bothCoresAgree("REM débordant", setup + [muldiv(6, 4, 2, 3)] + emitAndSpin(4), emits: 0)
    }

    // MARK: - The atomics a kernel does not reach

    /// A cell in RAM the atomics work on, well clear of the program.
    private var cellInX5: [UInt32] { [lui(5, 0x8000_1000 >> 12)] }

    func testTheAtomicsAgree() {
        // The cell starts at -1 and the register holds 1, which is the pair that
        // separates signed from unsigned on all four min/max.
        let setup = [uartInX1] + cellInX5 + [
            addi(6, 0, -1),
            store(2, 6, 0, 5),          // sw x6, 0(x5) — the cell is now -1
            addi(6, 0, 1),
        ]
        for (funct5, expected, name) in [
            (UInt32(4), UInt8(0xFE), "AMOXOR"),     // -1 ^ 1 = 0xFFFF_FFFE
            (UInt32(16), UInt8(0xFF), "AMOMIN"),    // signed: -1 wins
            (UInt32(24), UInt8(0x01), "AMOMINU"),   // unsigned: 1 wins
            (UInt32(20), UInt8(0x01), "AMOMAX"),    // signed: 1 wins
            (UInt32(28), UInt8(0xFF), "AMOMAXU"),   // unsigned: 0xFFFF_FFFF wins
        ] {
            bothCoresAgree(
                name,
                setup + [
                    amo(funct5, 7, 6, 5),
                    // lw x8, 0(x5) — read back what the atomic left in the cell.
                    (5 << 15) | (2 << 12) | (8 << 7) | 0x03,
                ] + emitAndSpin(8),
                emits: expected
            )
        }
    }

    /// **The other order, and the reason it is not optional.**
    ///
    /// In the pair above, `AMOMINU` and `AMOMAX` both answer with the register
    /// — which is exactly what an arm that computed nothing leaves in place and
    /// stores. Both survived the counter-check on that pair alone, and this is
    /// the second time the same mistake has been made in this repository: the
    /// witness file next door was corrected for it and the lesson did not carry
    /// across. So each of the four is asked once more with the cell holding the
    /// answer, which no amount of doing nothing produces.
    func testTheAtomicMinMaxWhenTheCellWins() {
        for (funct5, cell, register, expected, name) in [
            (UInt32(16), Int32(3), Int32(8), UInt8(3), "AMOMIN, cellule gagnante"),
            (UInt32(24), Int32(3), Int32(8), UInt8(3), "AMOMINU, cellule gagnante"),
            (UInt32(20), Int32(8), Int32(3), UInt8(8), "AMOMAX, cellule gagnante"),
            (UInt32(28), Int32(8), Int32(3), UInt8(8), "AMOMAXU, cellule gagnante"),
        ] {
            let program = [uartInX1] + cellInX5 + [
                addi(6, 0, cell),
                store(2, 6, 0, 5),
                addi(6, 0, register),
                amo(funct5, 7, 6, 5),
                (5 << 15) | (2 << 12) | (8 << 7) | 0x03,   // lw x8, 0(x5)
            ] + emitAndSpin(8)
            bothCoresAgree(name, program, emits: expected)
        }
    }

    /// A store-conditional on an address nobody reserved must fail *and* leave
    /// memory alone. The byte is what the cell still holds, so a core that wrote
    /// anyway prints the other value.
    func testAStaleStoreConditionalAgrees() {
        let program = [uartInX1] + cellInX5 + [
            addi(6, 0, 0x2A),
            store(2, 6, 0, 5),                      // the cell holds 0x2A
            lui(9, 0x8000_2000 >> 12),              // a different cell
            amo(2, 10, 0, 9),                       // lr.w on that other one
            addi(6, 0, 0x7B),
            amo(3, 11, 6, 5),                       // sc.w here: no reservation
            (5 << 15) | (2 << 12) | (8 << 7) | 0x03,  // lw x8, 0(x5)
        ] + emitAndSpin(8)
        bothCoresAgree("SC.W périmé", program, emits: 0x2A)
    }

    // MARK: - The registers the machine keeps about itself

    func testTheIdentityRegistersAgree() {
        // misa says RV32 with I, M and A. Its low byte is 0x01, and a core that
        // answered zero for an unknown number would print zero.
        bothCoresAgree(
            "misa",
            [uartInX1, csr(0x301, 0, 2, 4)] + emitAndSpin(4),
            emits: 0x01
        )
        bothCoresAgree(
            "mvendorid",
            [uartInX1, csr(0xF11, 0, 2, 4)] + emitAndSpin(4),
            emits: 0xFF
        )
    }

    /// The micro-operations, on a register the machine does not otherwise touch.
    /// `CSRRWI` and `CSRRCI` take their operand from the register *field*, so
    /// loading the register it names with something else is what tells the two
    /// forms apart.
    func testTheCSRMicroOperationsAgree() {
        bothCoresAgree(
            "CSRRW puis relecture",
            [uartInX1, addi(2, 0, 0x33), csr(0x340, 2, 1, 0), csr(0x340, 0, 2, 4)]
                + emitAndSpin(4),
            emits: 0x33
        )
        bothCoresAgree(
            "CSRRC efface les bits",
            [
                uartInX1, addi(2, 0, 0x3F), csr(0x340, 2, 1, 0),
                addi(3, 0, 0x0F), csr(0x340, 3, 3, 0), csr(0x340, 0, 2, 4),
            ] + emitAndSpin(4),
            emits: 0x30
        )
        bothCoresAgree(
            "CSRRWI prend le champ, pas le registre",
            [uartInX1, addi(5, 0, 0x7F), csr(0x340, 5, 5, 0), csr(0x340, 0, 2, 4)]
                + emitAndSpin(4),
            emits: 0x05
        )
        bothCoresAgree(
            "CSRRCI de même",
            [
                uartInX1, addi(2, 0, 0x1F), csr(0x340, 2, 1, 0),
                addi(5, 0, 0x7F), csr(0x340, 5, 7, 0), csr(0x340, 0, 2, 4),
            ] + emitAndSpin(4),
            emits: 0x1A
        )
    }

    /// The machine registers a boot writes and never reads back, each written
    /// then re-read through its own number. A number mistyped in one core's
    /// switch and not the other's lands the value in a neighbour, which is
    /// invisible to anything that only writes.
    ///
    /// `mip` is written below bit 7 on purpose: bit 7 is `MTIP`, which the hart
    /// republishes from the clock at the top of every step, so a guest's value
    /// there does not survive the next instruction.
    func testTheMachineRegistersRoundTripTheSameWay() {
        for (number, value, name) in [
            (UInt32(0x305), Int32(0x40), "mtvec"),
            (UInt32(0x344), Int32(0x0F), "mip"),
            (UInt32(0x342), Int32(0x51), "mcause"),
            (UInt32(0x343), Int32(0x62), "mtval"),
        ] {
            bothCoresAgree(
                "aller-retour \(name)",
                [uartInX1, addi(2, 0, value), csr(number, 2, 1, 0), csr(number, 0, 2, 4)]
                    + emitAndSpin(4),
                emits: UInt8(value)
            )
        }
    }

    /// `cycle` is not stored, it counts. Read twice with a known number of
    /// instructions between, the difference is that number — and a core that
    /// answered a constant would emit zero.
    func testTheCycleCounterCountsTheSameOnBothCores() {
        bothCoresAgree(
            "cycle avance",
            [
                uartInX1,
                csr(0xC00, 0, 2, 2),          // x2 = cycle
                addi(0, 0, 0), addi(0, 0, 0), addi(0, 0, 0),
                csr(0xC00, 0, 2, 3),          // x3 = cycle, four instructions later
                rtype(0x20, 2, 3, 0, 4),      // sub x4, x3, x2
            ] + emitAndSpin(4),
            emits: 4
        )
    }

    /// A fence is a no-op here, but a no-op that writes its destination register
    /// is not a no-op — and the encoding has a destination field.
    func testAFenceLeavesItsDestinationAloneOnBothCores() {
        let fenceIntoX4: UInt32 = (4 << 7) | 0x0F
        bothCoresAgree(
            "FENCE n'écrit pas rd",
            [uartInX1, addi(4, 0, 0x5A), fenceIntoX4] + emitAndSpin(4),
            emits: 0x5A
        )
    }

    /// `JALR` clears the low bit of its computed target. Jumping to an odd
    /// address must land on the even one below it and carry on; a core that kept
    /// the bit would take a misaligned-instruction trap instead and emit
    /// nothing.
    func testJumpAndLinkRegisterRoundsTheSameWay() {
        // x2 = ramBase; jalr x0, 21(x2) → 0x…15, rounded to 0x…14, which is
        // word five: the emit.
        var program = [
            uartInX1,
            lui(2, RV32Core.ramBase >> 12),
            addi(3, 0, 0x3C),
            // 21, odd on purpose: the comment above says 21 and an earlier
            // version of this line said 20, which made the target even and the
            // mask under test unreachable. The counter-check found it.
            (UInt32(bitPattern: Int32(21)) << 20) | (2 << 15) | (0 << 7) | 0x67,
            spin,
        ]
        XCTAssertEqual(program.count, 5, "l'émission doit tomber au mot cinq")
        program += emitAndSpin(3)
        bothCoresAgree("JALR arrondit sa cible", program, emits: 0x3C)
    }

    // MARK: - The faults

    /// A trap has to land in the guest's own handler with the right cause, in
    /// both cores. The handler is four instructions at a known address: read
    /// `mcause`, emit it, spin.
    private func trapping(_ offender: [UInt32], vector: UInt32 = 0x100) -> [UInt32] {
        var program = [uartInX1, lui(2, (RV32Core.ramBase &+ vector) >> 12)]
        program.append(addi(2, 2, Int32(vector & 0xFFF)))
        program.append(csr(0x305, 2, 1, 0))            // mtvec = ramBase + vector
        program += offender
        program.append(spin)
        // Pad out to the vector, then the handler.
        while program.count * 4 < Int(vector) { program.append(spin) }
        program.append(csr(0x342, 0, 2, 4))            // x4 = mcause
        program += emitAndSpin(4)
        return program
    }

    func testTheFaultCausesAgree() {
        bothCoresAgree(
            "instruction illégale",
            trapping([0xFFFF_FFFF]),
            emits: 2
        )
        // A load from past the end of RAM, which is a different cause from a
        // store to the same place — the distinction a handler needs and the one
        // a boot never exercises.
        bothCoresAgree(
            "défaut de chargement",
            trapping([lui(6, 0x8FFF_0000 >> 12), (6 << 15) | (2 << 12) | (7 << 7) | 0x03]),
            emits: 5
        )
        bothCoresAgree(
            "défaut de rangement",
            trapping([lui(6, 0x8FFF_0000 >> 12), store(2, 0, 0, 6)]),
            emits: 7
        )
        bothCoresAgree(
            "EBREAK",
            trapping([0x0010_0073]),
            emits: 3
        )
        // The atomics check their own bounds, on their own line, and neither
        // the load nor the store check above covers it.
        bothCoresAgree(
            "AMO hors RAM",
            trapping([lui(6, 0x8FFF_0000 >> 12), amo(0, 7, 0, 6)]),
            emits: 7
        )
        // Jumping off the end of RAM: an instruction access fault, which is a
        // third cause again and the one a runaway guest takes.
        bothCoresAgree(
            "PC hors RAM",
            trapping([
                lui(6, 0x8FFF_0000 >> 12),
                (6 << 15) | (0 << 7) | 0x67,          // jalr x0, 0(x6)
            ]),
            emits: 1
        )
    }

    // MARK: - Two arms this file deliberately does not reach
    //
    // A differential test drives the cores the way a guest does, which bounds
    // what it can ask them. Written here rather than as a test, because a test
    // asserting its own list is a test that cannot fail.
    //
    // *The misaligned program counter.* No instruction can produce one on a
    // correct core: `JAL`'s immediate has a zero low bit by construction and
    // `JALR` masks the low bit off. The only route is a trap vector that is
    // itself odd, and that traps on entry to its own handler, for ever, with
    // nothing left to print. So the trap is unreachable from guest code — the
    // fourth of the four diagnoses — and the only thing that can hold it is a
    // unit test that sets the program counter directly, which
    // `RV32SupervisorWitnessTests.testAMisalignedProgramCounterTrapsWithItsOwnCause`
    // does.
    //
    // *`WFI` reopening the interrupt gate.* Observing it means arming the
    // CLINT, parking, waking, and reading `mstatus` back — a program long
    // enough that what it mostly tests is the program.
    // `RV32SupervisorWitnessTests.testWaitForInterruptParksTheHartAndOpensTheGate`
    // reads the flag directly and says the same thing in three lines.

}
