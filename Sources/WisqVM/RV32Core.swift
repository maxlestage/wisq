import Foundation

/// One rv32ima hart, interpreted.
///
/// This is a Swift port of the execution semantics of Charles Lohr's
/// mini-rv32ima (MIT), the smallest known machine that boots a real Linux
/// kernel: RV32 IMA + Zicsr, machine and user modes, no MMU. Interpretation is
/// the point, not a compromise — iOS grants executable memory only to
/// development-signed apps, so a JIT was never on the table, and an interpreter
/// is App Store-clean.
///
/// The core knows nothing about devices: memory-mapped I/O in
/// 0x1000_0000..<0x1200_0000 is delegated to the `RV32Bus` it runs against.
public protocol RV32Bus: AnyObject {
    func mmioLoad(_ address: UInt32) -> UInt32
    /// A non-nil return halts the machine with that code (the syscon path).
    func mmioStore(_ address: UInt32, _ value: UInt32) -> UInt32?
}

public enum RV32StepResult: Equatable {
    case ran
    /// The hart executed WFI and is waiting for an interrupt.
    case waiting
    /// A syscon write asked for shutdown (0x5555) or reboot (0x7777).
    case halted(code: UInt32)
}

/// The 32 integer registers, addressable without a bounds check.
///
/// A Swift array would be re-fetched and re-checked constantly: `regs` is a
/// public property of a class that also calls out to an opaque bus, so the
/// optimiser cannot prove the buffer survives the call and reloads it after
/// every one. At tens of millions of instructions a second that is not free.
/// The checking lives here, at the public boundary, where callers are rare;
/// the interpreter indexes the storage directly with values it has already
/// masked to 5 bits.
public struct RegisterFile {
    fileprivate let storage: UnsafeMutablePointer<UInt32>

    public subscript(index: Int) -> UInt32 {
        get {
            precondition(index >= 0 && index < 32, "registre hors bornes : \(index)")
            return storage[index]
        }
        nonmutating set {
            precondition(index >= 0 && index < 32, "registre hors bornes : \(index)")
            storage[index] = newValue
        }
    }
}

public final class RV32Core {
    public static let ramBase: UInt32 = 0x8000_0000

    // Register file. x0 is stored but never written.
    private let x: UnsafeMutablePointer<UInt32>
    public var regs: RegisterFile { RegisterFile(storage: x) }
    public var pc: UInt32 = RV32Core.ramBase

    // Machine CSRs.
    public var mstatus: UInt32 = 0
    public var cyclel: UInt32 = 0
    public var cycleh: UInt32 = 0
    public var timerl: UInt32 = 0
    public var timerh: UInt32 = 0
    public var timermatchl: UInt32 = 0
    public var timermatchh: UInt32 = 0
    public var mscratch: UInt32 = 0
    public var mtvec: UInt32 = 0
    public var mie: UInt32 = 0
    public var mip: UInt32 = 0
    public var mepc: UInt32 = 0
    public var mtval: UInt32 = 0
    public var mcause: UInt32 = 0
    /// Bits 0..1: privilege (3 = machine, 0 = user). Bit 2: WFI.
    /// Bits 3+: load-reservation address, for LR/SC.
    public var extraflags: UInt32 = 0

    private let ram: UnsafeMutableRawPointer
    private let ramSize: UInt32
    private unowned let bus: any RV32Bus

    public init(ram: UnsafeMutableRawPointer, ramSize: UInt32, bus: any RV32Bus) {
        self.ram = ram
        self.ramSize = ramSize
        self.bus = bus
        self.x = .allocate(capacity: 32)
        self.x.initialize(repeating: 0, count: 32)
    }

    deinit {
        x.deinitialize(count: 32)
        x.deallocate()
    }

    // MARK: - Memory (little-endian, like the host)

    @inline(__always) private func load32(_ offset: UInt32) -> UInt32 {
        ram.loadUnaligned(fromByteOffset: Int(offset), as: UInt32.self)
    }
    @inline(__always) private func load16(_ offset: UInt32) -> UInt16 {
        ram.loadUnaligned(fromByteOffset: Int(offset), as: UInt16.self)
    }
    @inline(__always) private func load8(_ offset: UInt32) -> UInt8 {
        ram.load(fromByteOffset: Int(offset), as: UInt8.self)
    }
    @inline(__always) private func store32(_ offset: UInt32, _ value: UInt32) {
        ram.storeBytes(of: value, toByteOffset: Int(offset), as: UInt32.self)
    }
    @inline(__always) private func store16(_ offset: UInt32, _ value: UInt16) {
        ram.storeBytes(of: value, toByteOffset: Int(offset), as: UInt16.self)
    }
    @inline(__always) private func store8(_ offset: UInt32, _ value: UInt8) {
        ram.storeBytes(of: value, toByteOffset: Int(offset), as: UInt8.self)
    }

    @inline(__always) private static func isMMIO(_ address: UInt32) -> Bool {
        (0x1000_0000..<0x1200_0000).contains(address)
    }

    // MARK: - Immediates
    //
    // Every RISC-V immediate is sign-extended from its top bit. Testing that
    // bit and OR-ing in the fill costs a branch on the three hottest opcode
    // groups; an arithmetic shift of the whole instruction word produces the
    // same fill with no branch at all, because `ir`'s bit 31 *is* the sign bit
    // of every immediate format that has one.

    /// I-type: ir[31:20], sign-extended. Loads, JALR, OP-IMM.
    @inline(__always) private static func immI(_ ir: UInt32) -> UInt32 {
        UInt32(bitPattern: Int32(bitPattern: ir) >> 20)
    }

    /// S-type: ir[31:25] | ir[11:7], sign-extended. Stores.
    @inline(__always) private static func immS(_ ir: UInt32) -> UInt32 {
        (immI(ir) & ~0x1F) | ((ir >> 7) & 0x1F)
    }

    /// B-type: the branch displacement, sign-extended. Bit 0 is always zero.
    @inline(__always) private static func immB(_ ir: UInt32) -> UInt32 {
        UInt32(bitPattern: (Int32(bitPattern: ir) >> 31) << 12)
            | ((ir & 0x80) << 4) | ((ir >> 20) & 0x7E0) | ((ir >> 7) & 0x1E)
    }

    /// J-type: the JAL displacement, sign-extended. Bit 0 is always zero.
    @inline(__always) private static func immJ(_ ir: UInt32) -> UInt32 {
        UInt32(bitPattern: (Int32(bitPattern: ir) >> 31) << 20)
            | (ir & 0x000F_F000) | ((ir & 0x0010_0000) >> 9) | ((ir & 0x7FE0_0000) >> 20)
    }

    // MARK: - Execution

    /// Advances the virtual timer, then runs up to `count` instructions.
    ///
    /// Mirrors the reference implementation instruction for instruction; where
    /// the behaviour looks odd (the `pc - 4` dance around traps, mepc pointing
    /// at the faulting instruction), it is what the kernel expects.
    public func step(elapsedMicroseconds: UInt32, count: Int) -> RV32StepResult {
        // A hart in WFI retires nothing until an interrupt arrives, and the
        // only interrupt this machine can raise is the timer — whose firing
        // moment is already written in mtimecmp. Creeping toward it in 64 µs
        // hops costs real CPU, and on a phone real battery, to reach an instant
        // we can already name. Jump to it.
        if extraflags & 4 != 0, timermatchh != 0 || timermatchl != 0 {
            let now = (UInt64(timerh) << 32) | UInt64(timerl)
            let match = (UInt64(timermatchh) << 32) | UInt64(timermatchl)
            if now < match {
                timerh = UInt32(truncatingIfNeeded: match >> 32)
                timerl = UInt32(truncatingIfNeeded: match)
            }
        }

        let newTimer = timerl &+ elapsedMicroseconds
        if newTimer < timerl { timerh &+= 1 }
        timerl = newTimer

        if timerh > timermatchh || (timerh == timermatchh && timerl > timermatchl),
           timermatchh != 0 || timermatchl != 0 {
            extraflags &= ~4                     // wake from WFI
            mip |= 1 << 7                        // MTIP
        } else {
            mip &= ~(1 << 7)
        }

        if extraflags & 4 != 0 { return .waiting }

        var trap: UInt32 = 0
        var rval: UInt32 = 0
        var pc = self.pc
        var cycle = cyclel

        if (mip & (1 << 7)) != 0, (mie & (1 << 7)) != 0, (mstatus & 0x8) != 0 {
            // Timer interrupt fires between instructions.
            trap = 0x8000_0007
            pc &-= 4
        } else {
            instructionLoop: for _ in 0..<count {
                rval = 0
                cycle &+= 1
                let offsetPC = pc &- Self.ramBase

                if offsetPC >= ramSize {
                    trap = 1 + 1                 // instruction access fault
                    break
                }
                if offsetPC & 3 != 0 {
                    trap = 1 + 0                 // misaligned PC
                    break
                }

                let ir = load32(offsetPC)
                var rdid = (ir >> 7) & 0x1F

                switch ir & 0x7F {
                case 0x37:                       // LUI
                    rval = ir & 0xFFFF_F000

                case 0x17:                       // AUIPC
                    rval = pc &+ (ir & 0xFFFF_F000)

                case 0x6F:                       // JAL
                    rval = pc &+ 4
                    pc = pc &+ Self.immJ(ir) &- 4

                case 0x67:                       // JALR
                    rval = pc &+ 4
                    pc = ((x[Int((ir >> 15) & 0x1F)] &+ Self.immI(ir)) & ~1) &- 4

                case 0x63:                       // branches
                    let imm = Self.immB(ir)
                    let rs1 = Int32(bitPattern: x[Int((ir >> 15) & 0x1F)])
                    let rs2 = Int32(bitPattern: x[Int((ir >> 20) & 0x1F)])
                    let target = pc &+ imm &- 4
                    rdid = 0
                    switch (ir >> 12) & 0x7 {
                    case 0: if rs1 == rs2 { pc = target }
                    case 1: if rs1 != rs2 { pc = target }
                    case 4: if rs1 < rs2 { pc = target }
                    case 5: if rs1 >= rs2 { pc = target }
                    case 6: if UInt32(bitPattern: rs1) < UInt32(bitPattern: rs2) { pc = target }
                    case 7: if UInt32(bitPattern: rs1) >= UInt32(bitPattern: rs2) { pc = target }
                    default: trap = 2 + 1
                    }

                case 0x03:                       // loads
                    let rs1 = x[Int((ir >> 15) & 0x1F)]
                    var address = rs1 &+ Self.immI(ir) &- Self.ramBase
                    if address >= ramSize &- 3 {
                        address &+= Self.ramBase
                        if Self.isMMIO(address) {
                            rval = bus.mmioLoad(address)
                        } else {
                            trap = 5 + 1         // load access fault
                            rval = address
                        }
                    } else {
                        switch (ir >> 12) & 0x7 {
                        case 0: rval = UInt32(bitPattern: Int32(Int8(bitPattern: load8(address))))
                        case 1: rval = UInt32(bitPattern: Int32(Int16(bitPattern: load16(address))))
                        case 2: rval = load32(address)
                        case 4: rval = UInt32(load8(address))
                        case 5: rval = UInt32(load16(address))
                        default: trap = 2 + 1
                        }
                    }

                case 0x23:                       // stores
                    let rs1 = x[Int((ir >> 15) & 0x1F)]
                    let rs2 = x[Int((ir >> 20) & 0x1F)]
                    var address = Self.immS(ir) &+ rs1 &- Self.ramBase
                    rdid = 0
                    if address >= ramSize &- 3 {
                        address &+= Self.ramBase
                        if Self.isMMIO(address) {
                            if let halt = bus.mmioStore(address, rs2) {
                                // Syscon: the reference advances PC before halting.
                                self.pc = pc &+ 4
                                syncCycles(cycle)
                                return .halted(code: halt)
                            }
                        } else {
                            trap = 7 + 1         // store access fault
                            rval = address
                        }
                    } else {
                        switch (ir >> 12) & 0x7 {
                        case 0: store8(address, UInt8(truncatingIfNeeded: rs2))
                        case 1: store16(address, UInt16(truncatingIfNeeded: rs2))
                        case 2: store32(address, rs2)
                        default: trap = 2 + 1
                        }
                    }

                case 0x13, 0x33:                 // ALU, immediate and register forms
                    let imm = Self.immI(ir)
                    let rs1 = x[Int((ir >> 15) & 0x1F)]
                    let isReg = ir & 0x20 != 0
                    let rs2 = isReg ? x[Int(imm & 0x1F)] : imm

                    if isReg, ir & 0x0200_0000 != 0 {
                        // RV32M
                        let s1 = Int32(bitPattern: rs1)
                        let s2 = Int32(bitPattern: rs2)
                        switch (ir >> 12) & 7 {
                        case 0: rval = rs1 &* rs2
                        case 1: rval = UInt32(truncatingIfNeeded: (Int64(s1) * Int64(s2)) >> 32)
                        case 2: rval = UInt32(truncatingIfNeeded: (Int64(s1) * Int64(UInt64(rs2))) >> 32)
                        case 3: rval = UInt32(truncatingIfNeeded: (UInt64(rs1) * UInt64(rs2)) >> 32)
                        case 4:
                            if rs2 == 0 {
                                rval = 0xFFFF_FFFF
                            } else if s1 == Int32.min && s2 == -1 {
                                rval = rs1
                            } else {
                                rval = UInt32(bitPattern: s1 / s2)
                            }
                        case 5: rval = rs2 == 0 ? 0xFFFF_FFFF : rs1 / rs2
                        case 6:
                            if rs2 == 0 {
                                rval = rs1
                            } else if s1 == Int32.min && s2 == -1 {
                                rval = 0
                            } else {
                                rval = UInt32(bitPattern: s1 % s2)
                            }
                        case 7: rval = rs2 == 0 ? rs1 : rs1 % rs2
                        default: break
                        }
                    } else {
                        switch (ir >> 12) & 7 {
                        case 0: rval = (isReg && ir & 0x4000_0000 != 0) ? rs1 &- rs2 : rs1 &+ rs2
                        case 1: rval = rs1 << (rs2 & 0x1F)
                        case 2: rval = Int32(bitPattern: rs1) < Int32(bitPattern: rs2) ? 1 : 0
                        case 3: rval = rs1 < rs2 ? 1 : 0
                        case 4: rval = rs1 ^ rs2
                        case 5:
                            rval = ir & 0x4000_0000 != 0
                                ? UInt32(bitPattern: Int32(bitPattern: rs1) >> (rs2 & 0x1F))
                                : rs1 >> (rs2 & 0x1F)
                        case 6: rval = rs1 | rs2
                        case 7: rval = rs1 & rs2
                        default: break
                        }
                    }

                case 0x0F:                       // fences are no-ops here
                    rdid = 0

                case 0x73:                       // SYSTEM: Zicsr, ecall/ebreak, mret, wfi
                    let csrno = ir >> 20
                    let microop = (ir >> 12) & 0x7
                    if microop & 3 != 0 {
                        let rs1imm = (ir >> 15) & 0x1F
                        let rs1 = x[Int(rs1imm)]
                        var writeval = rs1

                        switch csrno {
                        case 0x340: rval = mscratch
                        case 0x305: rval = mtvec
                        case 0x304: rval = mie
                        case 0xC00: rval = cycle
                        case 0x344: rval = mip
                        case 0x341: rval = mepc
                        case 0x300: rval = mstatus
                        case 0x342: rval = mcause
                        case 0x343: rval = mtval
                        case 0xF11: rval = 0xFF0F_F0FF          // mvendorid
                        case 0x301: rval = 0x4040_1101          // misa: RV32 IMA+X
                        default: rval = 0
                        }

                        switch microop {
                        case 1: writeval = rs1                  // CSRRW
                        case 2: writeval = rval | rs1           // CSRRS
                        case 3: writeval = rval & ~rs1          // CSRRC
                        case 5: writeval = rs1imm               // CSRRWI
                        case 6: writeval = rval | rs1imm        // CSRRSI
                        case 7: writeval = rval & ~rs1imm       // CSRRCI
                        default: break
                        }

                        switch csrno {
                        case 0x340: mscratch = writeval
                        case 0x305: mtvec = writeval
                        case 0x304: mie = writeval
                        case 0x344: mip = writeval
                        case 0x341: mepc = writeval
                        case 0x300: mstatus = writeval
                        case 0x342: mcause = writeval
                        case 0x343: mtval = writeval
                        default: break
                        }
                    } else if microop == 0 {
                        rdid = 0
                        if csrno & 0xFF == 0x02 {
                            // MRET: restore MIE from MPIE, drop back to the
                            // privilege stashed in MPP.
                            let startMstatus = mstatus
                            let startExtra = extraflags
                            mstatus = ((startMstatus & 0x80) >> 4) | ((startExtra & 3) << 11) | 0x80
                            extraflags = (startExtra & ~3) | ((startMstatus >> 11) & 3)
                            pc = mepc &- 4
                        } else {
                            switch csrno {
                            case 0:
                                trap = extraflags & 3 != 0 ? (11 + 1) : (8 + 1)   // ECALL from M / U
                            case 1:
                                trap = 3 + 1                                       // EBREAK
                            case 0x105:
                                // WFI: sleep with interrupts enabled.
                                mstatus |= 8
                                extraflags |= 4
                                syncCycles(cycle)
                                self.pc = pc &+ 4
                                return .waiting
                            default:
                                trap = 2 + 1
                            }
                        }
                    } else {
                        trap = 2 + 1
                    }

                case 0x2F:                       // RV32A
                    var rs1 = x[Int((ir >> 15) & 0x1F)]
                    var rs2 = x[Int((ir >> 20) & 0x1F)]
                    let op = (ir >> 27) & 0x1F
                    rs1 &-= Self.ramBase

                    if rs1 >= ramSize &- 3 {
                        trap = 7 + 1
                        rval = rs1 &+ Self.ramBase
                    } else {
                        rval = load32(rs1)
                        var doWrite = true
                        switch op {
                        case 2:                  // LR.W: remember the reserved address
                            doWrite = false
                            extraflags = (extraflags & 0x07) | (rs1 << 3)
                        case 3:                  // SC.W: succeed only on a matching reservation
                            rval = (extraflags >> 3 != (rs1 & 0x1FFF_FFFF)) ? 1 : 0
                            doWrite = rval == 0
                        case 1: break            // AMOSWAP
                        case 0: rs2 = rs2 &+ rval
                        case 4: rs2 ^= rval
                        case 12: rs2 &= rval
                        case 8: rs2 |= rval
                        case 16: rs2 = Int32(bitPattern: rs2) < Int32(bitPattern: rval) ? rs2 : rval
                        case 20: rs2 = Int32(bitPattern: rs2) > Int32(bitPattern: rval) ? rs2 : rval
                        case 24: rs2 = min(rs2, rval)
                        case 28: rs2 = max(rs2, rval)
                        default:
                            trap = 2 + 1
                            doWrite = false
                        }
                        if doWrite { store32(rs1, rs2) }
                    }

                default:
                    trap = 2 + 1                 // illegal instruction
                }

                if trap != 0 {
                    break instructionLoop
                }
                if rdid != 0 {
                    x[Int(rdid)] = rval
                }
                pc &+= 4
            }
        }

        if trap != 0 {
            if trap & 0x8000_0000 != 0 {
                // Interrupt: mepc points at the instruction to resume.
                mcause = trap
                mtval = 0
                pc &+= 4
            } else {
                mcause = trap &- 1
                mtval = (trap > 5 && trap <= 8) ? rval : pc
            }
            mepc = pc
            // Stash MIE into MPIE and the current privilege into MPP, then
            // enter machine mode at the trap vector.
            mstatus = ((mstatus & 0x08) << 4) | ((extraflags & 3) << 11)
            pc = mtvec
            extraflags |= 3
        }

        syncCycles(cycle)
        self.pc = pc
        return .ran
    }

    @inline(__always) private func syncCycles(_ cycle: UInt32) {
        if cyclel > cycle { cycleh &+= 1 }
        cyclel = cycle
    }
}
