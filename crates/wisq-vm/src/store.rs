//! Where a disk's bytes live: in memory, or in a file with a write overlay.
//!
//! A port of `DiskStore` from the Swift side, byte for byte on the overlay
//! format. The two are not free to differ: the app opens the same `writes`
//! and `writes.map` files on either core, and a differential test compares
//! the two overlays after the same guest program wrote through them.
//!
//! **The base never changes.** It is opened read-only; every read is a
//! `pread` at the asked offset, and nothing of it is copied into memory —
//! which is what lets a multi-gigabyte installer image be attached at all.
//!
//! **The overlay is two files, and it is packed.** `writes` holds the written
//! sectors back to back **in the order they were written**: the n-th sector
//! touched takes the n-th slot, whatever its number on the disk.
//! `writes.map` says which sector is in which slot — a header, then one
//! eight-byte sector number per slot.
//!
//! **The first attempt put each sector at its own offset** in a sparse file
//! the size of the base, trusting the filesystem to allocate nothing between
//! the holes. **APFS allocates.** Measured on macOS: one sector written two
//! mebibytes in cost 2,052,096 bytes. APFS is also the iPhone's filesystem,
//! so the only measurement that counted said the idea did not hold. Packed,
//! the overlay costs 512 bytes per sector touched, on any filesystem, because
//! it no longer asks anything of anyone.
//!
//! **Every write is durable when it is made.** The sector goes into `writes`,
//! then its number into `writes.map`, before the device answers the guest.
//! **In that order**, and the order is what makes a sudden death harmless: a
//! slot written but not yet named belongs to nobody, is ignored at the next
//! opening, and the next sector takes its place. The other way round would
//! leave a named slot whose content does not exist. `flush` adds `fsync`.

use std::fs::{File, OpenOptions};
use std::os::unix::fs::FileExt;
use std::path::Path;

pub const SECTOR: u64 = 512;
/// Eight bytes saying what this file is for, then the base's sector count:
/// **that** is what ties an overlay to its disk. Size could not do it once the
/// overlay was packed, and trusting size would have let two disks of the same
/// sector count pass for each other.
const MAGIC: &[u8; 8] = b"wisqdisk";
const HEADER: u64 = 16;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StoreError {
    /// The base could not be opened.
    CannotOpenBase,
    /// Less than a sector: the guest would see a zero-sector disk.
    NotADisk,
    /// The overlay could not be created or opened.
    CannotOpenOverlay,
    /// The map's header does not describe this base: this overlay belongs to
    /// another disk, and reading it would hand out another file's sectors.
    OverlayBelongsToAnotherDisk,
    /// The map names slots the writes file does not have: it was truncated,
    /// and the bytes the guest believes it wrote are gone.
    OverlayIsTruncated,
}

pub enum Store {
    Memory(Vec<u8>),
    File(FileStore),
}

impl Store {
    pub fn sectors(&self) -> u64 {
        match self {
            Store::Memory(image) => image.len() as u64 / SECTOR,
            Store::File(file) => file.sectors,
        }
    }

    /// `count` bytes from a byte offset, or `None` past the end: the device
    /// then answers an error status, as a real disk asked for a sector it
    /// does not have.
    pub fn read(&self, offset: u64, count: usize) -> Option<Vec<u8>> {
        match self {
            Store::Memory(image) => {
                let start = usize::try_from(offset).ok()?;
                let end = start.checked_add(count)?;
                image.get(start..end).map(<[u8]>::to_vec)
            }
            Store::File(file) => file.read(offset, count),
        }
    }

    /// Writes bytes. False past the end, and nothing is written then.
    pub fn write(&mut self, offset: u64, bytes: &[u8]) -> bool {
        match self {
            Store::Memory(image) => {
                let Ok(start) = usize::try_from(offset) else {
                    return false;
                };
                let Some(end) = start.checked_add(bytes.len()) else {
                    return false;
                };
                match image.get_mut(start..end) {
                    Some(slot) => {
                        slot.copy_from_slice(bytes);
                        true
                    }
                    None => false,
                }
            }
            Store::File(file) => file.write(offset, bytes),
        }
    }

    pub fn flush(&self) {
        if let Store::File(file) = self {
            file.flush();
        }
    }

    /// How many bytes the guest changed — what the storage report shows. A
    /// memory store answers the size of its image: that is what the snapshot
    /// carries.
    pub fn bytes_written(&self) -> u64 {
        match self {
            Store::Memory(image) => image.len() as u64,
            Store::File(file) => file.used * SECTOR,
        }
    }

    /// The whole content, for tests and measurements. A six-gigabyte disk is
    /// not asked for this way.
    pub fn image(&self) -> Vec<u8> {
        self.read(0, (self.sectors() * SECTOR) as usize)
            .unwrap_or_default()
    }
}

pub struct FileStore {
    base: File,
    writes: File,
    map: File,
    pub sectors: u64,
    /// Which slot holds which sector. In memory only: the map on disk is the
    /// list of sectors, in slot order.
    slots: std::collections::HashMap<u64, u64>,
    used: u64,
}

impl FileStore {
    pub fn open(base_path: &Path, writes_path: &Path) -> Result<FileStore, StoreError> {
        let base = File::open(base_path).map_err(|_| StoreError::CannotOpenBase)?;
        let size = base
            .metadata()
            .map_err(|_| StoreError::CannotOpenBase)?
            .len();
        if size < SECTOR {
            return Err(StoreError::NotADisk);
        }
        let sectors = size / SECTOR;

        let mut options = OpenOptions::new();
        options.read(true).write(true).create(true).truncate(false);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let writes = options
            .open(writes_path)
            .map_err(|_| StoreError::CannotOpenOverlay)?;
        let mut map_path = writes_path.as_os_str().to_owned();
        map_path.push(".map");
        let map = options
            .open(Path::new(&map_path))
            .map_err(|_| StoreError::CannotOpenOverlay)?;

        let map_size = map
            .metadata()
            .map_err(|_| StoreError::CannotOpenOverlay)?
            .len();
        let writes_size = writes
            .metadata()
            .map_err(|_| StoreError::CannotOpenOverlay)?
            .len();

        let mut slots = std::collections::HashMap::new();
        let mut used = 0u64;
        if map_size == 0 {
            let mut header = [0u8; HEADER as usize];
            header[..8].copy_from_slice(MAGIC);
            header[8..].copy_from_slice(&sectors.to_le_bytes());
            map.write_all_at(&header, 0)
                .map_err(|_| StoreError::CannotOpenOverlay)?;
        } else {
            if map_size < HEADER {
                return Err(StoreError::OverlayBelongsToAnotherDisk);
            }
            let mut header = [0u8; HEADER as usize];
            map.read_exact_at(&mut header, 0)
                .map_err(|_| StoreError::CannotOpenOverlay)?;
            if &header[..8] != MAGIC {
                return Err(StoreError::OverlayBelongsToAnotherDisk);
            }
            let declared = u64::from_le_bytes(header[8..].try_into().expect("huit octets"));
            if declared != sectors {
                return Err(StoreError::OverlayBelongsToAnotherDisk);
            }
            // **The two files can only disagree one way.** The content goes
            // before the name, so there can be one more slot than names: that
            // is the app killed between the two, and that slot belongs to
            // nobody — it is ignored, and the next sector takes its place.
            //
            // The other way cannot be produced honestly: a name whose content
            // is missing means the writes file was truncated under us. Refuse
            // the overlay rather than choose between two wrong answers.
            let named = (map_size - HEADER) / 8;
            let stored = writes_size / SECTOR;
            if named > stored {
                return Err(StoreError::OverlayIsTruncated);
            }
            let count = named;
            if count > 0 {
                let mut bytes = vec![0u8; (count * 8) as usize];
                map.read_exact_at(&mut bytes, HEADER)
                    .map_err(|_| StoreError::CannotOpenOverlay)?;
                for slot in 0..count {
                    let at = (slot * 8) as usize;
                    let sector =
                        u64::from_le_bytes(bytes[at..at + 8].try_into().expect("huit octets"));
                    slots.insert(sector, slot);
                }
                used = count;
            }
        }

        Ok(FileStore {
            base,
            writes,
            map,
            sectors,
            slots,
            used,
        })
    }

    fn in_range(&self, offset: u64, count: usize) -> bool {
        let size = self.sectors * SECTOR;
        offset <= size && count as u64 <= size - offset
    }

    fn read(&self, offset: u64, count: usize) -> Option<Vec<u8>> {
        if !self.in_range(offset, count) {
            return None;
        }
        let mut out = vec![0u8; count];
        let mut done = 0usize;
        let mut at = offset;
        // Sector by sector, because the source changes at each one.
        while done < count {
            let sector = at / SECTOR;
            let within = at % SECTOR;
            let take = (count - done).min((SECTOR - within) as usize);
            let (source, from) = match self.slots.get(&sector) {
                Some(slot) => (&self.writes, slot * SECTOR + within),
                None => (&self.base, at),
            };
            source
                .read_exact_at(&mut out[done..done + take], from)
                .ok()?;
            done += take;
            at += take as u64;
        }
        Some(out)
    }

    fn write(&mut self, offset: u64, bytes: &[u8]) -> bool {
        if !self.in_range(offset, bytes.len()) {
            return false;
        }
        let mut done = 0usize;
        let mut at = offset;
        while done < bytes.len() {
            let sector = at / SECTOR;
            let within = (at % SECTOR) as usize;
            let take = (bytes.len() - done).min(SECTOR as usize - within);
            let existing = self.slots.get(&sector).copied();
            let slot = existing.unwrap_or(self.used);

            // A whole slot every time. The first pass copies what the sector
            // was worth — the base, or the slot it already had — otherwise the
            // bytes not written would read a fresh slot's zero.
            let mut whole = [0u8; SECTOR as usize];
            if take < SECTOR as usize {
                let (source, from) = match existing {
                    Some(slot) => (&self.writes, slot * SECTOR),
                    None => (&self.base, sector * SECTOR),
                };
                if source.read_exact_at(&mut whole, from).is_err() {
                    return false;
                }
            }
            whole[within..within + take].copy_from_slice(&bytes[done..done + take]);
            if self.writes.write_all_at(&whole, slot * SECTOR).is_err() {
                return false;
            }

            if existing.is_none() {
                // The content first, the name second: a named slot whose
                // content is missing would hand out zeroes for bytes it claims
                // to have.
                if self
                    .map
                    .write_all_at(&sector.to_le_bytes(), HEADER + slot * 8)
                    .is_err()
                {
                    return false;
                }
                self.slots.insert(sector, slot);
                self.used += 1;
            }
            done += take;
            at += take as u64;
        }
        true
    }

    fn flush(&self) {
        let _ = self.writes.sync_data();
        let _ = self.map.sync_data();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    struct Folder(PathBuf);

    impl Folder {
        fn new(name: &str) -> Folder {
            let path =
                std::env::temp_dir().join(format!("wisq-store-{}-{}", name, std::process::id()));
            let _ = std::fs::remove_dir_all(&path);
            std::fs::create_dir_all(&path).unwrap();
            Folder(path)
        }

        /// A base of `sectors` sectors, each filled with its own number plus
        /// one — the same base the Swift tests use.
        fn base(&self, sectors: usize, name: &str) -> PathBuf {
            let mut bytes = vec![0u8; sectors * 512];
            for (sector, chunk) in bytes.chunks_mut(512).enumerate() {
                chunk.fill((sector + 1) as u8);
            }
            let path = self.0.join(name);
            std::fs::write(&path, bytes).unwrap();
            path
        }

        fn writes(&self) -> PathBuf {
            self.0.join("disk.writes")
        }
    }

    impl Drop for Folder {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    fn open(base: &Path, writes: &Path) -> Store {
        Store::File(FileStore::open(base, writes).unwrap())
    }

    #[test]
    fn writes_go_to_the_overlay_and_the_base_is_never_touched() {
        let folder = Folder::new("overlay");
        let base = folder.base(8, "base.img");
        let before = std::fs::read(&base).unwrap();
        let mut store = open(&base, &folder.writes());
        assert_eq!(store.sectors(), 8);
        assert_eq!(store.read(512, 4).unwrap(), [2, 2, 2, 2]);
        assert!(store.write(512, &[0xAB; 512]));
        assert_eq!(store.read(512, 4).unwrap(), [0xAB; 4]);
        assert_eq!(
            store.read(1024, 2).unwrap(),
            [3, 3],
            "the neighbour did not move"
        );
        store.flush();
        assert_eq!(std::fs::read(&base).unwrap(), before, "the base is intact");
    }

    #[test]
    fn writes_survive_closing_and_reopening() {
        let folder = Folder::new("reopen");
        let base = folder.base(8, "base.img");
        {
            let mut store = open(&base, &folder.writes());
            assert!(store.write(3 * 512, &[0x5A; 512]));
        }
        let reopened = open(&base, &folder.writes());
        assert_eq!(reopened.read(3 * 512, 3).unwrap(), [0x5A; 3]);
        assert_eq!(
            reopened.read(2 * 512, 3).unwrap(),
            [3; 3],
            "never written: from the base"
        );
        assert_eq!(reopened.bytes_written(), 512);
    }

    #[test]
    fn a_partial_sector_write_keeps_the_rest_of_the_sector() {
        let folder = Folder::new("partial");
        let mut store = open(&folder.base(4, "base.img"), &folder.writes());
        assert!(store.write(512 + 8, &[9, 9, 9, 9]));
        let sector = store.read(512, 512).unwrap();
        assert_eq!(&sector[..8], &[2u8; 8]);
        assert_eq!(&sector[8..12], &[9, 9, 9, 9]);
        assert_eq!(&sector[12..], &[2u8; 500]);
    }

    #[test]
    fn a_write_straddling_two_sectors_lands_in_both() {
        let folder = Folder::new("straddle");
        let mut store = open(&folder.base(4, "base.img"), &folder.writes());
        assert!(store.write(1020, &[7; 8]));
        assert_eq!(
            store.read(1018, 12).unwrap(),
            [2, 2, 7, 7, 7, 7, 7, 7, 7, 7, 3, 3]
        );
        assert_eq!(store.bytes_written(), 1024);
    }

    #[test]
    fn beyond_the_end_is_refused() {
        let folder = Folder::new("beyond");
        let mut store = open(&folder.base(4, "base.img"), &folder.writes());
        assert!(store.read(4 * 512 - 2, 4).is_none());
        assert!(store.read(4 * 512, 1).is_none());
        assert!(!store.write(4 * 512, &[1]));
        assert_eq!(store.read(4 * 512 - 1, 1).unwrap(), [4]);
    }

    /// The overlay is packed, and the file's own size says so — not what the
    /// filesystem chose to allocate. The sparse-file version of this cost two
    /// mebibytes on APFS for the same single sector.
    #[test]
    fn the_overlay_is_packed_not_spread() {
        let folder = Folder::new("packed");
        let mut store = open(&folder.base(4000, "base.img"), &folder.writes());
        assert!(store.write(3999 * 512, &[1; 512]));
        store.flush();
        assert_eq!(std::fs::metadata(folder.writes()).unwrap().len(), 512);
        let mut map_path = folder.writes().into_os_string();
        map_path.push(".map");
        let map = std::fs::read(&map_path).unwrap();
        assert_eq!(map.len(), 16 + 8);
        assert_eq!(&map[..8], b"wisqdisk");
        assert_eq!(store.bytes_written(), 512);

        assert!(store.write(0, &[7, 7, 7]));
        assert!(store.write(3999 * 512, &[2; 512]));
        store.flush();
        assert_eq!(
            std::fs::metadata(folder.writes()).unwrap().len(),
            1024,
            "deux emplacements, pas trois"
        );
        assert_eq!(store.read(3999 * 512, 2).unwrap(), [2, 2]);
        assert_eq!(store.read(0, 4).unwrap(), [7, 7, 7, 1]);
    }

    /// A slot written but not yet named belongs to nobody: the app killed
    /// between the two `pwrite`s leaves the map one entry behind, and the next
    /// sector takes the orphan's place.
    #[test]
    fn a_slot_written_but_not_yet_named_is_ignored() {
        let folder = Folder::new("orphan");
        let base = folder.base(8, "base.img");
        {
            let mut store = open(&base, &folder.writes());
            assert!(store.write(512, &[0xAB; 512]));
            assert!(store.write(1024, &[0xCD; 512]));
            store.flush();
        }
        let mut map_path = folder.writes().into_os_string();
        map_path.push(".map");
        let map = std::fs::read(&map_path).unwrap();
        std::fs::write(&map_path, &map[..16 + 8]).unwrap();

        let mut reopened = open(&base, &folder.writes());
        assert_eq!(reopened.read(512, 2).unwrap(), [0xAB, 0xAB]);
        assert_eq!(
            reopened.read(1024, 2).unwrap(),
            [3, 3],
            "revient de la base"
        );
        assert_eq!(reopened.bytes_written(), 512);
        assert!(reopened.write(2048, &[0xEE; 512]));
        assert_eq!(std::fs::metadata(folder.writes()).unwrap().len(), 1024);
        assert_eq!(reopened.read(2048, 2).unwrap(), [0xEE, 0xEE]);
    }

    #[test]
    fn an_overlay_from_another_disk_is_refused() {
        let folder = Folder::new("another");
        let _ = open(&folder.base(8, "base.img"), &folder.writes());
        let other = folder.base(16, "other.img");
        assert_eq!(
            FileStore::open(&other, &folder.writes()).err(),
            Some(StoreError::OverlayBelongsToAnotherDisk)
        );
        let bogus = folder.0.join("bogus.writes");
        let mut bogus_map = bogus.clone().into_os_string();
        bogus_map.push(".map");
        std::fs::write(&bogus_map, b"pas une carte du tout").unwrap();
        assert_eq!(
            FileStore::open(&folder.base(8, "b.img"), &bogus).err(),
            Some(StoreError::OverlayBelongsToAnotherDisk)
        );
    }

    #[test]
    fn a_base_smaller_than_a_sector_is_refused() {
        let folder = Folder::new("tiny");
        let tiny = folder.0.join("tiny");
        std::fs::write(&tiny, [1, 2, 3]).unwrap();
        assert_eq!(
            FileStore::open(&tiny, &folder.writes()).err(),
            Some(StoreError::NotADisk)
        );
    }

    /// A truncated overlay is refused, not guessed: a name whose slot is gone
    /// would otherwise serve the base's stale sector without saying so.
    #[test]
    fn a_truncated_overlay_is_refused_rather_than_guessed() {
        let folder = Folder::new("truncated");
        let base = folder.base(8, "base.img");
        {
            let mut store = open(&base, &folder.writes());
            assert!(store.write(512, &[0xAB; 512]));
            assert!(store.write(1024, &[0xCD; 512]));
            store.flush();
        }
        let content = std::fs::read(folder.writes()).unwrap();
        assert_eq!(content.len(), 1024);
        std::fs::write(folder.writes(), &content[..512]).unwrap();
        assert_eq!(
            FileStore::open(&base, &folder.writes()).err(),
            Some(StoreError::OverlayIsTruncated)
        );
    }

    #[test]
    fn a_missing_base_is_refused_and_leaves_no_overlay_behind() {
        let folder = Folder::new("missing");
        assert_eq!(
            FileStore::open(&folder.0.join("nope.img"), &folder.writes()).err(),
            Some(StoreError::CannotOpenBase)
        );
        assert!(!folder.writes().exists());
    }

    #[test]
    fn a_memory_store_reads_and_writes_in_place() {
        let mut store = Store::Memory(vec![1u8; 1024]);
        assert_eq!(store.sectors(), 2);
        assert!(store.write(512, &[9, 9]));
        assert_eq!(store.read(510, 4).unwrap(), [1, 1, 9, 9]);
        assert!(!store.write(1023, &[1, 1]));
        assert!(store.read(1024, 1).is_none());
        assert_eq!(store.bytes_written(), 1024);
    }
}
