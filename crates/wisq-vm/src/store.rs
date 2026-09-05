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
//! **The overlay is two files.** `writes` is a sparse file the size of the
//! base, where every written sector sits at its own offset; `writes.map` is
//! one bit per sector saying which sectors to read from the overlay instead
//! of the base. Both are written on every guest write, before the device
//! answers: an app killed without notice loses nothing the guest had already
//! written. `flush` adds `fsync` for the trip to the background.

use std::fs::{File, OpenOptions};
use std::os::unix::fs::FileExt;
use std::path::Path;

pub const SECTOR: u64 = 512;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StoreError {
    /// The base could not be opened.
    CannotOpenBase,
    /// Less than a sector: the guest would see a zero-sector disk.
    NotADisk,
    /// The overlay could not be created or opened.
    CannotOpenOverlay,
    /// The map is not the size of this base: this overlay belongs to another
    /// disk, and reading it would hand out another file's sectors.
    OverlayBelongsToAnotherDisk,
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
            Store::File(file) => file.written_sectors * SECTOR,
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
    /// One bit per sector, in memory; every changed byte goes straight back
    /// to the map file.
    bitmap: Vec<u8>,
    written_sectors: u64,
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
        let map_bytes = usize::try_from(sectors.div_ceil(8)).map_err(|_| StoreError::NotADisk)?;

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
        let mut bitmap = vec![0u8; map_bytes];
        if map_size == 0 {
            // A new map: everything comes from the base. Written whole at once,
            // so that its size says which disk it belongs to.
            map.write_all_at(&bitmap, 0)
                .map_err(|_| StoreError::CannotOpenOverlay)?;
        } else if map_size != map_bytes as u64 {
            return Err(StoreError::OverlayBelongsToAnotherDisk);
        } else {
            map.read_exact_at(&mut bitmap, 0)
                .map_err(|_| StoreError::CannotOpenOverlay)?;
        }
        let written_sectors = bitmap.iter().map(|byte| u64::from(byte.count_ones())).sum();

        Ok(FileStore {
            base,
            writes,
            map,
            sectors,
            bitmap,
            written_sectors,
        })
    }

    fn is_written(&self, sector: u64) -> bool {
        self.bitmap[(sector >> 3) as usize] & (1 << (sector & 7)) != 0
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
        // Sector by sector, because the source can change at each one.
        while done < count {
            let sector = at / SECTOR;
            let within = (at % SECTOR) as usize;
            let take = (count - done).min(SECTOR as usize - within);
            let source = if self.is_written(sector) {
                &self.writes
            } else {
                &self.base
            };
            source.read_exact_at(&mut out[done..done + take], at).ok()?;
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
            let sector_start = sector * SECTOR;

            // A whole sector every time. The first pass over a sector copies
            // the base, otherwise the bytes not written would read the sparse
            // file's zero where the base had something.
            let mut whole = [0u8; SECTOR as usize];
            if take < SECTOR as usize {
                let source = if self.is_written(sector) {
                    &self.writes
                } else {
                    &self.base
                };
                if source.read_exact_at(&mut whole, sector_start).is_err() {
                    return false;
                }
            }
            whole[within..within + take].copy_from_slice(&bytes[done..done + take]);
            if self.writes.write_all_at(&whole, sector_start).is_err() {
                return false;
            }

            if !self.is_written(sector) {
                let index = (sector >> 3) as usize;
                self.bitmap[index] |= 1 << (sector & 7);
                self.written_sectors += 1;
                // The bit goes straight away: it is what makes the sector
                // visible at the next opening.
                if self
                    .map
                    .write_all_at(&self.bitmap[index..=index], index as u64)
                    .is_err()
                {
                    return false;
                }
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

    #[test]
    fn the_overlay_is_sparse_and_the_map_is_one_bit_per_sector() {
        let folder = Folder::new("sparse");
        let mut store = open(&folder.base(4000, "base.img"), &folder.writes());
        assert!(store.write(3999 * 512, &[1; 512]));
        store.flush();
        let mut map_path = folder.writes().into_os_string();
        map_path.push(".map");
        let map = std::fs::read(map_path).unwrap();
        assert_eq!(map.len(), 500);
        assert_eq!(map[499], 0x80);
        assert_eq!(store.bytes_written(), 512);
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
