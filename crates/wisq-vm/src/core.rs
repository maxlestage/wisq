//! One rv32ima hart, interpreted.
//!
//! A Swift port of these same semantics shipped first, and this is a port of
//! that port — both descend from the execution model of Charles Lohr's
//! mini-rv32ima (MIT), the smallest known machine that boots a real Linux
//! kernel: RV32 IMA + Zicsr, machine and user modes, no MMU.
//!
//! Interpretation is the point, not a compromise. iOS grants executable memory
//! only to development-signed apps, so a JIT was never available; what is
//! available is a tighter interpreter, and that is what this is.
//!
//! Where the behaviour looks odd — the `pc - 4` dance around traps, mepc
//! pointing at the faulting instruction — it is what the kernel expects.

pub const RAM_BASE: u32 = 0x8000_0000;

/// The machine external interrupt bit in `mip` and `mie`.
///
/// Named rather than written out at the four places that read it. This is the
/// line a disk pulls to say "your request is served"; the Swift core grew it
/// first, and the two must agree bit for bit or the differential tests are
/// comparing two machines instead of two interpreters.
pub const EXTERNAL_BIT: u32 = 1 << 11;

/// Memory-mapped I/O the core does not implement itself.
pub trait Bus {
    fn mmio_load(&mut self, address: u32) -> u32;
    /// `Some(code)` halts the machine with that code — the syscon path.
    fn mmio_store(&mut self, address: u32, value: u32) -> Option<u32>;
    /// The machine clock, handed to the devices once per step, after the timer
    /// has advanced and after any wait-for-interrupt jump.
    ///
    /// It exists because the borrow checker forces the devices to be built
    /// apart from the core, and a device built with last step's time answers
    /// the guest's CLINT reads with a clock that runs behind the machine's own
    /// — by one slice normally, and by the whole idle period whenever the hart
    /// has just been jumped forward out of WFI.
    fn set_time(&mut self, low: u32, high: u32);
}

#[derive(Debug, PartialEq, Eq, Clone, Copy)]
pub enum StepResult {
    Ran,
    /// The hart executed WFI and is waiting for an interrupt.
    Waiting,
    /// A syscon write asked for shutdown (0x5555) or reboot (0x7777).
    Halted(u32),
}

pub struct Core {
    /// x0 is stored but never read back as anything but zero: the write-back
    /// path stores unconditionally and then clears it.
    pub x: [u32; 32],
    pub pc: u32,

    pub mstatus: u32,
    pub cyclel: u32,
    pub cycleh: u32,
    pub timerl: u32,
    pub timerh: u32,
    pub timermatchl: u32,
    pub timermatchh: u32,
    pub mscratch: u32,
    pub mtvec: u32,
    pub mie: u32,
    pub mip: u32,
    pub mepc: u32,
    pub mtval: u32,
    pub mcause: u32,
    /// Bits 0..1: privilege (3 = machine, 0 = user). Bit 2: WFI.
    /// Bits 3+: load-reservation address, for LR/SC.
    pub extraflags: u32,
}

impl Core {
    pub fn new() -> Self {
        Core {
            x: [0; 32],
            pc: RAM_BASE,
            mstatus: 0,
            cyclel: 0,
            cycleh: 0,
            timerl: 0,
            timerh: 0,
            timermatchl: 0,
            timermatchh: 0,
            mscratch: 0,
            mtvec: 0,
            mie: 0,
            mip: 0,
            mepc: 0,
            mtval: 0,
            mcause: 0,
            extraflags: 0,
        }
    }

    pub fn retired(&self) -> u64 {
        ((self.cycleh as u64) << 32) | self.cyclel as u64
    }

    // Immediates.
    //
    // Every RISC-V immediate is sign-extended from its top bit, and bit 31 of
    // the instruction word *is* that bit in every format that has one. An
    // arithmetic shift therefore produces the fill without a branch.

    #[inline(always)]
    fn imm_i(ir: u32) -> u32 {
        ((ir as i32) >> 20) as u32
    }

    #[inline(always)]
    fn imm_s(ir: u32) -> u32 {
        (Self::imm_i(ir) & !0x1F) | ((ir >> 7) & 0x1F)
    }

    #[inline(always)]
    fn imm_b(ir: u32) -> u32 {
        ((((ir as i32) >> 31) << 12) as u32)
            | ((ir & 0x80) << 4)
            | ((ir >> 20) & 0x7E0)
            | ((ir >> 7) & 0x1E)
    }

    #[inline(always)]
    fn imm_j(ir: u32) -> u32 {
        ((((ir as i32) >> 31) << 20) as u32)
            | (ir & 0x000F_F000)
            | ((ir & 0x0010_0000) >> 9)
            | ((ir & 0x7FE0_0000) >> 20)
    }

    #[inline(always)]
    fn is_mmio(address: u32) -> bool {
        (0x1000_0000..0x1200_0000).contains(&address)
    }

    /// Advances the virtual timer, then runs up to `count` instructions.
    ///
    /// `ram` is the guest's whole address space from `RAM_BASE`; every access
    /// is bounds-checked against it before it happens, which is also how
    /// out-of-range guest accesses become traps rather than host crashes.
    pub fn step<B: Bus>(
        &mut self,
        ram: &mut [u8],
        bus: &mut B,
        elapsed_micros: u32,
        count: u32,
    ) -> StepResult {
        let ram_size = ram.len() as u32;

        // What a device can be asking for, right now. Computed once, here,
        // because three decisions below depend on it: the jump through time,
        // waking from a `wfi`, and which trap wins.
        let external_pending = (self.mip & EXTERNAL_BIT) != 0
            && (self.mie & EXTERNAL_BIT) != 0
            && (self.mstatus & 0x8) != 0;

        // A hart in WFI retires nothing until an interrupt arrives, and the
        // timer's firing moment is already written in mtimecmp. Creeping
        // toward it in small hops costs real CPU, and on a phone real battery,
        // to reach an instant we can already name.
        //
        // Except when a device is already waiting. This machine had only the
        // timer, so the jump was always right; it is not any more. Jumping to
        // mtimecmp with a served request pending would age the guest by whole
        // seconds for a disk that has already answered — and the clock it read
        // next would not be its own.
        if self.extraflags & 4 != 0
            && !external_pending
            && (self.timermatchh != 0 || self.timermatchl != 0)
        {
            let now = ((self.timerh as u64) << 32) | self.timerl as u64;
            let match_at = ((self.timermatchh as u64) << 32) | self.timermatchl as u64;
            if now < match_at {
                self.timerh = (match_at >> 32) as u32;
                self.timerl = match_at as u32;
            }
        }

        let new_timer = self.timerl.wrapping_add(elapsed_micros);
        if new_timer < self.timerl {
            self.timerh = self.timerh.wrapping_add(1);
        }
        self.timerl = new_timer;
        bus.set_time(self.timerl, self.timerh);

        if (self.timerh > self.timermatchh
            || (self.timerh == self.timermatchh && self.timerl > self.timermatchl))
            && (self.timermatchh != 0 || self.timermatchl != 0)
        {
            self.extraflags &= !4; // wake from WFI
            self.mip |= 1 << 7; // MTIP
        } else {
            self.mip &= !(1 << 7);
        }

        // And a device wakes the hart too. A guest that issued a request waits
        // in a `wfi`; without this, the answer falls into the void and the
        // machine only restarts on the next clock tick — or never, if none is
        // armed.
        if external_pending {
            self.extraflags &= !4;
        }

        if self.extraflags & 4 != 0 {
            return StepResult::Waiting;
        }

        let mut trap: u32 = 0;
        let mut rval: u32 = 0;
        let mut pc = self.pc;
        let mut cycle = self.cyclel;

        // The external line outranks the timer, as the privileged manual
        // orders. Both pending at once is the ordinary case for a busy guest:
        // taking the timer first would leave the disk queued behind a clock.
        if external_pending {
            trap = 0x8000_000B;
            pc = pc.wrapping_sub(4);
        } else if (self.mip & (1 << 7)) != 0
            && (self.mie & (1 << 7)) != 0
            && (self.mstatus & 0x8) != 0
        {
            // Timer interrupt fires between instructions.
            trap = 0x8000_0007;
            pc = pc.wrapping_sub(4);
        } else {
            for _ in 0..count {
                rval = 0;
                cycle = cycle.wrapping_add(1);
                let offset_pc = pc.wrapping_sub(RAM_BASE);

                if offset_pc >= ram_size {
                    trap = 1 + 1; // instruction access fault
                    break;
                }
                if offset_pc & 3 != 0 {
                    trap = 1; // misaligned PC
                    break;
                }

                let ir = read_u32(ram, offset_pc);
                let mut rdid = (ir >> 7) & 0x1F;

                match ir & 0x7F {
                    0x37 => rval = ir & 0xFFFF_F000, // LUI

                    0x17 => rval = pc.wrapping_add(ir & 0xFFFF_F000), // AUIPC

                    0x6F => {
                        // JAL
                        rval = pc.wrapping_add(4);
                        pc = pc.wrapping_add(Self::imm_j(ir)).wrapping_sub(4);
                    }

                    0x67 => {
                        // JALR
                        rval = pc.wrapping_add(4);
                        pc = ((self.x[((ir >> 15) & 0x1F) as usize].wrapping_add(Self::imm_i(ir)))
                            & !1)
                            .wrapping_sub(4);
                    }

                    0x63 => {
                        // branches
                        let rs1 = self.x[((ir >> 15) & 0x1F) as usize] as i32;
                        let rs2 = self.x[((ir >> 20) & 0x1F) as usize] as i32;
                        let target = pc.wrapping_add(Self::imm_b(ir)).wrapping_sub(4);
                        rdid = 0;
                        let taken = match (ir >> 12) & 0x7 {
                            0 => rs1 == rs2,
                            1 => rs1 != rs2,
                            4 => rs1 < rs2,
                            5 => rs1 >= rs2,
                            6 => (rs1 as u32) < (rs2 as u32),
                            7 => (rs1 as u32) >= (rs2 as u32),
                            _ => {
                                trap = 2 + 1;
                                false
                            }
                        };
                        if taken {
                            pc = target;
                        }
                    }

                    0x03 => {
                        // loads
                        let rs1 = self.x[((ir >> 15) & 0x1F) as usize];
                        let mut address = rs1.wrapping_add(Self::imm_i(ir)).wrapping_sub(RAM_BASE);
                        if address >= ram_size.wrapping_sub(3) {
                            address = address.wrapping_add(RAM_BASE);
                            if Self::is_mmio(address) {
                                rval = bus.mmio_load(address);
                            } else {
                                trap = 5 + 1; // load access fault
                                rval = address;
                            }
                        } else {
                            match (ir >> 12) & 0x7 {
                                0 => rval = read_u8(ram, address) as i8 as i32 as u32,
                                1 => rval = read_u16(ram, address) as i16 as i32 as u32,
                                2 => rval = read_u32(ram, address),
                                4 => rval = read_u8(ram, address) as u32,
                                5 => rval = read_u16(ram, address) as u32,
                                _ => trap = 2 + 1,
                            }
                        }
                    }

                    0x23 => {
                        // stores
                        let rs1 = self.x[((ir >> 15) & 0x1F) as usize];
                        let rs2 = self.x[((ir >> 20) & 0x1F) as usize];
                        let mut address = Self::imm_s(ir).wrapping_add(rs1).wrapping_sub(RAM_BASE);
                        rdid = 0;
                        if address >= ram_size.wrapping_sub(3) {
                            address = address.wrapping_add(RAM_BASE);
                            if Self::is_mmio(address) {
                                if let Some(halt) = bus.mmio_store(address, rs2) {
                                    // Syscon: the reference advances PC before halting.
                                    self.pc = pc.wrapping_add(4);
                                    self.sync_cycles(cycle);
                                    return StepResult::Halted(halt);
                                }
                            } else {
                                trap = 7 + 1; // store access fault
                                rval = address;
                            }
                        } else {
                            match (ir >> 12) & 0x7 {
                                0 => write_u8(ram, address, rs2 as u8),
                                1 => write_u16(ram, address, rs2 as u16),
                                2 => write_u32(ram, address, rs2),
                                _ => trap = 2 + 1,
                            }
                        }
                    }

                    0x13 | 0x33 => {
                        // ALU, immediate and register forms
                        let imm = Self::imm_i(ir);
                        let rs1 = self.x[((ir >> 15) & 0x1F) as usize];
                        let is_reg = ir & 0x20 != 0;
                        let rs2 = if is_reg {
                            self.x[(imm & 0x1F) as usize]
                        } else {
                            imm
                        };

                        if is_reg && ir & 0x0200_0000 != 0 {
                            // RV32M
                            let s1 = rs1 as i32;
                            let s2 = rs2 as i32;
                            match (ir >> 12) & 7 {
                                0 => rval = rs1.wrapping_mul(rs2),
                                1 => rval = (((s1 as i64) * (s2 as i64)) >> 32) as u32,
                                2 => rval = (((s1 as i64) * (rs2 as u64 as i64)) >> 32) as u32,
                                3 => rval = (((rs1 as u64) * (rs2 as u64)) >> 32) as u32,
                                4 => {
                                    rval = if rs2 == 0 {
                                        0xFFFF_FFFF
                                    } else if s1 == i32::MIN && s2 == -1 {
                                        rs1
                                    } else {
                                        (s1 / s2) as u32
                                    }
                                }
                                // DIVU and REMU: the spec's answer for a zero
                                // divisor is all-ones and the dividend
                                // respectively, which is exactly what the
                                // checked forms fall back to. The signed pair
                                // above cannot use them — `checked_div` returns
                                // None for both a zero divisor and the
                                // INT_MIN / -1 overflow, and RISC-V wants a
                                // different answer for each.
                                5 => rval = rs1.checked_div(rs2).unwrap_or(0xFFFF_FFFF),
                                6 => {
                                    rval = if rs2 == 0 {
                                        rs1
                                    } else if s1 == i32::MIN && s2 == -1 {
                                        0
                                    } else {
                                        (s1 % s2) as u32
                                    }
                                }
                                7 => rval = rs1.checked_rem(rs2).unwrap_or(rs1),
                                _ => {}
                            }
                        } else {
                            match (ir >> 12) & 7 {
                                0 => {
                                    rval = if is_reg && ir & 0x4000_0000 != 0 {
                                        rs1.wrapping_sub(rs2)
                                    } else {
                                        rs1.wrapping_add(rs2)
                                    }
                                }
                                1 => rval = rs1 << (rs2 & 0x1F),
                                2 => rval = ((rs1 as i32) < (rs2 as i32)) as u32,
                                3 => rval = (rs1 < rs2) as u32,
                                4 => rval = rs1 ^ rs2,
                                5 => {
                                    rval = if ir & 0x4000_0000 != 0 {
                                        ((rs1 as i32) >> (rs2 & 0x1F)) as u32
                                    } else {
                                        rs1 >> (rs2 & 0x1F)
                                    }
                                }
                                6 => rval = rs1 | rs2,
                                7 => rval = rs1 & rs2,
                                _ => {}
                            }
                        }
                    }

                    0x0F => rdid = 0, // fences are no-ops here

                    0x73 => {
                        // SYSTEM: Zicsr, ecall/ebreak, mret, wfi
                        let csrno = ir >> 20;
                        let microop = (ir >> 12) & 0x7;
                        if microop & 3 != 0 {
                            let rs1imm = (ir >> 15) & 0x1F;
                            let rs1 = self.x[rs1imm as usize];

                            rval = match csrno {
                                0x340 => self.mscratch,
                                0x305 => self.mtvec,
                                0x304 => self.mie,
                                0xC00 => cycle,
                                0x344 => self.mip,
                                0x341 => self.mepc,
                                0x300 => self.mstatus,
                                0x342 => self.mcause,
                                0x343 => self.mtval,
                                0xF11 => 0xFF0F_F0FF, // mvendorid
                                0x301 => 0x4040_1101, // misa: RV32 IMA+X
                                _ => 0,
                            };

                            let writeval = match microop {
                                1 => rs1,            // CSRRW
                                2 => rval | rs1,     // CSRRS
                                3 => rval & !rs1,    // CSRRC
                                5 => rs1imm,         // CSRRWI
                                6 => rval | rs1imm,  // CSRRSI
                                7 => rval & !rs1imm, // CSRRCI
                                _ => rs1,
                            };

                            match csrno {
                                0x340 => self.mscratch = writeval,
                                0x305 => self.mtvec = writeval,
                                0x304 => self.mie = writeval,
                                0x344 => self.mip = writeval,
                                0x341 => self.mepc = writeval,
                                0x300 => self.mstatus = writeval,
                                0x342 => self.mcause = writeval,
                                0x343 => self.mtval = writeval,
                                _ => {}
                            }
                        } else if microop == 0 {
                            rdid = 0;
                            if csrno & 0xFF == 0x02 {
                                // MRET: restore MIE from MPIE, drop back to the
                                // privilege stashed in MPP.
                                let start_mstatus = self.mstatus;
                                let start_extra = self.extraflags;
                                self.mstatus = ((start_mstatus & 0x80) >> 4)
                                    | ((start_extra & 3) << 11)
                                    | 0x80;
                                self.extraflags = (start_extra & !3) | ((start_mstatus >> 11) & 3);
                                pc = self.mepc.wrapping_sub(4);
                            } else {
                                match csrno {
                                    // ECALL from M / U
                                    0 => {
                                        trap = if self.extraflags & 3 != 0 {
                                            11 + 1
                                        } else {
                                            8 + 1
                                        }
                                    }
                                    1 => trap = 3 + 1, // EBREAK
                                    0x105 => {
                                        // WFI: sleep with interrupts enabled.
                                        self.mstatus |= 8;
                                        self.extraflags |= 4;
                                        self.sync_cycles(cycle);
                                        self.pc = pc.wrapping_add(4);
                                        return StepResult::Waiting;
                                    }
                                    _ => trap = 2 + 1,
                                }
                            }
                        } else {
                            trap = 2 + 1;
                        }
                    }

                    0x2F => {
                        // RV32A
                        let mut rs1 = self.x[((ir >> 15) & 0x1F) as usize];
                        let mut rs2 = self.x[((ir >> 20) & 0x1F) as usize];
                        let op = (ir >> 27) & 0x1F;
                        rs1 = rs1.wrapping_sub(RAM_BASE);

                        if rs1 >= ram_size.wrapping_sub(3) {
                            trap = 7 + 1;
                            rval = rs1.wrapping_add(RAM_BASE);
                        } else {
                            rval = read_u32(ram, rs1);
                            let mut do_write = true;
                            match op {
                                2 => {
                                    // LR.W: remember the reserved address
                                    do_write = false;
                                    self.extraflags = (self.extraflags & 0x07) | (rs1 << 3);
                                }
                                3 => {
                                    // SC.W: succeed only on a matching reservation
                                    rval = ((self.extraflags >> 3) != (rs1 & 0x1FFF_FFFF)) as u32;
                                    do_write = rval == 0;
                                }
                                1 => {} // AMOSWAP
                                0 => rs2 = rs2.wrapping_add(rval),
                                4 => rs2 ^= rval,
                                12 => rs2 &= rval,
                                8 => rs2 |= rval,
                                16 => {
                                    rs2 = if (rs2 as i32) < (rval as i32) {
                                        rs2
                                    } else {
                                        rval
                                    }
                                }
                                20 => {
                                    rs2 = if (rs2 as i32) > (rval as i32) {
                                        rs2
                                    } else {
                                        rval
                                    }
                                }
                                24 => rs2 = rs2.min(rval),
                                28 => rs2 = rs2.max(rval),
                                _ => {
                                    trap = 2 + 1;
                                    do_write = false;
                                }
                            }
                            if do_write {
                                write_u32(ram, rs1, rs2);
                            }
                        }
                    }

                    _ => trap = 2 + 1, // illegal instruction
                }

                if trap != 0 {
                    break;
                }
                if rdid != 0 {
                    self.x[rdid as usize] = rval;
                }
                pc = pc.wrapping_add(4);
            }
        }

        if trap != 0 {
            if trap & 0x8000_0000 != 0 {
                // Interrupt: mepc points at the instruction to resume.
                self.mcause = trap;
                self.mtval = 0;
                pc = pc.wrapping_add(4);
            } else {
                self.mcause = trap - 1;
                self.mtval = if trap > 5 && trap <= 8 { rval } else { pc };
            }
            self.mepc = pc;
            // Stash MIE into MPIE and the current privilege into MPP, then
            // enter machine mode at the trap vector.
            self.mstatus = ((self.mstatus & 0x08) << 4) | ((self.extraflags & 3) << 11);
            pc = self.mtvec;
            self.extraflags |= 3;
        }

        self.sync_cycles(cycle);
        self.pc = pc;
        StepResult::Ran
    }

    #[inline(always)]
    fn sync_cycles(&mut self, cycle: u32) {
        if self.cyclel > cycle {
            self.cycleh = self.cycleh.wrapping_add(1);
        }
        self.cyclel = cycle;
    }
}

impl Default for Core {
    fn default() -> Self {
        Self::new()
    }
}

// Guest memory access.
//
// Reads and writes are unaligned by contract: RISC-V allows a 32-bit load at
// any byte address, and the guest uses that. One unaligned access compiles to a
// single instruction on both architectures wisq targets; assembling the value
// from four byte loads does not reliably fold back into one.
//
// Every caller bounds-checks the address against the guest's RAM size first —
// that check is not an assertion, it is the emulator semantics that turn an
// out-of-range guest access into a trap. Re-checking here would be a second
// branch per load and store on the two opcode groups that make up 47 % of a
// Linux boot, so these read the slice directly. `debug_assert` keeps the test
// builds honest about the invariant.

#[inline(always)]
fn read_u8(ram: &[u8], offset: u32) -> u8 {
    debug_assert!((offset as usize) < ram.len());
    unsafe { *ram.get_unchecked(offset as usize) }
}

#[inline(always)]
fn read_u16(ram: &[u8], offset: u32) -> u16 {
    debug_assert!((offset as usize) + 2 <= ram.len());
    unsafe {
        u16::from_le(
            ram.as_ptr()
                .add(offset as usize)
                .cast::<u16>()
                .read_unaligned(),
        )
    }
}

#[inline(always)]
fn read_u32(ram: &[u8], offset: u32) -> u32 {
    debug_assert!((offset as usize) + 4 <= ram.len());
    unsafe {
        u32::from_le(
            ram.as_ptr()
                .add(offset as usize)
                .cast::<u32>()
                .read_unaligned(),
        )
    }
}

#[inline(always)]
fn write_u8(ram: &mut [u8], offset: u32, value: u8) {
    debug_assert!((offset as usize) < ram.len());
    unsafe {
        *ram.get_unchecked_mut(offset as usize) = value;
    }
}

#[inline(always)]
fn write_u16(ram: &mut [u8], offset: u32, value: u16) {
    debug_assert!((offset as usize) + 2 <= ram.len());
    unsafe {
        ram.as_mut_ptr()
            .add(offset as usize)
            .cast::<u16>()
            .write_unaligned(value.to_le());
    }
}

#[inline(always)]
fn write_u32(ram: &mut [u8], offset: u32, value: u32) {
    debug_assert!((offset as usize) + 4 <= ram.len());
    unsafe {
        ram.as_mut_ptr()
            .add(offset as usize)
            .cast::<u32>()
            .write_unaligned(value.to_le());
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A bus that answers nothing and remembers nothing.
    ///
    /// These tests are about the interrupt line, not about devices: the line
    /// is raised by writing `mip` from the outside, which is exactly what a
    /// device does through `poll_devices`.
    struct NullBus;

    impl Bus for NullBus {
        fn mmio_load(&mut self, _address: u32) -> u32 {
            0
        }
        fn mmio_store(&mut self, _address: u32, _value: u32) -> Option<u32> {
            None
        }
        fn set_time(&mut self, _low: u32, _high: u32) {}
    }

    /// `wfi` then a spin, so a hart that is woken has somewhere to go.
    const PARKS_THEN_SPINS: [u32; 2] = [0x1050_0073, 0x0000_0063];

    fn machine(program: &[u32]) -> (Vec<u8>, Core) {
        let mut ram = vec![0u8; 1 << 20];
        for (index, word) in program.iter().enumerate() {
            ram[index * 4..index * 4 + 4].copy_from_slice(&word.to_le_bytes());
        }
        let mut core = Core::new();
        core.extraflags |= 3; // machine mode
        (ram, core)
    }

    /// The line only fires when all three say so: pending, enabled, and the
    /// global gate open. Any one of them missing and the hart runs on.
    #[test]
    fn the_external_line_needs_pending_enabled_and_the_gate() {
        for (mip, mie, mstatus, expected) in [
            (EXTERNAL_BIT, EXTERNAL_BIT, 0x8, true),
            (0, EXTERNAL_BIT, 0x8, false),
            (EXTERNAL_BIT, 0, 0x8, false),
            (EXTERNAL_BIT, EXTERNAL_BIT, 0, false),
        ] {
            let (mut ram, mut core) = machine(&[0x0000_0013, 0x0000_0013]);
            core.mtvec = RAM_BASE + 0x100;
            core.mip = mip;
            core.mie = mie;
            core.mstatus = mstatus;
            core.step(&mut ram, &mut NullBus, 0, 1);
            assert_eq!(
                core.pc == core.mtvec,
                expected,
                "mip={mip:#x} mie={mie:#x} mstatus={mstatus:#x}"
            );
        }
    }

    /// The cause the guest reads, and the instruction it comes back to.
    #[test]
    fn the_cause_is_machine_external_and_mepc_points_at_the_next_instruction() {
        let (mut ram, mut core) = machine(&[0x0000_0013, 0x0000_0013]);
        core.mtvec = RAM_BASE + 0x100;
        core.mip = EXTERNAL_BIT;
        core.mie = EXTERNAL_BIT;
        core.mstatus = 0x8;
        core.step(&mut ram, &mut NullBus, 0, 1);
        assert_eq!(core.mcause, 0x8000_000B);
        assert_eq!(core.mepc, RAM_BASE, "the instruction that had not run yet");
    }

    /// Both pending at once is the ordinary case for a busy guest, and the
    /// external one goes first — the privileged manual's order.
    #[test]
    fn the_external_line_outranks_the_timer() {
        let (mut ram, mut core) = machine(&[0x0000_0013, 0x0000_0013]);
        core.mtvec = RAM_BASE + 0x100;
        core.mip = EXTERNAL_BIT | (1 << 7);
        core.mie = EXTERNAL_BIT | (1 << 7);
        core.mstatus = 0x8;
        core.timermatchl = 1;
        core.step(&mut ram, &mut NullBus, 0, 1);
        assert_eq!(core.mcause, 0x8000_000B, "the timer must not win");
    }

    /// A parked hart is woken by a device, not only by the clock.
    ///
    /// Without this, a guest that issued a request and waited would sleep
    /// until the next tick — or for ever, with no timer armed.
    #[test]
    fn a_device_wakes_a_parked_hart() {
        let (mut ram, mut core) = machine(&PARKS_THEN_SPINS);
        core.mtvec = RAM_BASE + 0x100;
        core.mie = EXTERNAL_BIT;
        core.mstatus = 0x8;
        assert_eq!(
            core.step(&mut ram, &mut NullBus, 0, 4),
            StepResult::Waiting,
            "the hart parks with nothing armed"
        );
        core.mip |= EXTERNAL_BIT;
        let result = core.step(&mut ram, &mut NullBus, 0, 4);
        assert_ne!(result, StepResult::Waiting, "and the device wakes it");
        assert_eq!(core.pc, core.mtvec);
    }

    /// And the jump through time stands down while a device is waiting.
    ///
    /// The jump exists because a parked hart's next event is already written
    /// in mtimecmp. That stopped being the whole truth the moment a second
    /// interrupt source existed: jumping would age the guest by the whole idle
    /// period for a disk that has already answered.
    #[test]
    fn a_waiting_device_stops_the_jump_through_time() {
        let (mut ram, mut core) = machine(&PARKS_THEN_SPINS);
        core.mtvec = RAM_BASE + 0x100;
        core.mie = EXTERNAL_BIT;
        core.mstatus = 0x8;
        core.timermatchh = 1; // a very long way off
        core.step(&mut ram, &mut NullBus, 0, 4);
        assert_eq!(core.timerh, 0, "parked, but the clock has not moved yet");

        core.mip |= EXTERNAL_BIT;
        core.step(&mut ram, &mut NullBus, 0, 4);
        assert_eq!(
            core.timerh, 0,
            "the guest's clock must not leap to mtimecmp for a device that already answered"
        );
    }
}
