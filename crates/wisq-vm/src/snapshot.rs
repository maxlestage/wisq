//! Saving a running machine, and bringing it back.
//!
//! The obvious way to give the local Linux persistence is a disk: a virtio-blk
//! device, a filesystem, and the guest keeps its own files. That does not work
//! here, and the reason is worth writing down so nobody spends a week
//! discovering it again. The kernels this emulator runs are rv32 nommu builds
//! in the mini-rv32ima family, and the reference image has the virtio-mmio
//! transport but no block driver at all — its whole filesystem list is
//! devtmpfs, proc, ramfs and sysfs. A perfect virtio-blk implementation would
//! have nobody to talk to. Worse, the user imports their own kernel, so
//! whether a disk works at all would depend on a build we do not control.
//!
//! Saving the machine instead of the disk sidesteps the guest entirely. The
//! state below the kernel — RAM, the hart's registers, the timer, the bytes
//! queued for the UART — is ours, and restoring it puts the guest back exactly
//! where it was, mid-syscall if that is where it was. Any kernel, no driver
//! required, and no filesystem to corrupt on a hard kill.
//!
//! The format is deliberately dull: a magic, a version, the CPU words, then
//! RAM. Zero runs are folded, because a 64 MB image whose
//! interesting part is a few megabytes is the difference between a snapshot a
//! phone can take on every backgrounding and one it cannot.

use crate::core::Core;

/// Bytes at the start of every snapshot. Version last, so a future format can
/// be recognised and refused rather than read as garbage.
const MAGIC: [u8; 8] = *b"WISQSNP\x01";

/// The CPU words the snapshot carries: `x[0..32]` then the sixteen control
/// registers, in the order [`Core`] declares them.
const CORE_WORDS: usize = 48;

/// If [`Core`] grows a field, this stops the crate from compiling.
///
/// A snapshot that silently omits a new register restores a machine that is
/// subtly not the one that was saved — the worst kind of bug, because it
/// boots. Catching it at compile time costs one line and makes forgetting
/// impossible rather than unlikely.
const _: () = assert!(std::mem::size_of::<Core>() == CORE_WORDS * 4);

#[derive(Debug, PartialEq, Eq, Clone, Copy)]
pub enum SnapshotError {
    /// Not a wisq snapshot, or one from a version this build cannot read.
    NotASnapshot,
    /// Truncated, or the sections disagree about their own lengths.
    Corrupt,
    /// Saved from a machine with a different amount of RAM. Restoring it into
    /// this one would leave the guest's memory map describing memory that is
    /// not there.
    RamSizeMismatch { saved: u64, expected: u64 },
}

impl std::fmt::Display for SnapshotError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            SnapshotError::NotASnapshot => write!(f, "ce n'est pas un instantané wisq"),
            SnapshotError::Corrupt => write!(f, "instantané tronqué ou incohérent"),
            SnapshotError::RamSizeMismatch { saved, expected } => write!(
                f,
                "instantané pris avec {saved} octets de RAM, machine actuelle {expected}"
            ),
        }
    }
}

impl std::error::Error for SnapshotError {}

// MARK: - Writing

pub(crate) struct Writer {
    bytes: Vec<u8>,
}

impl Writer {
    pub(crate) fn new() -> Self {
        Writer {
            bytes: MAGIC.to_vec(),
        }
    }

    pub(crate) fn core(&mut self, core: &Core) {
        for word in core_words(core) {
            self.u32(word);
        }
    }

    pub(crate) fn u32(&mut self, value: u32) {
        self.bytes.extend_from_slice(&value.to_le_bytes());
    }

    pub(crate) fn u64(&mut self, value: u64) {
        self.bytes.extend_from_slice(&value.to_le_bytes());
    }

    pub(crate) fn bytes(&mut self, data: &[u8]) {
        self.u64(data.len() as u64);
        self.bytes.extend_from_slice(data);
    }

    /// RAM, with runs of zeros folded to a count.
    ///
    /// Guest RAM is 64 MB and a booted Linux has touched a small fraction of
    /// it; the rest is the zero the mapping started as. The encoding is a
    /// sequence of (zeros, literal) pairs, which costs sixteen bytes per pair
    /// on dense data and saves tens of megabytes on real ones.
    pub(crate) fn ram(&mut self, ram: &[u8]) {
        self.u64(ram.len() as u64);
        let start = self.bytes.len();
        self.u64(0); // pair count, filled in below
        let mut pairs = 0u64;
        let mut index = 0;
        while index < ram.len() {
            let zeros_from = index;
            while index < ram.len() && ram[index] == 0 {
                index += 1;
            }
            let zeros = (index - zeros_from) as u64;
            let literal_from = index;
            while index < ram.len() && ram[index] != 0 {
                index += 1;
            }
            self.u64(zeros);
            self.bytes(&ram[literal_from..index]);
            pairs += 1;
        }
        self.bytes[start..start + 8].copy_from_slice(&pairs.to_le_bytes());
    }

    pub(crate) fn finish(self) -> Vec<u8> {
        self.bytes
    }
}

// MARK: - Reading

pub(crate) struct Reader<'a> {
    bytes: &'a [u8],
    at: usize,
}

impl<'a> Reader<'a> {
    pub(crate) fn new(bytes: &'a [u8]) -> Result<Self, SnapshotError> {
        if bytes.len() < MAGIC.len() || bytes[..MAGIC.len()] != MAGIC {
            return Err(SnapshotError::NotASnapshot);
        }
        Ok(Reader {
            bytes,
            at: MAGIC.len(),
        })
    }

    pub(crate) fn u32(&mut self) -> Result<u32, SnapshotError> {
        let end = self.at.checked_add(4).ok_or(SnapshotError::Corrupt)?;
        let slice = self.bytes.get(self.at..end).ok_or(SnapshotError::Corrupt)?;
        self.at = end;
        Ok(u32::from_le_bytes(slice.try_into().unwrap()))
    }

    pub(crate) fn u64(&mut self) -> Result<u64, SnapshotError> {
        let end = self.at.checked_add(8).ok_or(SnapshotError::Corrupt)?;
        let slice = self.bytes.get(self.at..end).ok_or(SnapshotError::Corrupt)?;
        self.at = end;
        Ok(u64::from_le_bytes(slice.try_into().unwrap()))
    }

    pub(crate) fn bytes(&mut self) -> Result<&'a [u8], SnapshotError> {
        let len = usize::try_from(self.u64()?).map_err(|_| SnapshotError::Corrupt)?;
        let end = self.at.checked_add(len).ok_or(SnapshotError::Corrupt)?;
        let slice = self.bytes.get(self.at..end).ok_or(SnapshotError::Corrupt)?;
        self.at = end;
        Ok(slice)
    }

    pub(crate) fn core(&mut self, core: &mut Core) -> Result<(), SnapshotError> {
        let mut words = [0u32; CORE_WORDS];
        for word in &mut words {
            *word = self.u32()?;
        }
        set_core_words(core, &words);
        Ok(())
    }

    /// Fills `ram` from the snapshot. The buffer must already be the saved
    /// size; the caller checks that and reports the mismatch, because it knows
    /// what the current machine is.
    pub(crate) fn ram(&mut self, ram: &mut [u8]) -> Result<(), SnapshotError> {
        let saved = self.u64()?;
        if saved != ram.len() as u64 {
            return Err(SnapshotError::RamSizeMismatch {
                saved,
                expected: ram.len() as u64,
            });
        }
        let pairs = self.u64()?;
        ram.fill(0);
        let mut at = 0usize;
        for _ in 0..pairs {
            let zeros = usize::try_from(self.u64()?).map_err(|_| SnapshotError::Corrupt)?;
            at = at.checked_add(zeros).ok_or(SnapshotError::Corrupt)?;
            let literal = self.bytes()?;
            let end = at
                .checked_add(literal.len())
                .ok_or(SnapshotError::Corrupt)?;
            let target = ram.get_mut(at..end).ok_or(SnapshotError::Corrupt)?;
            target.copy_from_slice(literal);
            at = end;
        }
        Ok(())
    }

    /// Refuses trailing bytes. A snapshot with something after its last
    /// section is one this build does not fully understand.
    pub(crate) fn finish(self) -> Result<(), SnapshotError> {
        if self.at == self.bytes.len() {
            Ok(())
        } else {
            Err(SnapshotError::Corrupt)
        }
    }
}

// MARK: - The CPU, as words

fn core_words(core: &Core) -> [u32; CORE_WORDS] {
    let mut words = [0u32; CORE_WORDS];
    words[..32].copy_from_slice(&core.x);
    words[32] = core.pc;
    words[33] = core.mstatus;
    words[34] = core.cyclel;
    words[35] = core.cycleh;
    words[36] = core.timerl;
    words[37] = core.timerh;
    words[38] = core.timermatchl;
    words[39] = core.timermatchh;
    words[40] = core.mscratch;
    words[41] = core.mtvec;
    words[42] = core.mie;
    words[43] = core.mip;
    words[44] = core.mepc;
    words[45] = core.mtval;
    words[46] = core.mcause;
    words[47] = core.extraflags;
    words
}

fn set_core_words(core: &mut Core, words: &[u32; CORE_WORDS]) {
    core.x.copy_from_slice(&words[..32]);
    core.pc = words[32];
    core.mstatus = words[33];
    core.cyclel = words[34];
    core.cycleh = words[35];
    core.timerl = words[36];
    core.timerh = words[37];
    core.timermatchl = words[38];
    core.timermatchh = words[39];
    core.mscratch = words[40];
    core.mtvec = words[41];
    core.mie = words[42];
    core.mip = words[43];
    core.mepc = words[44];
    core.mtval = words[45];
    core.mcause = words[46];
    core.extraflags = words[47];
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The encoding has to survive the shapes real RAM takes: all zero, no
    /// zero, and the alternation in between — including a buffer that ends
    /// mid-run either way.
    #[test]
    fn zero_runs_round_trip_whatever_the_shape() {
        let shapes: Vec<Vec<u8>> = vec![
            vec![0; 4096],
            (1..=255u8).cycle().take(4096).collect(),
            {
                let mut v = vec![0u8; 4096];
                v[0] = 1;
                v[4095] = 2;
                v
            },
            {
                let mut v = vec![0u8; 1000];
                v.extend([7u8; 10]);
                v.extend(vec![0u8; 1000]);
                v
            },
            vec![],
            vec![9],
            vec![0],
        ];
        for shape in shapes {
            let mut writer = Writer::new();
            writer.ram(&shape);
            let bytes = writer.finish();

            let mut back = vec![0xAAu8; shape.len()];
            let mut reader = Reader::new(&bytes).expect("magie");
            reader.ram(&mut back).expect("relecture");
            reader.finish().expect("pas de reste");
            assert_eq!(back, shape, "forme de {} octets", shape.len());
        }
    }

    #[test]
    fn folding_zeros_actually_shrinks_a_sparse_image() {
        let mut ram = vec![0u8; 1 << 20];
        ram[..4096].fill(0xAB);
        let mut writer = Writer::new();
        writer.ram(&ram);
        let encoded = writer.finish().len();
        assert!(
            encoded < ram.len() / 100,
            "1 Mio dont 4 Kio utiles doit tenir en moins de 10 Kio, obtenu {encoded}"
        );
    }

    #[test]
    fn a_foreign_buffer_is_refused_rather_than_read() {
        assert_eq!(Reader::new(b"").err(), Some(SnapshotError::NotASnapshot));
        assert_eq!(
            Reader::new(b"pas un instantane du tout").err(),
            Some(SnapshotError::NotASnapshot)
        );
    }

    /// Every truncation of a valid snapshot must be refused. A reader that
    /// walks off the end of a short buffer is the bug this whole module would
    /// otherwise invite, since the input is a file the user can hand us.
    #[test]
    fn every_truncation_is_refused() {
        let mut writer = Writer::new();
        writer.core(&Core::new());
        writer.ram(&{
            let mut ram = vec![0u8; 512];
            ram[100..110].fill(3);
            ram
        });
        let full = writer.finish();

        for cut in 0..full.len() {
            let short = &full[..cut];
            let outcome = Reader::new(short).and_then(|mut reader| {
                let mut core = Core::new();
                reader.core(&mut core)?;
                let mut ram = vec![0u8; 512];
                reader.ram(&mut ram)?;
                reader.finish()
            });
            assert!(outcome.is_err(), "troncature à {cut} octets acceptée");
        }
    }

    #[test]
    fn the_cpu_comes_back_word_for_word() {
        let mut core = Core::new();
        for (index, register) in core.x.iter_mut().enumerate() {
            *register = 0x1000 + index as u32;
        }
        core.pc = 0x8000_0004;
        core.mstatus = 0x1800;
        core.cyclel = 12345;
        core.cycleh = 1;
        core.timerl = 999;
        core.timerh = 2;
        core.timermatchl = 1000;
        core.timermatchh = 3;
        core.mscratch = 0xDEAD;
        core.mtvec = 0xBEEF;
        core.mie = 0x80;
        core.mip = 0x80;
        core.mepc = 0x8000_0000;
        core.mtval = 0x42;
        core.mcause = 7;
        core.extraflags = 3;

        let mut writer = Writer::new();
        writer.core(&core);
        let bytes = writer.finish();

        let mut back = Core::new();
        let mut reader = Reader::new(&bytes).expect("magie");
        reader.core(&mut back).expect("relecture");
        reader.finish().expect("pas de reste");

        assert_eq!(core_words(&core), core_words(&back));
    }
}
