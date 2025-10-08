// SPDX-License-Identifier: Apache-2.0
// Copyright 2025 Benjamin Chess
use std::path::{Path, PathBuf};
use std::io::{Read, BufReader};
use std::fs::{OpenOptions, File};
use std::os::unix::fs::OpenOptionsExt;
use std::sync::{Arc, atomic::AtomicBool};
use dashmap::{DashMap, DashSet};
use crossbeam::channel::{unbounded, Receiver, Sender};
use tokio::sync::Notify;

pub type ByteArray = Vec<u8>;

#[derive(Copy, Clone, Debug, Eq, PartialEq)]
pub enum WalMode {
    None,
    Async,
    Sync,
}

/// A single WAL record. `value == None` represents a deletion.
#[derive(Clone, Debug)]
pub struct WalRecord {
    pub rev: i64,
    pub key: ByteArray,
    pub value: Option<Vec<u8>>, // raw bytes to avoid sharing reference counts across threads
    pub written_notify: Option<Arc<Notify>>,
}

impl WalRecord {
    // Record layout (little endian):
    // <u64 rev><u32 key_len><u32 value_len><key bytes><value bytes>
    // If `value_len` == `DELETE_MARKER`, the entry represents a delete.
    pub const DELETE_MARKER: u32 = u32::MAX;

    pub fn read_from(reader: &mut impl Read) -> std::io::Result<Option<Self>> {
        let mut header = [0u8; 16];
        match reader.read_exact(&mut header) {
            Ok(()) => {}
            Err(ref e) if e.kind() == std::io::ErrorKind::UnexpectedEof => return Ok(None),
            Err(e) => return Err(e),
        }
        let rev = u64::from_le_bytes(header[0..8].try_into().unwrap()) as i64;
        let key_len = u32::from_le_bytes(header[8..12].try_into().unwrap()) as usize;
        let value_len_raw = u32::from_le_bytes(header[12..16].try_into().unwrap());

        let mut key = vec![0u8; key_len];
        reader.read_exact(&mut key)?;

        let value = if value_len_raw == Self::DELETE_MARKER {
            None
        } else {
            let mut v = vec![0u8; value_len_raw as usize];
            reader.read_exact(&mut v)?;
            Some(v)
        };

        Ok(Some(WalRecord { rev, key, value, written_notify: None }))
    }
}

pub struct WalManager {
    wal_dir: PathBuf,
    default_mode: WalMode,
    prefix_modes_no_persist: DashSet<ByteArray>, // per-prefix overrides
    writers: DashMap<ByteArray, Arc<PerPrefixWriter>>,
    writers_with_work_tx: Sender<Arc<PerPrefixWriter>>,
}

impl WalManager {
    pub fn new(wal_dir: &Path, default_mode: WalMode, prefix_modes_no_persist: DashSet<ByteArray>) -> std::io::Result<Self> {
        let wal_dir = wal_dir.to_path_buf();
        std::fs::create_dir_all(&wal_dir)?;

        let (tx, rx) = unbounded();

        let s = Self {
            wal_dir: wal_dir,
            default_mode,
            prefix_modes_no_persist: prefix_modes_no_persist,
            writers: DashMap::new(),
            writers_with_work_tx: tx.clone(),
        };

        Self::spawn_writer_threads(rx, tx);
        Ok(s)
    }

    fn spawn_writer_threads(writers_with_work_rx: Receiver<Arc<PerPrefixWriter>>, writers_with_work_tx: Sender<Arc<PerPrefixWriter>>) {
        for _ in 0..std::thread::available_parallelism().unwrap().get() {
            let rx = writers_with_work_rx.clone();
            let tx = writers_with_work_tx.clone();
            std::thread::spawn(move || {
                while let Ok(writer) = rx.recv() {
                    if writer.to_write_rx.is_empty() {
                        // no work to do
                        continue;
                    }
                    if writer.is_writing.compare_exchange(false, true, std::sync::atomic::Ordering::SeqCst, std::sync::atomic::Ordering::SeqCst).is_err() {
                        // is already writing
                        continue;
                    }
                    writer.write_locked().unwrap();
                    writer.is_writing.store(false, std::sync::atomic::Ordering::SeqCst);
                    if !writer.to_write_rx.is_empty() {
                        // if writer didn't write everything there is still more work to do
                        tx.send(writer.clone()).unwrap();
                    }
                }
            });
        };
    }

    pub fn default_mode(&self) -> WalMode {
        self.default_mode
    }

    // append is to be called in rev order
    pub fn append(&self, prefix: &[u8], rev: i64, key: &[u8], value: Option<&[u8]>, written_notify: Option<Arc<Notify>>) {
        if self.default_mode == WalMode::None || self.prefix_modes_no_persist.contains(prefix) {
            return;
        }

        let writer = self.writers.entry(prefix.to_vec()).or_insert_with(||
            Arc::new(PerPrefixWriter::open_for_prefix(&self.wal_dir, &prefix, self.default_mode).expect("open WAL file"))
        );
        writer.to_write_tx.send(WalRecord { rev, key: key.to_vec(), value: value.map(|v| v.to_vec()), written_notify }).unwrap();
        self.writers_with_work_tx.send(writer.clone()).unwrap();
    }

}

struct PerPrefixWriter {
    fd: libc::c_int,
    _path: PathBuf,
    is_writing: Arc<AtomicBool>,
    to_write_tx: Sender<WalRecord>,
    to_write_rx: Receiver<WalRecord>,
    mode: WalMode,
}

impl PerPrefixWriter {
    fn open_for_prefix(wal_dir: &Path, prefix: &[u8], mode: WalMode) -> std::io::Result<Self> {
        let path = wal_dir.join(Self::file_name_for_prefix(prefix));
        if let Some(parent) = path.parent() { std::fs::create_dir_all(parent)?; }
        let file = OpenOptions::new()
            .create(true)
            .read(true)
            .append(true)
            .custom_flags(libc::O_NOATIME | libc::O_CLOEXEC)
            .open(&path)?;
        let fd = file.as_raw_fd();
        std::mem::forget(file); // Keep FD open; File would close on drop
        let (tx, rx) = unbounded();
        Ok(Self {
            fd,
            _path: path,
            is_writing: Arc::new(AtomicBool::new(false)),
            to_write_tx: tx,
            to_write_rx: rx,
            mode,
        })
    }

    fn file_name_for_prefix(prefix: &[u8]) -> String {
        // Encode prefix bytes as hex to make a safe filename
        let mut s = String::from("prefix_");
        for b in prefix { s.push_str(&format!("{:02x}", b)); }
        s.push_str(".wal");
        s
    }

    fn write_locked(&self) -> std::io::Result<()> {
        // TODO: change based on mode
        // TODO: maybe use deadlines based on enqueue time
        let end_time = std::time::Instant::now() + std::time::Duration::from_micros(500);
        let end_size = 16384;

        let mut current_size = 0;
        let mut iovs_vec: Vec<libc::iovec> = Vec::with_capacity(16);
        let mut notify_vec: Vec<Arc<Notify>> = Vec::with_capacity(16);

        // Batch up things to write
        while current_size < end_size && std::time::Instant::now() < end_time {
            let mut rec = match self.to_write_rx.recv_deadline(end_time) {
                Ok(rec) => rec,
                Err(_) => break,
            };

            // Build header and iovecs from provided slices
            let key_bytes: &[u8] = &rec.key;
            let val_opt: Option<&[u8]> = rec.value.as_deref();
            let key_len = key_bytes.len() as u32;
            let value_len = val_opt.map(|v| v.len() as u32).unwrap_or(WalRecord::DELETE_MARKER);
            let mut header = [0u8; 16];
            header[0..8].copy_from_slice(&(rec.rev as u64).to_le_bytes());
            header[8..12].copy_from_slice(&key_len.to_le_bytes());
            header[12..16].copy_from_slice(&value_len.to_le_bytes());

            let iov0 = libc::iovec { iov_base: header.as_ptr() as *mut _, iov_len: header.len() };
            let iov1 = if key_len > 0 { Some(libc::iovec { iov_base: key_bytes.as_ptr() as *mut _, iov_len: key_bytes.len() }) } else { None };
            let iov2 = match val_opt { Some(v) if !v.is_empty() => Some(libc::iovec { iov_base: v.as_ptr() as *mut _, iov_len: v.len() }), _ => None };
            iovs_vec.push(iov0);
            if let Some(k) = iov1 { iovs_vec.push(k); }
            if let Some(v) = iov2 { iovs_vec.push(v); }

            current_size += rec.key.len() + rec.value.as_ref().map_or(0, |v| v.len()) + 16; // 16 is header size

            if let Some(notify) = rec.written_notify.take() {
                notify_vec.push(notify);
            }
        }

        let mut remaining = current_size;
        let mut iovs_offset = 0;
        while remaining > 0 {
            let res = unsafe { libc::writev(self.fd, iovs_vec.as_ptr().add(iovs_offset), iovs_vec.len() as i32) };
            if res < 0 {
                let err = std::io::Error::last_os_error();
                if err.kind() == std::io::ErrorKind::Interrupted { continue; }
                return Err(err);
            }
            let mut wrote = res as usize;
            remaining -= wrote;
            if remaining == 0 {
                // Most common that we wrote everything
                break;
            }
            while wrote > 0 {
                if wrote >= iovs_vec[iovs_offset].iov_len as usize {
                    wrote -= iovs_vec[iovs_offset].iov_len as usize;
                    iovs_offset += 1;
                } else {
                    iovs_vec[iovs_offset].iov_len -= wrote;
                    iovs_vec[iovs_offset].iov_base = unsafe { (iovs_vec[iovs_offset].iov_base as *mut u8).add(wrote) } as *mut _;
                    wrote = 0;
                }
            }
        }
        if self.mode == WalMode::Sync {
            unsafe { libc::fsync(self.fd); }
        }

        for notify in notify_vec {
            notify.notify_one();
        }

        Ok(())
    }
}

use std::os::fd::AsRawFd;

/// Utilities for reading per-prefix WAL files from a directory and replaying them
pub fn load_wal_dir<F>(wal_dir: &Path, mut on_entry: F) -> std::io::Result<()>
where
    F: FnMut(WalRecord),
{
    let mut readers: Vec<(i32, BufReader<File>, Option<WalRecord>)> = vec![];
    if !wal_dir.exists() { return Ok(()); }
    for entry in std::fs::read_dir(wal_dir)? {
        let entry = entry?;
        let path = entry.path();
        if path.is_file() && path.extension().and_then(|e| e.to_str()) == Some("wal") {
            let file = File::open(&path)?;
            let mut reader = BufReader::new(file);
            let next = WalRecord::read_from(&mut reader)?;
            readers.push((0, reader, next));
        }
    }

    // Min-heap by rev
    use std::cmp::Ordering;
    use std::collections::BinaryHeap;
    #[derive(Debug)]
    struct HeapItem { idx: usize, rev: i64 }
    impl PartialEq for HeapItem { fn eq(&self, other: &Self) -> bool { self.rev == other.rev } }
    impl Eq for HeapItem {}
    impl PartialOrd for HeapItem { fn partial_cmp(&self, other: &Self) -> Option<Ordering> { Some(other.rev.cmp(&self.rev)) } }
    impl Ord for HeapItem { fn cmp(&self, other: &Self) -> Ordering { other.rev.cmp(&self.rev) } }

    let mut heap = BinaryHeap::new();
    for (i, (_, _, rec_opt)) in readers.iter().enumerate() {
        if let Some(rec) = rec_opt { heap.push(HeapItem { idx: i, rev: rec.rev }); }
    }

    while let Some(HeapItem { idx, .. }) = heap.pop() {
        let (_, reader, rec_opt) = &mut readers[idx];
        if let Some(rec) = rec_opt.take() {
            on_entry(rec);
            // load next for this reader
            let next = WalRecord::read_from(reader)?;
            readers[idx].2 = next;
            if let Some(rec) = &readers[idx].2 { heap.push(HeapItem { idx, rev: rec.rev }); }
        }
    }

    Ok(())
}