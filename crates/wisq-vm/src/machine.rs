//! A complete virtual machine that boots Linux: 64 MB of RAM, one rv32ima
//! hart, an 8250 UART, a CLINT timer and a syscon — the minimal machine a
//! nommu RISC-V kernel is happy to run on.
//!
//! The console is a byte stream both ways. Output arrives through a callback on
//! the thread that runs the machine; input is queued from any thread.

use crate::core::{Bus, Core, StepResult, RAM_BASE};
use crate::dtb;
use crate::snapshot::{Reader, SnapshotError, Writer};

use std::collections::VecDeque;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

pub const DEFAULT_RAM_SIZE: usize = 64 * 1024 * 1024;

/// Reserved space at the top of RAM, matching the reference layout: the DTB
/// sits below it, and the kernel must not allocate over either.
const STATE_RESERVE: usize = 192;

/// Called with each batch of console bytes the guest writes, on the thread
/// running the machine.
pub type OutputSink = Box<dyn FnMut(&[u8]) + Send>;

#[derive(Debug, PartialEq, Eq, Clone, Copy)]
pub enum Outcome {
    PowerOff,
    Reboot,
    Stopped,
}

#[derive(Debug, PartialEq, Eq, Clone, Copy)]
pub enum LoadError {
    ImageEmpty,
    ImageTooLarge,
    CommandLineTooLong,
}

/// Shared between the thread running the machine and whoever talks to it.
#[derive(Default)]
struct Shared {
    input: Mutex<VecDeque<u8>>,
    /// Read on every UART status poll, which the guest does constantly at a
    /// shell prompt. A lock there would be taken millions of times to answer
    /// "no" — this is the same answer without the lock.
    input_ready: AtomicBool,
    stop: AtomicBool,
}

/// Handle for talking to a running machine from another thread.
#[derive(Clone)]
pub struct Handle {
    shared: Arc<Shared>,
}

impl Handle {
    /// Feeds keyboard bytes to the guest's UART.
    pub fn send(&self, bytes: &[u8]) {
        let mut queue = self.shared.input.lock().unwrap();
        queue.extend(bytes.iter().copied());
        self.shared.input_ready.store(true, Ordering::Release);
    }

    /// Asks a running `run` to return.
    pub fn stop(&self) {
        self.shared.stop.store(true, Ordering::Release);
    }
}

pub struct Machine {
    ram: Box<[u8]>,
    core: Core,
    shared: Arc<Shared>,
    pending_output: Vec<u8>,
    on_output: OutputSink,
}

impl Machine {
    pub fn new(ram_size: usize, on_output: OutputSink) -> Self {
        Machine {
            // `vec![0u8; n]` reaches the allocator's zeroing path, which for a
            // block this size is an anonymous mapping: the pages are zero by
            // definition and materialise as the guest touches them. Writing the
            // zeroes by hand would make all 64 MB resident before the guest has
            // used a byte — on a phone, that is both a startup pause and the
            // footprint the system judges the app on.
            ram: vec![0u8; ram_size].into_boxed_slice(),
            core: Core::new(),
            shared: Arc::new(Shared::default()),
            pending_output: Vec::with_capacity(4096),
            on_output,
        }
    }

    pub fn handle(&self) -> Handle {
        Handle {
            shared: Arc::clone(&self.shared),
        }
    }

    /// Instructions actually retired since boot.
    ///
    /// Not the same as budget spent: a hart in WFI burns wall time without
    /// retiring anything, so a throughput figure computed from the budget
    /// flatters an idle guest.
    pub fn retired_instructions(&self) -> u64 {
        self.core.retired()
    }

    /// Loads a kernel image and prepares the hart exactly the way the reference
    /// firmware would: image at the base of RAM, DTB near the top, a0 = hart id,
    /// a1 = DTB address, machine mode, PC at the image's first instruction.
    pub fn load(&mut self, image: &[u8], command_line: Option<&str>) -> Result<(), LoadError> {
        let mut tree = dtb::BYTES;
        if let Some(line) = command_line {
            let bytes = line.as_bytes();
            if bytes.len() >= dtb::COMMAND_LINE_CAPACITY {
                return Err(LoadError::CommandLineTooLong);
            }
            tree[dtb::COMMAND_LINE_OFFSET..dtb::COMMAND_LINE_OFFSET + bytes.len()]
                .copy_from_slice(bytes);
            tree[dtb::COMMAND_LINE_OFFSET + bytes.len()] = 0;
        }

        if image.is_empty() {
            return Err(LoadError::ImageEmpty);
        }
        let dtb_pointer = self.ram.len() - tree.len() - STATE_RESERVE;
        if image.len() > dtb_pointer {
            return Err(LoadError::ImageTooLarge);
        }

        self.ram[..image.len()].copy_from_slice(image);
        self.ram[dtb_pointer..dtb_pointer + tree.len()].copy_from_slice(&tree);

        self.core.pc = RAM_BASE;
        self.core.x[10] = 0; // a0: hart id
        self.core.x[11] = (dtb_pointer as u32).wrapping_add(RAM_BASE); // a1: DTB
        self.core.extraflags |= 3; // machine mode
        Ok(())
    }

    /// Runs until shutdown, reboot, stop, or the instruction budget runs out.
    ///
    /// Blocking by design: the caller owns the thread. The virtual clock
    /// advances with executed instructions rather than wall time, so a boot is
    /// deterministic on every machine that runs it.
    ///
    /// The budget counts instructions the guest actually retired; counting
    /// slices offered instead would let an idle guest spend a whole budget
    /// without executing anything.
    pub fn run(&mut self, instruction_budget: u64) -> Outcome {
        const SLICE: u32 = 1024;
        let start = self.core.retired();
        let mut slices_since_flush = 0u32;

        while self.core.retired() - start < instruction_budget {
            if self.shared.stop.load(Ordering::Acquire) {
                self.flush_output();
                return Outcome::Stopped;
            }

            // The borrow checker will not let the core hold `&mut self.ram`
            // while `self` is also the bus, so the pieces are split apart for
            // the call and put back after.
            let mut bus = MachineBus {
                shared: &self.shared,
                pending_output: &mut self.pending_output,
                on_output: &mut self.on_output,
                timerl: self.core.timerl,
                timerh: self.core.timerh,
                timermatchl: self.core.timermatchl,
                timermatchh: self.core.timermatchh,
            };
            let result = self.core.step(&mut self.ram, &mut bus, SLICE / 16, SLICE);
            let (matchl, matchh) = (bus.timermatchl, bus.timermatchh);
            self.core.timermatchl = matchl;
            self.core.timermatchh = matchh;

            // Prompts end without a newline; without a periodic flush they
            // would sit in the batch buffer forever and the console would look
            // hung at exactly the moment it is waiting for the user.
            slices_since_flush += 1;
            if slices_since_flush >= 32 {
                slices_since_flush = 0;
                self.flush_output();
            }

            match result {
                StepResult::Ran => continue,
                StepResult::Waiting => {
                    // The timer is the only thing that can wake a parked hart:
                    // it executes nothing, so it cannot poll the UART either.
                    // With none armed nothing ever will, and the budget cannot
                    // end the wait — it counts *retired* instructions and a
                    // parked hart retires none. Without this the loop spins at
                    // full speed for ever, on a phone, for a guest that has
                    // stopped asking for anything. The Swift core does the
                    // same, and a differential test holds them together.
                    if self.core.timermatchl == 0 && self.core.timermatchh == 0 {
                        self.flush_output();
                        return Outcome::Stopped;
                    }
                    continue;
                }
                StepResult::Halted(code) => {
                    self.flush_output();
                    return if code == 0x7777 {
                        Outcome::Reboot
                    } else {
                        Outcome::PowerOff
                    };
                }
            }
        }
        self.flush_output();
        Outcome::Stopped
    }

    /// The whole machine as bytes: RAM, the hart, and whatever is queued for
    /// the UART.
    ///
    /// Not the console output — that has already been handed to the callback
    /// and belongs to whoever owns the terminal, not to the machine. Restoring
    /// into a fresh machine with a fresh callback is the point: the guest
    /// continues, the interface decides for itself what to show.
    pub fn snapshot(&self) -> Vec<u8> {
        let mut writer = Writer::new();
        writer.core(&self.core);
        writer.ram(&self.ram);
        let queued: Vec<u8> = self.shared.input.lock().unwrap().iter().copied().collect();
        writer.bytes(&queued);
        writer.bytes(&self.pending_output);
        writer.finish()
    }

    /// Puts a saved machine back, replacing everything this one holds.
    ///
    /// On any error the machine is left as it was rather than half-written:
    /// the RAM is filled from a scratch buffer that only replaces the live one
    /// once the whole snapshot has been read. A guest with half of yesterday's
    /// memory is worse than a refused restore.
    pub fn restore(&mut self, bytes: &[u8]) -> Result<(), SnapshotError> {
        let mut reader = Reader::new(bytes)?;
        let mut core = Core::new();
        reader.core(&mut core)?;
        let mut ram = vec![0u8; self.ram.len()].into_boxed_slice();
        reader.ram(&mut ram)?;
        let queued = reader.bytes()?.to_vec();
        let pending = reader.bytes()?.to_vec();
        reader.finish()?;

        self.core = core;
        self.ram = ram;
        {
            let mut input = self.shared.input.lock().unwrap();
            input.clear();
            input.extend(queued.iter().copied());
            self.shared
                .input_ready
                .store(!input.is_empty(), Ordering::Release);
        }
        // `stop` is deliberately left alone. It is not part of the guest's
        // state — it is the owner asking this machine to come back — and
        // clearing it here threw away a stop that arrived while the machine
        // was resuming. The app restores on a background thread and can be
        // told to stop from the main one before the restore finishes; the
        // machine then ran forever with nothing able to end it.
        self.pending_output = pending;
        Ok(())
    }

    fn flush_output(&mut self) {
        if self.pending_output.is_empty() {
            return;
        }
        (self.on_output)(&self.pending_output);
        self.pending_output.clear();
    }
}

/// The devices, borrowed apart from the machine for the duration of one step.
struct MachineBus<'a> {
    shared: &'a Arc<Shared>,
    pending_output: &'a mut Vec<u8>,
    on_output: &'a mut OutputSink,
    timerl: u32,
    timerh: u32,
    timermatchl: u32,
    timermatchh: u32,
}

impl Bus for MachineBus<'_> {
    fn mmio_load(&mut self, address: u32) -> u32 {
        match address {
            // UART LSR: TX empty | RX ready
            0x1000_0005 => {
                let ready = self.shared.input_ready.load(Ordering::Acquire);
                0x60 | u32::from(ready)
            }
            // UART RX
            0x1000_0000 => {
                let mut queue = self.shared.input.lock().unwrap();
                let byte = queue.pop_front();
                if queue.is_empty() {
                    self.shared.input_ready.store(false, Ordering::Release);
                }
                byte.map(u32::from).unwrap_or(0)
            }
            0x1100_BFFC => self.timerh, // CLINT mtime high
            0x1100_BFF8 => self.timerl, // CLINT mtime low
            _ => 0,
        }
    }

    fn set_time(&mut self, low: u32, high: u32) {
        self.timerl = low;
        self.timerh = high;
    }

    fn mmio_store(&mut self, address: u32, value: u32) -> Option<u32> {
        match address {
            // UART TX
            0x1000_0000 => {
                self.pending_output.push(value as u8);
                // Deliver on line breaks or when a burst accumulates, so the
                // console feels live without a callback per byte.
                if value == 0x0A || self.pending_output.len() >= 256 {
                    (self.on_output)(self.pending_output);
                    self.pending_output.clear();
                }
                None
            }
            0x1100_4004 => {
                self.timermatchh = value; // CLINT mtimecmp high
                None
            }
            0x1100_4000 => {
                self.timermatchl = value; // CLINT mtimecmp low
                None
            }
            // syscon: poweroff / reboot
            0x1110_0000 => Some(value),
            _ => None,
        }
    }
}
