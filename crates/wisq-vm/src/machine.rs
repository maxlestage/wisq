//! A complete virtual machine that boots Linux: 64 MB of RAM, one rv32ima
//! hart, an 8250 UART, a CLINT timer and a syscon — the minimal machine a
//! nommu RISC-V kernel is happy to run on.
//!
//! The console is a byte stream both ways. Output arrives through a callback on
//! the thread that runs the machine; input is queued from any thread.

use crate::core::{Bus, Core, StepResult, RAM_BASE};
use crate::dtb;
use crate::snapshot::{Reader, SnapshotError, Writer};
use crate::virtio::{Guest, VirtioBlock, MMIO_BASE, MMIO_SPAN};

use std::collections::VecDeque;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

pub const DEFAULT_RAM_SIZE: usize = 64 * 1024 * 1024;

/// The largest machine this architecture can have, and it is not a policy.
///
/// Guest RAM starts at `RAM_BASE` (`0x8000_0000`) and the hart addresses memory
/// with thirty-two bits, so the last byte a machine can own is `0xFFFF_FFFF`.
/// Two gibibytes lands exactly there — `0x8000_0000 + 2 GiB == 2^32` — and one
/// byte more has nowhere to live.
///
/// Measured on the Swift core, whose failure was silent: a machine built with
/// three gibibytes loaded without complaint, announced 3 221 209 088 bytes in
/// its device tree, and then produced nothing at all — no banner, no console,
/// no error. Both cores refuse it now, because two implementations of one
/// machine that disagree about its limits is the divergence the differential
/// test exists to prevent.
pub const MAXIMUM_RAM_SIZE: usize = 2 * 1024 * 1024 * 1024;

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
    /// More memory than a thirty-two-bit hart can address. See
    /// `MAXIMUM_RAM_SIZE`.
    RamSizeUnsupported,
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
    disk: Option<VirtioBlock>,
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
            disk: None,
            pending_output: Vec::with_capacity(4096),
            on_output,
        }
    }

    /// Gives the machine a disk, before `load`.
    ///
    /// Before, because it is `load` that writes the device tree, and a tree
    /// already placed is not rewritten: a device the tree does not declare
    /// does not exist for the kernel. The Swift machine builds its own tree
    /// and so decides this itself; here the tree arrives from outside, and it
    /// is the caller — `WisqUI` — that must ask for the node.
    pub fn attach_disk(&mut self, image: &[u8]) {
        self.disk = Some(VirtioBlock::new(image.to_vec()));
    }

    /// Gives the machine a disk read from a file, with a durable write
    /// overlay beside it — see `store::FileStore`. Nothing of the base is
    /// copied; this is how an installer image of several gigabytes gets
    /// attached on a phone.
    pub fn attach_disk_file(
        &mut self,
        base: &std::path::Path,
        writes: &std::path::Path,
    ) -> Result<(), crate::store::StoreError> {
        let store = crate::store::FileStore::open(base, writes)?;
        self.disk = Some(VirtioBlock::with_store(crate::store::Store::File(store)));
        Ok(())
    }

    /// Pushes what the guest wrote to the disk down to durable storage.
    pub fn flush_disk(&self) {
        if let Some(disk) = self.disk.as_ref() {
            disk.flush();
        }
    }

    /// How many bytes of disk the guest has changed — the overlay's size for
    /// a file-backed disk, the image's for a memory one.
    pub fn disk_bytes_written(&self) -> u64 {
        self.disk
            .as_ref()
            .map_or(0, |disk| disk.store.bytes_written())
    }

    /// Takes it away, and drops the line with it.
    ///
    /// An interrupt raised that nobody will ever serve locks the guest inside
    /// its handler.
    pub fn detach_disk(&mut self) {
        self.disk = None;
        self.core.mip &= !crate::core::EXTERNAL_BIT;
    }

    pub fn disk_served(&self) -> u64 {
        self.disk.as_ref().map_or(0, |disk| disk.served)
    }

    pub fn disk_refused(&self) -> u64 {
        self.disk.as_ref().map_or(0, |disk| disk.refused)
    }

    pub fn has_disk(&self) -> bool {
        self.disk.is_some()
    }

    /// Carries what the devices are asking for onto the hart's line.
    ///
    /// **Called after each slice, not inside the store that caused it.** The
    /// Swift machine polls from within `mmioStore`, which it can because the
    /// core and the device share an owner there; the borrow checker will not
    /// allow it here. The two come to the same thing: the trap is only taken
    /// between slices either way, and the line's state at that moment is what
    /// decides.
    fn poll_devices(&mut self) {
        let asking = self.disk.as_ref().is_some_and(|disk| disk.interrupting());
        if asking {
            self.core.mip |= crate::core::EXTERNAL_BIT;
        } else {
            self.core.mip &= !crate::core::EXTERNAL_BIT;
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
        // The tree states this machine's memory, not the reference's. Without
        // it, a machine allocated with more RAM would run a kernel that never
        // learns about it.
        let mut tree = dtb::bytes_for(self.ram.len());
        if let Some(line) = command_line {
            let bytes = line.as_bytes();
            if bytes.len() >= dtb::COMMAND_LINE_CAPACITY {
                return Err(LoadError::CommandLineTooLong);
            }
            tree[dtb::COMMAND_LINE_OFFSET..dtb::COMMAND_LINE_OFFSET + bytes.len()]
                .copy_from_slice(bytes);
            tree[dtb::COMMAND_LINE_OFFSET + bytes.len()] = 0;
        }
        self.load_with_tree(image, &tree)
    }

    /// The same, with the device tree handed in rather than built here.
    ///
    /// **Why the caller may own the tree.** The tree is not interpreter
    /// behaviour: it is what the firmware tells the kernel about the board,
    /// and wisq runs two interpreters on the *same* board. Each building its
    /// own tree from its own copy of the reference blob is how the two quietly
    /// end up describing different machines — and it is what stopped either of
    /// them from ever declaring a device the other did not know about. The app
    /// therefore builds one tree and hands it to whichever core it is running.
    ///
    /// `load` above stays for a caller that has no tree of its own: this crate
    /// is meant to be usable without the Swift side, and it should still boot
    /// a kernel on its own.
    pub fn load_with_tree(&mut self, image: &[u8], tree: &[u8]) -> Result<(), LoadError> {
        if self.ram.len() > MAXIMUM_RAM_SIZE {
            return Err(LoadError::RamSizeUnsupported);
        }
        if image.is_empty() {
            return Err(LoadError::ImageEmpty);
        }
        let dtb_pointer = self.ram.len() - tree.len() - STATE_RESERVE;
        if image.len() > dtb_pointer {
            return Err(LoadError::ImageTooLarge);
        }

        self.ram[..image.len()].copy_from_slice(image);
        self.ram[dtb_pointer..dtb_pointer + tree.len()].copy_from_slice(tree);

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
                disk: self.disk.as_mut(),
                disk_touched: false,
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
            if bus.disk_touched {
                self.poll_devices();
            }

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
        // The disk comes last, and only when there is one: a machine saved
        // before disks existed has nothing here, and reading it back must stay
        // possible — the phones already carry such snapshots.
        if let Some(disk) = self.disk.as_ref() {
            disk.save(&mut writer);
        }
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
        // Absent in a snapshot taken before the machine had a disk. Its
        // absence reads as "no disk", not as a corrupt file.
        let restored_disk = if reader.is_at_end() {
            None
        } else {
            Some(VirtioBlock::restored(&mut reader)?)
        };
        reader.finish()?;

        self.core = core;
        self.ram = ram;
        // A disk whose content lives elsewhere takes the store the machine
        // already holds — the one the app opened on the same file. Without
        // one it comes back empty: zero sectors, I/O errors, the way a disk
        // that was unplugged reads.
        self.disk = match restored_disk {
            None => None,
            Some((disk, false)) => Some(disk),
            Some((mut disk, true)) => {
                if let Some(previous) = self.disk.take() {
                    disk.store = previous.store;
                }
                Some(disk)
            }
        };
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
    disk: Option<&'a mut VirtioBlock>,
    /// Set when an access landed in the disk's window during this slice.
    ///
    /// **It is what says whether the line may be touched at all.** The Swift
    /// machine polls from inside the store that reached the device, so a guest
    /// that writes `mip` itself is never overwritten. Polling after every
    /// slice instead looked equivalent and was not: with no disk attached it
    /// cleared the bit the guest had just set by hand, and the differential
    /// test that compares the two cores on interrupt priority went red — which
    /// is exactly what it is for.
    disk_touched: bool,
    pending_output: &'a mut Vec<u8>,
    on_output: &'a mut OutputSink,
    timerl: u32,
    timerh: u32,
    timermatchl: u32,
    timermatchh: u32,
}

impl Bus for MachineBus<'_> {
    fn mmio_load(&mut self, _ram: &mut [u8], address: u32) -> u32 {
        // The disk decodes its own window first: everything else here is a
        // fixed address, and a device with a span has to be asked whether the
        // address is its own.
        if let Some(disk) = self.disk.as_deref_mut() {
            if (MMIO_BASE..MMIO_BASE + MMIO_SPAN).contains(&address) {
                let value = disk.read(u64::from(address - MMIO_BASE), 4) as u32;
                self.disk_touched = true;
                return value;
            }
        }
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

    fn mmio_store(&mut self, ram: &mut [u8], address: u32, value: u32) -> Option<u32> {
        if let Some(disk) = self.disk.as_deref_mut() {
            if (MMIO_BASE..MMIO_BASE + MMIO_SPAN).contains(&address) {
                let mut guest = Guest::new(ram, RAM_BASE);
                disk.write(u64::from(address - MMIO_BASE), u64::from(value), &mut guest);
                self.disk_touched = true;
                return None;
            }
        }
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

#[cfg(test)]
mod tests {
    use super::*;

    /// Where `load` put the tree, from the machine's own numbers rather than a
    /// restated constant: the last `STATE_RESERVE` bytes of RAM are reserved,
    /// and the tree sits just under them.
    fn tree_in_ram(machine: &Machine) -> [u8; 1536] {
        let at = machine.ram.len() - 1536 - STATE_RESERVE;
        machine.ram[at..at + 1536].try_into().expect("l'arbre")
    }

    /// A machine given more RAM must hand the guest a tree that says so.
    ///
    /// This is the assertion a sabotage found missing: putting `dtb::BYTES`
    /// back verbatim in `load` — the whole point of the resize undone — passed
    /// every test in this crate. The DTB module's own tests only proved
    /// `bytes_for` computes the right blob; nothing proved `load` used it.
    #[test]
    fn a_resized_machine_tells_its_guest_the_new_size() {
        // A single NOP: enough to satisfy `load`, small enough for any size.
        let image = [0x13, 0x00, 0x00, 0x00];

        let mut reference = Machine::new(DEFAULT_RAM_SIZE, Box::new(|_| {}));
        reference.load(&image, None).expect("chargement 64 Mio");
        assert_eq!(
            dtb::declared_memory(&tree_in_ram(&reference)),
            (DEFAULT_RAM_SIZE - dtb::MEMORY_TOP_RESERVE) as u32
        );

        let large = 128 * 1024 * 1024;
        let mut resized = Machine::new(large, Box::new(|_| {}));
        resized.load(&image, None).expect("chargement 128 Mio");
        assert_eq!(
            dtb::declared_memory(&tree_in_ram(&resized)),
            (large - dtb::MEMORY_TOP_RESERVE) as u32,
            "l'invité doit apprendre la taille de sa machine, pas celle de la référence"
        );
    }

    /// And the guest must be pointed at that tree: a1 carries its address.
    ///
    /// Patching the blob and then handing the kernel a pointer somewhere else
    /// would leave the resize invisible just as thoroughly.
    #[test]
    fn the_guest_is_pointed_at_the_tree_that_was_written() {
        let mut machine = Machine::new(128 * 1024 * 1024, Box::new(|_| {}));
        machine
            .load(&[0x13, 0x00, 0x00, 0x00], None)
            .expect("chargement");
        let pointer = machine.core.x[11];
        let at = (pointer - RAM_BASE) as usize;
        assert_eq!(
            dtb::declared_memory(
                &machine.ram[at..at + 1536]
                    .try_into()
                    .expect("l'arbre à l'adresse annoncée")
            ),
            (128 * 1024 * 1024 - dtb::MEMORY_TOP_RESERVE) as u32
        );
    }

    /// Plus de mémoire que le processeur ne peut adresser est refusé, pas
    /// construit en silence.
    ///
    /// La mesure qui a motivé cette garde vient du cœur Swift, et l'échec y
    /// était muet : trois gibioctets se chargeaient sans se plaindre puis ne
    /// produisaient rien du tout. Les deux cœurs refusent maintenant la même
    /// taille, parce que deux implémentations d'une même machine qui ne sont
    /// pas d'accord sur ses limites est exactement la divergence que le test
    /// différentiel existe pour empêcher.
    #[test]
    fn more_memory_than_the_hart_can_address_is_refused() {
        let image = [0x13, 0x00, 0x00, 0x00];

        let mut too_large = Machine::new(3 * 1024 * 1024 * 1024, Box::new(|_| {}));
        assert_eq!(
            too_large.load(&image, None),
            Err(LoadError::RamSizeUnsupported)
        );

        // Et le bord exact est accepté : refuser 2 Gio serait aussi faux.
        let mut at_the_limit = Machine::new(MAXIMUM_RAM_SIZE, Box::new(|_| {}));
        assert_eq!(at_the_limit.load(&image, None), Ok(()));
    }

    /// La limite est le dernier octet adressable, calculée plutôt que
    /// réaffirmée : RAM_BASE + MAXIMUM_RAM_SIZE vaut exactement 2^32.
    #[test]
    fn the_limit_is_where_the_address_space_ends() {
        assert_eq!(RAM_BASE as u64 + MAXIMUM_RAM_SIZE as u64, 1u64 << 32);
    }

    /// A command line and a resize are patched into the same blob, and neither
    /// erases the other — the two offsets are 0xC0 and 316, sixteen bytes
    /// apart at their closest, so this is a real thing to get wrong.
    #[test]
    fn a_command_line_and_a_resize_survive_each_other() {
        let mut machine = Machine::new(128 * 1024 * 1024, Box::new(|_| {}));
        machine
            .load(&[0x13, 0x00, 0x00, 0x00], Some("console=ttyS0 quiet"))
            .expect("chargement");
        let tree = tree_in_ram(&machine);
        assert_eq!(
            dtb::declared_memory(&tree),
            (128 * 1024 * 1024 - dtb::MEMORY_TOP_RESERVE) as u32
        );
        let line = &tree[dtb::COMMAND_LINE_OFFSET..dtb::COMMAND_LINE_OFFSET + 19];
        assert_eq!(line, b"console=ttyS0 quiet");
    }

    /// A file-backed disk does not travel in the snapshot: the snapshot is
    /// small, and the restore puts the store the machine already holds back
    /// under the restored registers. Without one, the disk comes back empty
    /// rather than the restore failing.
    #[test]
    fn a_file_backed_disk_stays_out_of_the_snapshot_and_comes_back_on_restore() {
        let folder = std::env::temp_dir().join(format!("wisq-machine-disk-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&folder);
        std::fs::create_dir_all(&folder).unwrap();
        let base = folder.join("base.img");
        std::fs::write(&base, vec![7u8; 4096 * 512]).unwrap();
        let writes = folder.join("disk.writes");

        let image = [0x13, 0x00, 0x00, 0x00];
        let mut machine = Machine::new(DEFAULT_RAM_SIZE, Box::new(|_| {}));
        machine
            .attach_disk_file(&base, &writes)
            .expect("le disque sur fichier");
        machine.load(&image, None).expect("chargement");
        machine.disk.as_mut().unwrap().store.write(512, &[1u8; 512]);
        let saved = machine.snapshot();
        assert!(
            saved.len() < 1 << 20,
            "l'image n'est pas dedans : {} octets",
            saved.len()
        );

        let mut resumed = Machine::new(DEFAULT_RAM_SIZE, Box::new(|_| {}));
        resumed.attach_disk_file(&base, &writes).expect("rebranché");
        resumed.restore(&saved).expect("reprise");
        assert!(resumed.has_disk());
        assert_eq!(
            resumed.disk_bytes_written(),
            512,
            "la couche rebranchée porte le secteur"
        );
        assert_eq!(
            resumed.disk.as_ref().unwrap().store.read(512, 2),
            Some(vec![1, 1])
        );

        let mut bare = Machine::new(DEFAULT_RAM_SIZE, Box::new(|_| {}));
        bare.restore(&saved).expect("reprise sans disque rebranché");
        assert!(bare.has_disk(), "le périphérique est là");
        assert_eq!(bare.disk.as_ref().unwrap().sectors(), 0, "mais vide");

        let _ = std::fs::remove_dir_all(&folder);
    }
}
