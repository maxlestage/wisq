//! A virtio-mmio block device, over the modern (version 2) transport.
//!
//! A port of `VirtioBlock` from the Swift side, register for register and
//! branch for branch. The two are not free to differ: the same guest kernel
//! runs on either core, and a difference here is a disk that works on one and
//! not on the other — with no error anywhere, because a virtio device that
//! answers wrongly is answering.
//!
//! Only the MMIO door is here. The Swift device also has the old port-based
//! form for the PC machine's legacy virtio-pci; the rv32 machine has no PCI at
//! all, and a door nobody knocks on is a door nobody maintains.

use crate::snapshot::{Reader, SnapshotError, Writer};
use crate::store::Store;

/// Where the rv32 machine puts the device, matching QEMU's `virt` board so a
/// kernel built for it lands on an address that does not surprise it.
pub const MMIO_BASE: u32 = 0x1000_1000;
pub const MMIO_SPAN: u32 = 0x200;

const MAGIC: u32 = 0x7472_6976; // "virt", little-endian
const VERSION: u32 = 2;
const BLOCK_DEVICE: u32 = 2;
const VENDOR: u32 = 0x7773_7169; // "wisq"

/// A queue may not be larger than this. A hundred and twenty-eight descriptors
/// is far more than a disk serving one request at a time will ever use.
const QUEUE_LIMIT: u32 = 128;

/// The guest's memory, as the device addresses it: physical addresses, which
/// start at `RAM_BASE` on this machine.
///
/// The conversion lives here and nowhere else. Descriptors carry physical
/// addresses; forgetting to subtract the base reads a megabyte before the
/// guest's memory begins, which on the Swift side was caught by a test that
/// counted zero requests served rather than by a crash.
pub struct Guest<'a> {
    ram: &'a mut [u8],
    base: u32,
}

impl<'a> Guest<'a> {
    pub fn new(ram: &'a mut [u8], base: u32) -> Self {
        Guest { ram, base }
    }

    fn offset(&self, address: u64, width: usize) -> Option<usize> {
        let base = u64::from(self.base);
        let at = usize::try_from(address.checked_sub(base)?).ok()?;
        (at.checked_add(width)? <= self.ram.len()).then_some(at)
    }

    /// `None` for an address outside the guest's memory: refused, never
    /// followed.
    pub fn read(&self, address: u64, width: usize) -> Option<u64> {
        let at = self.offset(address, width)?;
        let mut value = 0u64;
        for byte in 0..width {
            value |= u64::from(self.ram[at + byte]) << (8 * byte);
        }
        Some(value)
    }

    pub fn write(&mut self, address: u64, width: usize, value: u64) -> Option<()> {
        let at = self.offset(address, width)?;
        for byte in 0..width {
            self.ram[at + byte] = (value >> (8 * byte)) as u8;
        }
        Some(())
    }
}

/// A descriptor: sixteen bytes, and the next one if there is one.
#[derive(Clone, Copy)]
struct Descriptor {
    address: u64,
    length: u32,
    flags: u16,
    next: u16,
}

impl Descriptor {
    fn writable(&self) -> bool {
        self.flags & 2 != 0
    }
    fn chained(&self) -> bool {
        self.flags & 1 != 0
    }
}

pub struct VirtioBlock {
    /// Where the bytes live: in memory, or in a file with its write overlay.
    /// The device does not know which, and does not have to: it reads and
    /// writes pieces, that is all.
    pub store: Store,
    device_features_select: u32,
    driver_features_select: u32,
    driver_features: u64,
    status: u32,
    queue_select: u32,
    queue_size: u32,
    queue_ready: u32,
    descriptor_table: u64,
    available_ring: u64,
    used_ring: u64,
    interrupt_status: u32,
    next_available: u16,
    next_used: u16,
    /// How many requests were served, and how many refused. A device that
    /// refuses everything and a device nobody calls read the same without
    /// these two numbers.
    pub served: u64,
    pub refused: u64,
}

impl VirtioBlock {
    pub fn new(image: Vec<u8>) -> Self {
        Self::with_store(Store::Memory(image))
    }

    pub fn with_store(store: Store) -> Self {
        VirtioBlock {
            store,
            device_features_select: 0,
            driver_features_select: 0,
            driver_features: 0,
            status: 0,
            queue_select: 0,
            queue_size: 0,
            queue_ready: 0,
            descriptor_table: 0,
            available_ring: 0,
            used_ring: 0,
            interrupt_status: 0,
            next_available: 0,
            next_used: 0,
            served: 0,
            refused: 0,
        }
    }

    pub fn sectors(&self) -> u64 {
        self.store.sectors()
    }

    /// The whole content, re-read from the store. For tests and measurements.
    pub fn image(&self) -> Vec<u8> {
        self.store.image()
    }

    /// Pushes what the guest wrote down to durable storage.
    pub fn flush(&self) {
        self.store.flush();
    }

    /// True while the device is asking for the interrupt line.
    pub fn interrupting(&self) -> bool {
        self.interrupt_status != 0
    }

    pub fn read(&self, offset: u64, width: usize) -> u64 {
        // The configuration space: the capacity, in 512-byte sectors.
        if offset >= 0x100 {
            let field = offset - 0x100;
            if field >= 8 {
                return 0;
            }
            let capacity = self.sectors();
            let mut value = 0u64;
            for byte in 0..width as u64 {
                if field + byte < 8 {
                    value |= ((capacity >> (8 * (field + byte))) & 0xFF) << (8 * byte);
                }
            }
            return value;
        }
        match offset {
            0x000 => u64::from(MAGIC),
            0x004 => u64::from(VERSION),
            0x008 => u64::from(BLOCK_DEVICE),
            0x00C => u64::from(VENDOR),
            // Bits 0 to 31, then 32 to 63, depending on what the driver asked
            // for. The only one announced is VIRTIO_F_VERSION_1, bit 32:
            // without it a modern driver refuses the device, and with others
            // they would have to be honoured.
            0x010 => u64::from(self.device_features_select == 1),
            0x034 => u64::from(QUEUE_LIMIT),
            0x044 => u64::from(self.queue_ready),
            0x060 => u64::from(self.interrupt_status),
            0x070 => u64::from(self.status),
            0x0FC => 0, // the configuration never changes
            _ => 0,
        }
    }

    pub fn write(&mut self, offset: u64, value: u64, guest: &mut Guest<'_>) {
        let word = value as u32;
        match offset {
            0x014 => self.device_features_select = word,
            0x020 => {
                let shift = if self.driver_features_select == 1 {
                    32
                } else {
                    0
                };
                self.driver_features |= u64::from(word) << shift;
            }
            0x024 => self.driver_features_select = word,
            0x030 => self.queue_select = word,
            0x038 => self.queue_size = word.min(QUEUE_LIMIT),
            0x044 => self.queue_ready = word,
            0x050 => {
                if self.queue_ready != 0 {
                    self.serve(guest);
                }
            }
            0x064 => self.interrupt_status &= !word,
            0x070 => {
                self.status = word;
                // Zero puts everything back: that is the reset.
                if word == 0 {
                    self.reset();
                }
            }
            0x080 => {
                self.descriptor_table = (self.descriptor_table & !0xFFFF_FFFF) | u64::from(word)
            }
            0x084 => {
                self.descriptor_table =
                    (self.descriptor_table & 0xFFFF_FFFF) | (u64::from(word) << 32)
            }
            0x090 => self.available_ring = (self.available_ring & !0xFFFF_FFFF) | u64::from(word),
            0x094 => {
                self.available_ring = (self.available_ring & 0xFFFF_FFFF) | (u64::from(word) << 32)
            }
            0x0A0 => self.used_ring = (self.used_ring & !0xFFFF_FFFF) | u64::from(word),
            0x0A4 => self.used_ring = (self.used_ring & 0xFFFF_FFFF) | (u64::from(word) << 32),
            _ => {}
        }
    }

    fn reset(&mut self) {
        self.queue_ready = 0;
        self.queue_size = 0;
        self.descriptor_table = 0;
        self.available_ring = 0;
        self.used_ring = 0;
        self.interrupt_status = 0;
        self.next_available = 0;
        self.next_used = 0;
        self.driver_features = 0;
    }

    fn descriptor(&self, index: u16, guest: &Guest<'_>) -> Option<Descriptor> {
        let at = self
            .descriptor_table
            .wrapping_add(u64::from(index).wrapping_mul(16));
        Some(Descriptor {
            address: guest.read(at, 8)?,
            length: guest.read(at.wrapping_add(8), 4)? as u32,
            flags: guest.read(at.wrapping_add(12), 2)? as u16,
            next: guest.read(at.wrapping_add(14), 2)? as u16,
        })
    }

    /// Serve everything the driver has made available.
    ///
    /// Silence is a lie: a malformed queue, a sector past the end of the disk
    /// or an unknown request type are answered with an error *status* in the
    /// buffer meant for it, never by answering nothing — a driver with no
    /// answer waits for ever.
    fn serve(&mut self, guest: &mut Guest<'_>) {
        if self.queue_size == 0
            || self.descriptor_table == 0
            || self.available_ring == 0
            || self.used_ring == 0
        {
            return;
        }
        let Some(head) = guest.read(self.available_ring.wrapping_add(2), 2) else {
            return;
        };
        let target = head as u16;
        while self.next_available != target {
            let slot = u64::from(self.next_available % self.queue_size as u16);
            let Some(entry) = guest.read(
                self.available_ring
                    .wrapping_add(4)
                    .wrapping_add(slot.wrapping_mul(2)),
                2,
            ) else {
                return;
            };
            self.serve_one(entry as u16, guest);
            self.next_available = self.next_available.wrapping_add(1);
        }
    }

    fn serve_one(&mut self, head: u16, guest: &mut Guest<'_>) {
        let mut written: u32 = 0;
        // I/O error, until proven otherwise.
        let mut status_byte: u8 = 1;

        // The chain: the header, the data, then the status byte.
        let mut chain: Vec<Descriptor> = Vec::new();
        let mut index = head;
        while chain.len() <= QUEUE_LIMIT as usize {
            let Some(one) = self.descriptor(index, guest) else {
                break;
            };
            chain.push(one);
            if !one.chained() {
                break;
            }
            index = one.next;
        }

        let outcome = self.serve_chain(&chain, guest, &mut written);
        match outcome {
            Ok(()) => status_byte = 0,
            Err(Refusal::UnknownKind) => {
                status_byte = 2; // this device does not know that type
                self.refused += 1;
            }
            Err(Refusal::Malformed) => self.refused += 1,
        }
        if outcome.is_ok() {
            self.served += 1;
        }
        self.complete(head, written, status_byte, chain.last().copied(), guest);
    }

    fn serve_chain(
        &mut self,
        chain: &[Descriptor],
        guest: &mut Guest<'_>,
        written: &mut u32,
    ) -> Result<(), Refusal> {
        if chain.len() < 2 {
            return Err(Refusal::Malformed);
        }
        let header = chain[0];
        let last = chain[chain.len() - 1];
        if header.length < 16 || !last.writable() || last.length < 1 {
            return Err(Refusal::Malformed);
        }
        let (Some(kind), Some(sector)) = (
            guest.read(header.address, 4),
            guest.read(header.address.wrapping_add(8), 8),
        ) else {
            return Err(Refusal::Malformed);
        };
        let payload = &chain[1..chain.len() - 1];

        // A sector that does not exist is an error, not zeroes. Handing back
        // zeroes for what lies past the disk answers "here is the content" to
        // a question whose answer is "there is nothing there": a filesystem
        // would read an empty superblock instead of learning it asked too far.
        let span: u64 = payload.iter().map(|one| u64::from(one.length)).sum();
        if (kind == 0 || kind == 1)
            && sector.wrapping_mul(512).wrapping_add(span) > self.sectors().wrapping_mul(512)
        {
            return Err(Refusal::Malformed);
        }

        match kind {
            0 => {
                // read
                let mut at = sector.wrapping_mul(512);
                for buffer in payload {
                    if !buffer.writable() {
                        return Err(Refusal::Malformed);
                    }
                    let Some(bytes) = self.store.read(at, buffer.length as usize) else {
                        return Err(Refusal::Malformed);
                    };
                    for (index, value) in bytes.iter().enumerate() {
                        guest.write(
                            buffer.address.wrapping_add(index as u64),
                            1,
                            u64::from(*value),
                        );
                    }
                    *written += buffer.length;
                    at += u64::from(buffer.length);
                }
                Ok(())
            }
            1 => {
                // write
                let mut at = sector.wrapping_mul(512);
                for buffer in payload {
                    if buffer.writable() {
                        return Err(Refusal::Malformed);
                    }
                    let mut bytes = vec![0u8; buffer.length as usize];
                    for (index, slot) in bytes.iter_mut().enumerate() {
                        if let Some(value) =
                            guest.read(buffer.address.wrapping_add(index as u64), 1)
                        {
                            *slot = value as u8;
                        }
                    }
                    if !self.store.write(at, &bytes) {
                        return Err(Refusal::Malformed);
                    }
                    at += u64::from(buffer.length);
                }
                Ok(())
            }
            8 => {
                // the disk's identifier, twenty bytes
                let name = b"wisq-disk";
                for buffer in payload.iter().filter(|one| one.writable()) {
                    for byte in 0..u64::from(buffer.length) {
                        let value = name.get(byte as usize).copied().unwrap_or(0);
                        guest.write(buffer.address.wrapping_add(byte), 1, u64::from(value));
                    }
                    *written += buffer.length;
                }
                Ok(())
            }
            _ => Err(Refusal::UnknownKind),
        }
    }

    /// Put the status down, file the request in the used ring, and raise the
    /// interrupt.
    fn complete(
        &mut self,
        head: u16,
        written: u32,
        status_byte: u8,
        last: Option<Descriptor>,
        guest: &mut Guest<'_>,
    ) {
        if let Some(last) = last {
            if last.writable() && last.length >= 1 {
                guest.write(
                    last.address
                        .wrapping_add(u64::from(last.length))
                        .wrapping_sub(1),
                    1,
                    u64::from(status_byte),
                );
            }
        }
        if self.queue_size == 0 {
            return;
        }
        let slot = u64::from(self.next_used % self.queue_size as u16);
        guest.write(
            self.used_ring
                .wrapping_add(4)
                .wrapping_add(slot.wrapping_mul(8)),
            4,
            u64::from(head),
        );
        guest.write(
            self.used_ring
                .wrapping_add(8)
                .wrapping_add(slot.wrapping_mul(8)),
            4,
            u64::from(written),
        );
        self.next_used = self.next_used.wrapping_add(1);
        guest.write(self.used_ring.wrapping_add(2), 2, u64::from(self.next_used));
        self.interrupt_status |= 1;
    }

    /// Everything the driver put down, plus where the queue has got to.
    ///
    /// Field for field and in the same order as the Swift device, because the
    /// differential tests compare the two snapshots byte for byte — including
    /// the `queuePageNumber` of the legacy port form, which this device does
    /// not have and writes as zero rather than leaving a hole.
    pub(crate) fn save(&self, writer: &mut Writer) {
        writer.u32(self.device_features_select);
        writer.u32(self.driver_features_select);
        writer.u64(self.driver_features);
        writer.u32(self.status);
        writer.u32(self.queue_select);
        writer.u32(self.queue_size);
        writer.u32(self.queue_ready);
        writer.u64(self.descriptor_table);
        writer.u64(self.available_ring);
        writer.u64(self.used_ring);
        writer.u32(0); // queuePageNumber: the PC machine's legacy door
        writer.u32(self.interrupt_status);
        writer.u32(u32::from(self.next_available));
        writer.u32(u32::from(self.next_used));
        writer.u64(self.served);
        writer.u64(self.refused);
        // Except when the content lives elsewhere. A file-backed disk does not
        // travel: its overlay is already durable, and the snapshot of a machine
        // with six gigabytes of disk would be six gigabytes. An impossible
        // length marks "elsewhere"; the restore re-attaches the store the app
        // hands it.
        match &self.store {
            Store::Memory(image) => {
                writer.u64(image.len() as u64);
                writer.ram(image);
            }
            Store::File(_) => writer.u64(CONTENT_LIVES_ELSEWHERE),
        }
    }

    /// The device as it was, plus whether its content lives elsewhere — in
    /// which case the caller puts the store it already holds back in.
    pub(crate) fn restored(reader: &mut Reader) -> Result<(VirtioBlock, bool), SnapshotError> {
        let mut device = VirtioBlock::new(Vec::new());
        device.device_features_select = reader.u32()?;
        device.driver_features_select = reader.u32()?;
        device.driver_features = reader.u64()?;
        device.status = reader.u32()?;
        device.queue_select = reader.u32()?;
        device.queue_size = reader.u32()?;
        device.queue_ready = reader.u32()?;
        device.descriptor_table = reader.u64()?;
        device.available_ring = reader.u64()?;
        device.used_ring = reader.u64()?;
        let _page_number = reader.u32()?;
        device.interrupt_status = reader.u32()?;
        device.next_available = reader.u32()? as u16;
        device.next_used = reader.u32()? as u16;
        device.served = reader.u64()?;
        device.refused = reader.u64()?;
        let length = reader.u64()?;
        if length == CONTENT_LIVES_ELSEWHERE {
            return Ok((device, true));
        }
        let count = usize::try_from(length).map_err(|_| SnapshotError::Corrupt)?;
        let mut image = vec![0u8; count];
        reader.ram(&mut image)?;
        device.store = Store::Memory(image);
        Ok((device, false))
    }
}

/// The mark, in place of the image length: no image has this size. The same
/// value as the Swift device's `contentLivesElsewhere`.
const CONTENT_LIVES_ELSEWHERE: u64 = u64::MAX;

enum Refusal {
    Malformed,
    UnknownKind,
}
