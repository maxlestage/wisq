import XCTest
@testable import WisqVM

/// Instruction-level checks with hand-encoded RISC-V, run on a tiny bus.
final class RV32CoreTests: XCTestCase {
    private final class NullBus: RV32Bus {
        var loads: [UInt32] = []
        var stores: [(UInt32, UInt32)] = []
        func mmioLoad(_ address: UInt32) -> UInt32 { loads.append(address); return 0x42 }
        func mmioStore(_ address: UInt32, _ value: UInt32) -> UInt32? {
            stores.append((address, value))
            return address == 0x1110_0000 ? value : nil
        }
    }

    private var ram: UnsafeMutableRawPointer!
    private var bus: NullBus!
    private var core: RV32Core!
    private let ramSize: UInt32 = 1 << 20

    override func setUp() {
        ram = UnsafeMutableRawPointer.allocate(byteCount: Int(ramSize), alignment: 8)
        ram.initializeMemory(as: UInt8.self, repeating: 0, count: Int(ramSize))
        bus = NullBus()
        core = RV32Core(ram: ram, ramSize: ramSize, bus: bus)
        core.extraflags |= 3
    }

    override func tearDown() {
        core = nil
        ram.deallocate()
    }

    private func write(_ instructions: [UInt32], at offset: UInt32 = 0) {
        for (index, instruction) in instructions.enumerated() {
            ram.storeBytes(of: instruction, toByteOffset: Int(offset) + index * 4, as: UInt32.self)
        }
    }

    private func run(_ count: Int) {
        _ = core.step(elapsedMicroseconds: 0, count: count)
    }

    // MARK: - Encoders (the assembler we do not have)

    private func addi(_ rd: Int, _ rs1: Int, _ imm: Int32) -> UInt32 {
        (UInt32(bitPattern: imm) << 20) | (UInt32(rs1) << 15) | (0 << 12) | (UInt32(rd) << 7) | 0x13
    }
    private func lui(_ rd: Int, _ imm20: UInt32) -> UInt32 {
        (imm20 << 12) | (UInt32(rd) << 7) | 0x37
    }
    private func add(_ rd: Int, _ rs1: Int, _ rs2: Int) -> UInt32 {
        (UInt32(rs2) << 20) | (UInt32(rs1) << 15) | (UInt32(rd) << 7) | 0x33
    }
    private func mul(_ rd: Int, _ rs1: Int, _ rs2: Int) -> UInt32 {
        (1 << 25) | (UInt32(rs2) << 20) | (UInt32(rs1) << 15) | (UInt32(rd) << 7) | 0x33
    }
    private func sw(_ rs2: Int, _ offset: Int32, _ rs1: Int) -> UInt32 {
        let imm = UInt32(bitPattern: offset)
        return ((imm >> 5) << 25) | (UInt32(rs2) << 20) | (UInt32(rs1) << 15)
            | (2 << 12) | ((imm & 0x1F) << 7) | 0x23
    }
    private func lw(_ rd: Int, _ offset: Int32, _ rs1: Int) -> UInt32 {
        (UInt32(bitPattern: offset) << 20) | (UInt32(rs1) << 15) | (2 << 12) | (UInt32(rd) << 7) | 0x03
    }
    private func beq(_ rs1: Int, _ rs2: Int, _ offset: Int32) -> UInt32 {
        let imm = UInt32(bitPattern: offset)
        return ((imm >> 12) & 1) << 31 | ((imm >> 5) & 0x3F) << 25
            | UInt32(rs2) << 20 | UInt32(rs1) << 15
            | ((imm >> 1) & 0xF) << 8 | ((imm >> 11) & 1) << 7 | 0x63
    }
    private func jal(_ rd: Int, _ offset: Int32) -> UInt32 {
        let imm = UInt32(bitPattern: offset)
        return ((imm >> 20) & 1) << 31 | ((imm >> 1) & 0x3FF) << 21
            | ((imm >> 11) & 1) << 20 | ((imm >> 12) & 0xFF) << 12
            | UInt32(rd) << 7 | 0x6F
    }

    // MARK: - Tests

    func testArithmeticAndSignExtension() {
        write([
            addi(1, 0, 42),          // x1 = 42
            addi(2, 1, -50),         // x2 = -8
            add(3, 1, 2),            // x3 = 34
            mul(4, 1, 1),            // x4 = 1764
        ])
        run(4)
        XCTAssertEqual(core.regs[1], 42)
        XCTAssertEqual(Int32(bitPattern: core.regs[2]), -8)
        XCTAssertEqual(core.regs[3], 34)
        XCTAssertEqual(core.regs[4], 1764)
    }

    func testX0StaysZero() {
        write([addi(0, 0, 99), addi(1, 0, 7)])
        run(2)
        XCTAssertEqual(core.regs[0], 0)
        XCTAssertEqual(core.regs[1], 7)
    }

    func testLoadStoreRoundTrip() {
        write([
            lui(1, 0x80001),         // x1 = 0x80001000
            addi(2, 0, 0x123),
            sw(2, 0, 1),
            lw(3, 0, 1),
        ])
        run(4)
        XCTAssertEqual(core.regs[3], 0x123)
        XCTAssertEqual(ram.load(fromByteOffset: 0x1000, as: UInt32.self), 0x123)
    }

    func testBranchTakenSkipsInstructions() {
        write([
            addi(1, 0, 5),
            beq(1, 1, 8),            // taken: jump over the next instruction
            addi(2, 0, 111),         // must be skipped
            addi(3, 0, 7),
        ])
        run(4)
        XCTAssertEqual(core.regs[2], 0)
        XCTAssertEqual(core.regs[3], 7)
    }

    func testJalLinksAndJumps() {
        write([
            jal(1, 12),              // to pc+12, x1 = return address
            addi(2, 0, 1),           // skipped
            addi(2, 0, 2),           // skipped
            addi(3, 0, 9),
        ])
        run(2)
        XCTAssertEqual(core.regs[1], RV32Core.ramBase + 4)
        XCTAssertEqual(core.regs[3], 9)
    }

    func testMMIOLoadGoesToTheBus() {
        write([
            lui(1, 0x10000),         // UART base
            lw(2, 0, 1),
        ])
        run(2)
        XCTAssertEqual(core.regs[2], 0x42)
        XCTAssertEqual(bus.loads, [0x1000_0000])
    }

    func testEcallFromMachineModeTraps() {
        core.mtvec = RV32Core.ramBase + 0x100
        write([UInt32(0x0000_0073)])                 // ECALL
        run(1)
        XCTAssertEqual(core.mcause, 11, "ECALL depuis le mode machine = cause 11")
        XCTAssertEqual(core.pc, RV32Core.ramBase + 0x100)
        XCTAssertEqual(core.mepc, RV32Core.ramBase)
    }

    func testIllegalInstructionTraps() {
        core.mtvec = RV32Core.ramBase + 0x100
        write([0xFFFF_FFFF])
        run(1)
        XCTAssertEqual(core.mcause, 2)
        XCTAssertEqual(core.pc, RV32Core.ramBase + 0x100)
    }

    func testTimerInterruptFiresWhenEnabled() {
        core.mtvec = RV32Core.ramBase + 0x200
        core.mie = 1 << 7
        core.mstatus = 0x8
        core.timermatchl = 10
        write([addi(1, 0, 1), addi(1, 1, 1), addi(1, 1, 1)])

        _ = core.step(elapsedMicroseconds: 100, count: 3)   // timer already past match
        XCTAssertEqual(core.mcause, 0x8000_0007)
        XCTAssertEqual(core.pc, RV32Core.ramBase + 0x200)
    }

    /// The failure this test used to claim in its name — a store-conditional on
    /// an address nobody reserved — lives in `RV32ArithmeticWitnessTests`. A
    /// sweep found it held by nothing: make the reservation check answer
    /// *success* unconditionally and this test stayed green, because it never
    /// asked for anything but the matching pair below.
    func testLrScPairSucceeds() {
        // LR.W x2, (x1) ; SC.W x3, x4, (x1)
        let lr: UInt32 = (2 << 27) | (1 << 15) | (2 << 12) | (2 << 7) | 0x2F
        let sc: UInt32 = (3 << 27) | (4 << 20) | (1 << 15) | (2 << 12) | (3 << 7) | 0x2F
        write([
            lui(1, 0x80001),
            addi(4, 0, 77),
            lr, sc,
        ])
        run(4)
        XCTAssertEqual(core.regs[3], 0, "SC après LR sur la même adresse doit réussir")
        XCTAssertEqual(ram.load(fromByteOffset: 0x1000, as: UInt32.self), 77)
    }
}
