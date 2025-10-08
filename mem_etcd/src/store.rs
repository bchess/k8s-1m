// SPDX-License-Identifier: Apache-2.0
// Copyright 2025 Benjamin Chess
use dashmap::{DashMap, DashSet};
use std::collections::BTreeMap;
// use std::io::BufReader; // no longer used after switching to per-prefix WAL loader
use std::ops::Bound;
use std::ops::Bound::{Excluded, Included, Unbounded};
use std::sync::atomic::{AtomicI64, Ordering};
use std::sync::{Arc, RwLock};
use std::time::Instant;
use std::collections::BinaryHeap;
use tokio::sync::mpsc;
use tonic::Status;
use std::sync::Once;
use bytes::Bytes;
use tokio::sync::mpsc::{UnboundedSender, UnboundedReceiver};
use tokio::sync::Notify;

use crate::block_deque::BlockDeque;
use crate::mvccpb::KeyValue;
use crate::metrics;
use crate::wal::{WalManager, WalMode, load_wal_dir};

type ByteArray = Vec<u8>;

// The per-watcher buffer between the serialized notify_thread() and the async watcher tasks sending out events over gRPC streams
const WATCH_CHANNEL_SIZE: usize = 10000;

/// Represents an in-memory store that tracks revisions and watchers.
pub struct Store {
    prefix_map: DashMap<ByteArray, PrefixMapItem>,
    tree_map: DashMap<ByteArray, Arc<RwLock<TreeItem>>>,
    values_by_revision: BlockDeque<Value, 1048576>,
    watchers: RwLock<BTreeMap<(ByteArray, i64), Watcher>>,
    watch_counter: AtomicI64,

    /// Per-prefix WAL manager, initialised via `init_wal_dir` during application startup.
    wal: Option<Arc<WalManager>>,

    /// Channel used to enqueue notification jobs so they can be processed sequentially by a
    /// dedicated task, decoupling watcher latency from the hot `set` path.
    notify_tx: UnboundedSender<NotifyJob>,
    progress_rev: Arc<AtomicI64>, // The last revision that was enqueued out to watchers
}

/// Holds per-prefix data (though in this simplified example we treat each key individually).
struct PrefixMapItem {
    btree: BTreeMap<ByteArray, Arc<RwLock<TreeItem>>>,
}

/// Contains revision-tracking for a single key.
struct TreeItem {
    key: ByteArray,
    revisions: Vec<i64>,
    latest_value: Value,
}

/// Internal representation of a value.
#[derive(Clone)]
pub struct Value {
    pub create_revision: i64,
    pub mod_revision: i64,
    pub version: i64,
    pub value: Option<Bytes>
}

impl Drop for Value {
    fn drop(&mut self) {
        if let Some(v) = self.value.as_ref() {
            if v.is_unique() {
                metrics::TREE_MAP_SIZE_BYTES.sub(v.len() as i64);
            }
        }
    }
}

/// Details about a watching client, including a channel for sending key changes.
pub struct Watcher {
    pub start_revision: i64,
    pub key_range_start: ByteArray, // TODO: remove
    pub key_range_end: ByteArray,
    pub ch: mpsc::Sender<KeyValueWithPrev>,
}

#[derive(Debug)]
#[derive(Clone)]
pub struct KeyValueWithPrev {
    pub prev_kv: Option<KeyValue>,
    pub kv: KeyValue,
}

#[derive(Debug)]
#[derive(Default)]
pub struct SetRequired {
    pub required_last_revision: Option<i64>,
    pub required_version: Option<i64>,
}

pub struct RangeResult {
    pub kvs: Vec<KeyValue>,
    pub latest_rev: i64,
    pub count: i64,
}

static INIT: Once = Once::new();

struct NotifyJob {
    rev: i64,
    watchers: Vec<mpsc::Sender<KeyValueWithPrev>>, // cloned senders
    msg: KeyValueWithPrev,
    prefix_str: String,
    watch_result_size: u64,
    wal_handled: Option<Arc<Notify>>,
}

impl PartialEq for NotifyJob {
    fn eq(&self, other: &Self) -> bool {
        self.rev == other.rev
    }
}

impl Eq for NotifyJob {}

impl PartialOrd for NotifyJob {
    fn partial_cmp(&self, other: &Self) -> Option<std::cmp::Ordering> {
        Some(self.cmp(other))
    }
}

impl Ord for NotifyJob {
    fn cmp(&self, other: &Self) -> std::cmp::Ordering {
        // Note: BinaryHeap is a max-heap, so we reverse the ordering to get a min-heap
        // This ensures that jobs with lower revision numbers are processed first
        other.rev.cmp(&self.rev)
    }
}

pub struct WalSettings {
    pub wal_dir: std::path::PathBuf, // None if WAL is disabled
    pub default_mode: WalMode,
    pub load_wal_dir: bool,
    pub prefix_modes_no_persist: DashSet<ByteArray>,
}

impl Store {
    /// Create a new, empty Store.
    pub fn new(wal_settings: Option<WalSettings>) -> Self {
        // Initialize metrics so they're ready at startup
        INIT.call_once(|| {
            metrics::Metrics::init();
        });

        let mut wal: Option<Arc<WalManager>> = None;
        let mut do_load_wal_dir = false;
        let wal_settings: Option<&WalSettings> = wal_settings.as_ref();
        if let Some(wal_settings) = wal_settings {
            wal = Some(Arc::new(WalManager::new(&wal_settings.wal_dir, wal_settings.default_mode, wal_settings.prefix_modes_no_persist.clone()).expect("failed to init WAL manager")));
            do_load_wal_dir = wal_settings.load_wal_dir;
        }

        let (notify_tx, progress_rev) = Self::setup_notify_thread(wal.clone());
        let store = Store {
            prefix_map: DashMap::new(),
            tree_map: DashMap::new(),
            values_by_revision: BlockDeque::new(),
            watchers: RwLock::new(BTreeMap::new()),
            watch_counter: AtomicI64::new(0),
            wal: wal,
            notify_tx: notify_tx,
            progress_rev: progress_rev,
        };

        if do_load_wal_dir {
            let d = &wal_settings.unwrap().wal_dir;
            load_wal_dir(d, |rec| {
                let val_opt = rec.value.map(Bytes::from);
                let _ = store.set(rec.key, val_opt, None);
            }).expect("failed to load WAL dir");
        }

        store
    }


    /// Sets or updates a key-value pair.
    /// If `required_last_revision` is >= 0, then it must match the current revision or the operation fails.
    /// When required_last_revision is 0, that indicates it only works if the key does not exist or was previously deleted.
    /// If `value` is None, then the key is deleted
    pub async fn set(
        &self,
        key: ByteArray,
        value: Option<Bytes>,
        required: Option<SetRequired>
    ) -> Result<i64, (i64, Option<KeyValue>)> {
        // Start timer for "set" request
        let _timer = AlertingHistogramTimer::new(metrics::REQUEST_LATENCY
            .with_label_values(&["set"])
            .start_timer(),
            || format!("Set of {}", String::from_utf8_lossy(&key)));
        metrics::REQUEST_COUNT
            .with_label_values(&["set"])
            .inc();
        let value = value.map(|v| Bytes::from(v));

        let (prefix, suffix) = Self::prefix_split(&key);
        let latest_rev = self.current_revision();

        let required_last_revision = required.as_ref().and_then(|r| r.required_last_revision).unwrap_or(-1);
        let required_version = required.as_ref().and_then(|r| r.required_version).unwrap_or(-1);

        let placeholder_value = Value {
            create_revision: 0,
            mod_revision: 0,
            version: 1,
            value: None,
        };

        metrics::LOCK_COUNT.with_label_values(&["set", "tree_map", "write"]).inc();
        let lock_time = Instant::now();
        if let Some(item_ref) = self.tree_map.get(&key) {
            // Release the self.tree_map lock as early as possible
            let ei = item_ref.clone();
            drop(item_ref);

            let (new_rev, key_for_watchers, value_for_watchers, old_value) = {
                let mut existing_item = ei.write().unwrap();
                metrics::LOCK_TIME_SECONDS.with_label_values(&["set", "tree_map", "write"]).inc_by(lock_time.elapsed().as_secs_f64());
                // Item already exists
                if existing_item.latest_value.value.is_some() {
                    // Item is not deleted
                    if (required_last_revision >= 0
                        && required_last_revision != existing_item.latest_value.mod_revision)
                        || (required_version >= 0
                            && required_version != existing_item.latest_value.version)
                    {
                        // failed to update because the mod_revision does not match
                        return Err((
                            latest_rev,
                            Some(Self::as_mvcc_key_value(
                                existing_item.latest_value.clone(),
                                &existing_item.key,
                            )),
                        ));
                    }
                } else {
                    // Item has been deleted
                    if required_last_revision > 0 || required_version > 0 {
                        // This item does not exist, so anything but 0 for required version or rev is an error
                        return Err((latest_rev, None));
                    }
                    if value.is_none() {
                        // trying to delete a non-existent key
                        return Err((latest_rev, None));
                    }
                }

                // see if we should filter out revisions that have been compacted
                let earliest_revision = self.values_by_revision.earliest_revision() as i64;
                if existing_item.revisions.first().unwrap_or(&earliest_revision)
                    < &earliest_revision
                {
                    let earliest_idx = existing_item
                        .revisions
                        .partition_point(|v| v < &earliest_revision);
                    existing_item.revisions.drain(..earliest_idx);
                }

                // The placeholder value is temporary, it gets modified and re-set once we have the revision number
                let new_rev = self.values_by_revision.push(placeholder_value) as i64 + 1;

                metrics::TREE_MAP_SIZE_BYTES.add(value.as_ref().map(|v| v.len() as i64).unwrap_or(0));
                let mut new_value = Value {
                    create_revision: 0,
                    mod_revision: new_rev,
                    version: 0,
                    value: value
                };
                if existing_item.latest_value.value.is_some() {
                    // Modifying an existing item
                    new_value.create_revision = existing_item.latest_value.create_revision;
                    new_value.version = existing_item.latest_value.version + 1;
                } else {
                    // New item
                    new_value.create_revision = new_rev;
                    new_value.version = 1;
                }

                let old_value = existing_item.latest_value.clone();
                existing_item.latest_value = new_value;

                let key_for_watchers = existing_item.key.clone();
                let value_for_watchers = existing_item.latest_value.clone();

                self.values_by_revision
                    .set(new_rev as usize - 1, existing_item.latest_value.clone());
                existing_item.revisions.push(new_rev);

                (new_rev, key_for_watchers, value_for_watchers, old_value)
            }; // guard dropped here

            self.notify_watchers(&key_for_watchers, value_for_watchers, Some(old_value), prefix).await;

            return Ok(new_rev);
        } else {
            metrics::LOCK_TIME_SECONDS.with_label_values(&["set", "tree_map", "write"]).inc_by(lock_time.elapsed().as_secs_f64());
        }

        // Item does not exist

        if required_last_revision > 0 || required_version > 0 {
            // This item does not exist, so anything but 0 for required version or rev is an error
            return Err((latest_rev, None));
        }

        if value.is_none() {
            // trying to delete a non-existent key
            return Err((latest_rev, None));
        }

        let new_rev = self.values_by_revision.push(placeholder_value) as i64 + 1;

        metrics::TREE_MAP_SIZE_BYTES.add(value.as_ref().map(|v| v.len() as i64).unwrap_or(0));
        let new_value = Value {
            create_revision: new_rev,
            mod_revision: new_rev,
            version: 1,
            value: value
        };

        let item = TreeItem {
            key: key.clone(),
            revisions: vec![new_rev],
            latest_value: new_value,
        };
        self.values_by_revision
            .set(new_rev as usize - 1, item.latest_value.clone());

        let value_for_watchers = item.latest_value.clone();

        let item = Arc::new(RwLock::new(item));
        {
            // Do these things before we take the lock
            let item = item.clone();
            let prefix = prefix.to_vec();
            let suffix = suffix.to_vec();

            let lock_time = Instant::now();
            let mut prefix_item =
                self.prefix_map
                    .entry(prefix)
                    .or_insert_with(|| PrefixMapItem {
                        btree: BTreeMap::new(),
                    });
            let elapsed = lock_time.elapsed().as_secs_f64();
            prefix_item.btree.insert(suffix, item);
            drop(prefix_item);
            metrics::LOCK_TIME_SECONDS.with_label_values(&["set", "prefix_map", "write"]).inc_by(elapsed);
            metrics::LOCK_COUNT.with_label_values(&["set", "prefix_map", "write"]).inc();
        }
        let lock_time = Instant::now();
        self.tree_map.insert(key.clone(), item);
        metrics::LOCK_TIME_SECONDS.with_label_values(&["set", "tree_map", "write"]).inc_by(lock_time.elapsed().as_secs_f64());
        metrics::LOCK_COUNT.with_label_values(&["set", "tree_map", "write"]).inc();

        metrics::TREE_MAP_ITEM_COUNT.with_label_values(&[&String::from_utf8_lossy(prefix)]).inc();

        self.notify_watchers(&key, value_for_watchers, None, prefix).await;

        Ok(new_rev)
    }

    pub async fn delete(
        &self,
        key: ByteArray,
        required: Option<SetRequired>,
    ) -> Result<i64, (i64, Option<KeyValue>)> {
        metrics::REQUEST_COUNT
            .with_label_values(&["delete"])
            .inc();
        // No separate latency histogram here, because set() handles timing
        self.set(key, None, required).await
    }

    async fn notify_watchers(&self, key: &ByteArray, value: Value, prev_value: Option<Value>, prefix: &[u8]) {
        // Grab a read lock on watchers and collect watchers to notify
        let watchers_to_notify: Vec<mpsc::Sender<KeyValueWithPrev>> = {
            self.watchers.read().unwrap()
                .range(..(key.clone(), i64::MAX))
                .filter_map(|(_, watcher)| {
                    // Check if this watcher should receive an update
                    if watcher.start_revision <= value.mod_revision {
                        // Range match: either single key or [start, end) range
                        let in_range = if watcher.key_range_end.is_empty() {
                            *key == watcher.key_range_start
                        } else {
                            *key < watcher.key_range_end && *key >= watcher.key_range_start
                        };

                        if in_range {
                            return Some(watcher.ch.clone());
                        }
                    }
                    None
                })
                .collect()
            // watchers is automatically dropped here when the block ends
        };

        let rev = value.mod_revision;
        let kv = Self::as_mvcc_key_value(value, &key);
        let prev_kv = prev_value.map(|v| Self::as_mvcc_key_value(v, &key));

        let watch_result_size = kv.value.len() as u64 + prev_kv.as_ref().map_or(0, |p| p.value.len() as u64);

        let wal_handled: Option<Arc<Notify>> = if self.wal.as_ref().is_some_and(|w| w.default_mode() == WalMode::Sync) {
            // if we are in fsync mode, we need to sync the wal
            Some(Arc::new(Notify::new()))
        } else {
            None
        };


        // Prepare notification job
        let job = NotifyJob {
            rev: rev,
            watchers: watchers_to_notify,
            msg: KeyValueWithPrev { kv, prev_kv },
            prefix_str: String::from_utf8_lossy(prefix).into_owned(),
            watch_result_size,
            wal_handled: wal_handled.clone(),
        };

        let _ = self.notify_tx.send(job);
        if let Some(wal_handled) = wal_handled {
            // Wait for the WAL to be persisted
            wal_handled.notified().await;
        }
    }

    /// Creates the unbounded notification channel and spawns the dedicated worker thread that
    /// processes watcher notifications. The returned `UnboundedSender` is stored inside the
    /// `Store` instance so that `notify_watchers` can enqueue jobs without any additional
    /// allocation or locking on the hot path.
    fn setup_notify_thread(wal: Option<Arc<WalManager>>) -> (UnboundedSender<NotifyJob>, Arc<AtomicI64>) {
        let (tx, rx): (UnboundedSender<NotifyJob>, UnboundedReceiver<NotifyJob>) = mpsc::unbounded_channel();

        fn do_send(job: NotifyJob, wal: &Option<Arc<WalManager>>) {
            let NotifyJob {
                rev,
                watchers,
                msg,
                prefix_str,
                watch_result_size,
                wal_handled,
            } = job;

            if let Some(wal) = wal {
                // TODO: some potential confusion between empty value and deleted value
                // What we want is value == None for deleted values and value.length == 0 for empty values
                let v = if msg.kv.value.is_empty() { None } else { Some(msg.kv.value.as_ref()) };
                wal.append(prefix_str.as_bytes(), rev, msg.kv.key.as_slice(), v, wal_handled);
            }

            let num_watchers = watchers.len() as u64;
            if num_watchers == 0 {
                return;
            }
            metrics::WATCH_RESPONSE_BYTES
                .with_label_values(&[&prefix_str])
                .inc_by(watch_result_size * num_watchers);
            metrics::WATCH_RESPONSE_COUNT
                .with_label_values(&[&prefix_str])
                .inc_by(num_watchers);
            metrics::WATCH_RESPONSE_PER_WATCHER_COUNT
                .with_label_values(&[&prefix_str])
                .inc();

            for ch in watchers {
                // send() is async so we use try_send/blocking_send
                // First attempt non-blocking send.
                match ch.try_send(msg.clone()) {
                    Ok(_) => continue,
                    Err(tokio::sync::mpsc::error::TrySendError::Closed(_)) => {
                        // Receiver dropped – skip.
                        metrics::WATCH_RESPONSE_CLOSED_COUNT.with_label_values(&[&prefix_str]).inc();
                        continue;
                    }
                    Err(tokio::sync::mpsc::error::TrySendError::Full(msg_back)) => {
                        let start = Instant::now();
                        let _ = ch.blocking_send(msg_back);
                        let elapsed = start.elapsed();
                        metrics::WATCH_RESPONSE_BLOCKING_TIME_SECONDS.with_label_values(&[&prefix_str]).inc_by(elapsed.as_secs_f64());
                        metrics::WATCH_RESPONSE_BLOCKING_COUNT.with_label_values(&[&prefix_str]).inc();
                    }
                }
            }
        }

        let rev_written = Arc::new(AtomicI64::new(0));
        let rev_written_for_thread = rev_written.clone();

        // Spawn a dedicated OS thread
        std::thread::spawn(move || {
            let mut rx = rx;
            let mut next_rev: i64 = 1;
            // Spool holds jobs that are not yet ready to be sent beacuse the earlier revision is not yet available
            let mut job_spool: BinaryHeap<NotifyJob> = BinaryHeap::with_capacity(1024);

            while let Some(job) = rx.blocking_recv() {
                if job.rev > next_rev {
                    // Not ready to send yet. Spool it in sorted order
                    job_spool.push(job);
                    continue;
                }

                do_send(job, &wal);
                next_rev += 1;

                while let Some(job) = job_spool.peek() {
                    if job.rev == next_rev {
                        do_send(job_spool.pop().unwrap(), &wal);
                        next_rev += 1;
                    } else {
                        break;
                    }
                }
                // This must only be updated after all do_send() calls enqueue the message onto their channels
                rev_written_for_thread.store(next_rev - 1, Ordering::SeqCst);
            }
        });

        (tx, rev_written)
    }


    fn prefix_and_range_of_key<'a>(
        start: &'a ByteArray,
        end: &'a ByteArray,
    ) -> Result<(&'a [u8], (Bound<ByteArray>, Bound<ByteArray>)), Status> {
        let (start_prefix, start_suffix) = Self::prefix_split(start);
        if end.is_empty() {
            let i = Included(start_suffix.to_vec());
            return Ok((start_prefix, (i.clone(), i)));
        }
        let (end_prefix, end_suffix) = Self::prefix_split(end);
        if start_prefix != end_prefix {
            // A common pattern is to go prefix /a/b/c/ and end /a/b/c0, which is excluded so it
            // is essentially the full contents of /a/b/c/
            // This is ok.
            // start_prefix == "/a/b/c/"
            // start_suffix == ""
            // end_prefix == "/a/b/"
            // end_suffix == "c0"
            if !end_suffix.is_empty() {
                let end_suffix_without_last = &end_suffix[..end_suffix.len() - 1];
                if end_suffix.last() == Some(&b'0')
                    && start_prefix == [end_prefix, end_suffix_without_last, b"/"].concat()
                {
                    return Ok((start_prefix, (Included(start_suffix.to_vec()), Unbounded)));
                } else {
                    return Err(tonic::Status::new(
                        tonic::Code::InvalidArgument,
                        format!(
                            "Keys must be in the same prefix: start: {}, end: {}",
                            String::from_utf8_lossy(start_prefix),
                            String::from_utf8_lossy(end_prefix)
                        ),
                    ));
                }
            } else {
                return Err(tonic::Status::new(
                    tonic::Code::InvalidArgument,
                    format!(
                        "Keys must be in the same prefix: start: {}, end: {}",
                        String::from_utf8_lossy(start_prefix),
                        String::from_utf8_lossy(end_prefix)
                    ),
                ));
            }
        }
        return Ok((
            start_prefix,
            (
                Included(start_suffix.to_vec()),
                Excluded(end_suffix.to_vec()),
            ),
        ));
    }

    pub fn range(
        &self,
        start: ByteArray,
        end: ByteArray,
        rev: i64,
        limit: Option<usize>,
    ) -> Result<RangeResult, Status> {
        let _timer = AlertingHistogramTimer::new(metrics::REQUEST_LATENCY
            .with_label_values(&["range"])
            .start_timer(),
            || format!("Range of {} to {} limit {}", String::from_utf8_lossy(&start), String::from_utf8_lossy(&end), limit.unwrap_or(0))
        );
        metrics::REQUEST_COUNT
            .with_label_values(&["range"])
            .inc();

        let limit = limit.unwrap_or(usize::MAX);
        let latest_rev = self.current_revision();
        if rev > latest_rev {
            // rpctypes::ErrFutureRev
            return Err(tonic::Status::new(
                tonic::Code::OutOfRange,
                "etcdserver: mvcc: required revision is a future revision",
            ));
        }
        if rev > 0 && rev <= self.values_by_revision.earliest_revision() as i64 {
            // rpctypes::ErrCompacted
            return Err(tonic::Status::new(
                tonic::Code::OutOfRange,
                "etcdserver: mvcc: required revision has been compacted",
            ));
        }
        let rev = if rev == 0 {
            // If rev is 0, we will use the latest revision and need to stay locked for all items in the range
            latest_rev
        } else {
            rev
        };

        let (prefix, range) = Self::prefix_and_range_of_key(&start, &end)?;
        let prefix_str = String::from_utf8_lossy(prefix);
        let lock_time = Instant::now();
        if let Some(prefix_map_item) = self.prefix_map.get(prefix) {
            metrics::LOCK_TIME_SECONDS.with_label_values(&["range", "prefix_map", "read"]).inc_by(lock_time.elapsed().as_secs_f64());
            metrics::LOCK_COUNT.with_label_values(&["range", "prefix_map", "read"]).inc();

            let mut value_bytes_total = 0;
            let mut count = 0;
            let mut results = Vec::with_capacity(500);
            let mut full_key = prefix.to_vec();
            for (key, item) in prefix_map_item.btree.range(range) {
                if count > limit {
                    // It seems to be ok if this is an estimate, as long as count is larger than limit
                    count += 1;
                    continue;
                }

                let item = item.read().unwrap();

                if count == limit {
                    if self.has_value_for_revision(&item, rev) {
                        count += 1;
                    }
                } else {
                    if let Some(v) = self.find_value_for_revision(&item, rev) {
                        if v.value.is_some() {
                            if results.len() < limit {
                                full_key.truncate(prefix.len());
                                full_key.extend(key);
                                value_bytes_total += v.value.as_ref().map_or(0, |v| v.len() as u64);
                                results.push(Self::as_mvcc_key_value(v, &full_key));
                            }
                            count += 1;
                        }
                    }
                }
            }
            metrics::RANGE_RESPONSE_BYTES.with_label_values(&[&prefix_str]).inc_by(value_bytes_total);
            metrics::RANGE_RESPONSE_COUNT.with_label_values(&[&prefix_str]).inc_by(results.len() as u64);
            return Ok(RangeResult { kvs: results, latest_rev, count: count as i64 });
        } else {
            metrics::LOCK_TIME_SECONDS.with_label_values(&["range", "prefix_map", "read"]).inc_by(lock_time.elapsed().as_secs_f64());
            metrics::LOCK_COUNT.with_label_values(&["range", "prefix_map", "read"]).inc();
            return Ok(RangeResult { kvs: vec![], latest_rev, count: 0 });
        }
    }

    fn find_value_for_revision(&self, item: &TreeItem, rev: i64) -> Option<Value> {
        assert!(rev > 0, "find_value_for_revision called with rev == 0");
        if rev >= item.latest_value.mod_revision {
            return Some(item.latest_value.clone())
        }

        // Find the highest revision that is less than or equal to rev
        match item.revisions.binary_search(&rev) {
            Ok(i) => self.values_by_revision.get(item.revisions[i] as usize - 1).ok(),
            Err(i) => {
                if i > 0 {
                    self.values_by_revision.get(item.revisions[i - 1] as usize - 1).ok()
                } else {
                    None
                }
            }
        }
    }

    fn has_value_for_revision(&self, item: &TreeItem, rev: i64) -> bool {
        assert!(rev > 0, "has_value_for_revision called with rev == 0");
        if rev >= item.latest_value.mod_revision {
            return item.latest_value.value.is_some();
        }

        // Find the highest revision that is less than or equal to rev
        match item.revisions.binary_search(&rev) {
            Ok(i) => self.values_by_revision.get_with(item.revisions[i] as usize - 1, |x| x.as_ref().is_some_and(|v| v.value.is_some())),
            Err(i) => {
                if i > 0 {
                    self.values_by_revision.get_with(item.revisions[i - 1] as usize - 1, |x| x.as_ref().map_or(false, |v| v.value.is_some()))
                } else {
                    false
                }
            }
        }
    }

    fn as_mvcc_key_value(v: Value, key: &ByteArray) -> KeyValue {
        let is_deleted = v.value.is_none();
        return KeyValue {
            key: key.clone(),
            value: v.value.clone().unwrap_or_default(),
            create_revision: if is_deleted { 0 } else { v.create_revision },
            mod_revision: v.mod_revision,
            version: if is_deleted { 0 } else { v.version },
            lease: 0,
        };
    }

    /// Watches a range, returning a set of existing values plus a Watcher to receive future changes.
    pub fn watch(
        &self,
        start: ByteArray,
        end: ByteArray,
        rev: i64,
        want_prev_kv: bool,
    ) -> Result<(Vec<KeyValueWithPrev>, i64, mpsc::Receiver<KeyValueWithPrev>), i64> {
        let (tx, rx) = mpsc::channel(WATCH_CHANNEL_SIZE);

        let start_rev: i64 = if rev <= 0 {
            self.current_revision()
        } else {
            rev
        };

        let compact_revision = self.values_by_revision.earliest_revision() as i64;
        if rev > 0 && rev <= compact_revision {
            // TODO: return Err(rpctypes::ErrCompacted)
            return Err(compact_revision);
        }

        let watcher_id = self.watch_counter.fetch_add(1, Ordering::SeqCst) + 1;

        let watcher = Watcher {
            start_revision: start_rev,
            key_range_start: start.clone(),
            key_range_end: end.clone(),
            ch: tx,
        };

        {
            self.watchers
                .write()
                .unwrap()
                .insert((start.clone(), watcher_id), watcher);
        }

        // Get past changes
        let mut past_changes = vec![];
        if rev > 0 {
            let _ = rev;
            if let Ok((prefix, range)) =
                Self::prefix_and_range_of_key(&start, &end)
            {
                if let Some(prefix_map_item) = self.prefix_map.get(prefix) {
                    prefix_map_item.btree.range(range).for_each(|(_, item)| {
                        let item = item.read().unwrap();
                        let mut prev_kv = None;

                        // Find the position of the first revision that is >= start_rev
                        let mut start_pos = item.revisions.binary_search(&start_rev).unwrap_or_else(|pos| pos);
                        if start_pos > 0 && want_prev_kv {
                            // Start one back so we can build prev_kv
                            start_pos -= 1;
                        }

                        for item_rev in item.revisions.iter().skip(start_pos) {
                            let v = self
                                .values_by_revision
                                .get(*item_rev as usize - 1);
                            if let Ok(v) = v {
                                if *item_rev >= start_rev {
                                    past_changes.push(KeyValueWithPrev {
                                        kv: Self::as_mvcc_key_value(v.clone(), &item.key),
                                        prev_kv: prev_kv,
                                    });
                                }
                                prev_kv = want_prev_kv.then(|| Self::as_mvcc_key_value(v, &item.key));
                            } else {
                                // TODO: unnecessary?
                                prev_kv = None;
                            }
                        }
                    });
                }
            } else {
                return Err(compact_revision);
            }
        }

        Ok((past_changes, watcher_id, rx))
    }

    pub fn unwatch(&self, start: ByteArray, watcher_id: i64) {
        self.watchers.write().unwrap().remove(&(start, watcher_id));
    }

    pub fn compact(&self, rev: i64) -> Result<(), Status> {
        let _timer = metrics::REQUEST_LATENCY
            .with_label_values(&["compact"])
            .start_timer();
        metrics::REQUEST_COUNT
            .with_label_values(&["compact"])
            .inc();

        if rev < 1 || rev > self.current_revision() {
            return Err(tonic::Status::new(
                tonic::Code::OutOfRange,
                "etcdserver: mvcc: required revision has been compacted",
            ));
        }
        let result = self
            .values_by_revision
            .remove_before((rev - 1) as usize);
        // TODO: remove keys from self.tree_map and self.prefix_map[*].btree that no longer have any values. This can be done async
        return result.map_err(|_| Status::new(tonic::Code::Internal, "etcdserver: mvcc: compact failed"));
    }

    fn prefix_split(key: &ByteArray) -> (&[u8], &[u8]) {
        // This is more complex that you'd expect. We want to make as long a prefix as possible,
        // but such that Kube will never do a range across multiple prefixes

        // ranges can span across namespaces of a single resource
        // CRDs will have a period in the second segment

        // Using slashes to delimit segments:
        // The prefix should consist of 3 segments if the key starts with /registry/ and the second segment contains a period
        // Otherwise, it should consist of 2 segments
        if !key.starts_with(b"/registry/") {
            return (&[], key);
        }
        let segments = key.splitn(5, |v| *v == b'/').collect::<Vec<_>>();
        if segments.len() == 1 {
            return (&[], key);
        }
        let last_segment = std::cmp::min(segments.len() - 1, if key.starts_with(b"/registry/") && segments[2].contains(&b'.') {
            4
        } else {
            3
        });

        let prefix_end = segments[last_segment].as_ptr() as usize - key.as_ptr() as usize;
        let prefix = &key[0..prefix_end];
        let suffix = &key[prefix_end..];
        return (prefix, suffix);
    }

    /// Returns the current revision.
    pub fn current_revision(&self) -> i64 {
        self.values_by_revision.latest_revision() as i64
    }

    pub fn compacted_revision(&self) -> i64 {
        self.values_by_revision.earliest_revision() as i64
    }

    pub fn watcher_count(&self) -> i64 {
        self.watchers.read().unwrap().len() as i64
    }

    pub fn progress_revision(&self) -> i64 {
        self.progress_rev.load(Ordering::SeqCst)
    }
}

pub struct AlertingHistogramTimer<'a> {
    /// A histogram for automatic recording of observations.
    _histogram: prometheus::HistogramTimer,
    start: std::time::Instant,
    name_fn: Box<dyn Fn() -> String + Send + 'a>,
}

impl<'a> AlertingHistogramTimer<'a> {
    pub fn new(_histogram: prometheus::HistogramTimer, name_fn: impl Fn() -> String + Send + 'a) -> Self {
        Self {
            _histogram,
            start: std::time::Instant::now(),
            name_fn: Box::new(name_fn)
        }
    }
}

impl<'a> Drop for AlertingHistogramTimer<'a> {
    fn drop(&mut self) {
        let v = self.start.elapsed();
        if v > std::time::Duration::from_millis(100) {
            println!("AlertingHistogramTimer: {} seconds for {}", v.as_secs_f32(), (self.name_fn)());
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_prefix_split() {
        assert_eq!(
            Store::prefix_split(&b"abc".to_vec()),
            (b"".as_slice(), b"abc".as_slice())
        );
        assert_eq!(
            Store::prefix_split(&b"abc/".to_vec()),
            (b"".as_slice(), b"abc/".as_slice())
        );
        assert_eq!(
            Store::prefix_split(&b"a/b".to_vec()),
            (b"".as_slice(), b"a/b".as_slice())
        );
        assert_eq!(
            Store::prefix_split(&b"/a/b".to_vec()),
            (b"".as_slice(), b"/a/b".as_slice())
        );
        assert_eq!(
            Store::prefix_split(&b"a/b/c".to_vec()),
            (b"".as_slice(), b"a/b/c".as_slice())
        );
        assert_eq!(
            Store::prefix_split(&b"/a/b/c".to_vec()),
            (b"".as_slice(), b"/a/b/c".as_slice())
        );
        assert_eq!(
            Store::prefix_split(&b"/registry/serviceaccounts/".to_vec()),
            (b"/registry/serviceaccounts/".as_slice(), b"".as_slice())
        );
        assert_eq!(
            Store::prefix_split(&b"/registry/pods/kube-system/foo".to_vec()),
            (b"/registry/pods/".as_slice(), b"kube-system/foo".as_slice())
        );
        assert_eq!(
            Store::prefix_split(&b"/registry/roles/foo".to_vec()),
            (b"/registry/roles/".as_slice(), b"foo".as_slice())
        );
        assert_eq!(
            Store::prefix_split(&b"/registry/apigroup-example.com/my-resources/foo".to_vec()),
            (
                b"/registry/apigroup-example.com/my-resources/".as_slice(),
                b"foo".as_slice()
            )
        );
        assert_eq!(
            Store::prefix_split(
                &b"/registry/apigroup-example.com/my-resources/my-namespace/foo".to_vec()
            ),
            (
                b"/registry/apigroup-example.com/my-resources/".as_slice(),
                b"my-namespace/foo".as_slice()
            )
        );
    }

    #[test]
    fn test_prefix_and_range_of_key() {
        let key = b"/registry/serviceaccounts/".to_vec();
        let end = b"/registry/serviceaccounts0".to_vec();
        let (prefix, range) = Store::prefix_and_range_of_key(&key, &end).unwrap();
        assert_eq!(prefix, b"/registry/serviceaccounts/".as_slice());
        assert_eq!(range, (Bound::Included(b"".to_vec()), Bound::Unbounded));

        let key = b"/registry/apiextensions.k8s.io/customresourcedefinitions/".to_vec();
        let end = b"/registry/apiextensions.k8s.io/customresourcedefinitions0".to_vec();
        let (prefix, range) = Store::prefix_and_range_of_key(&key, &end).unwrap();
        assert_eq!(prefix, b"/registry/apiextensions.k8s.io/customresourcedefinitions/".as_slice());
        assert_eq!(range, (Bound::Included(b"".to_vec()), Bound::Unbounded));

        let key = b"/bootstrap".to_vec();
        let end = b"/bootstraq".to_vec();
        let (prefix, range) = Store::prefix_and_range_of_key(&key, &end).unwrap();
        assert_eq!(prefix, b"".as_slice());
        assert_eq!(range, (Bound::Included(b"/bootstrap".to_vec()), Bound::Excluded(b"/bootstraq".to_vec())));
    }


    #[tokio::test]
    async fn test_bytes_metrics() {
        assert_eq!(metrics::TREE_MAP_SIZE_BYTES.get(), 0);
        let s = Store::new(None);

        // The byte tracking doesn't work if the value is static so we need to use a Vec
        s.set(b"foo".to_vec(), Some(Bytes::from(b"beep".to_vec())), None).await.unwrap();
        assert_eq!(metrics::TREE_MAP_SIZE_BYTES.get(), 4);

        // Overwriting adds to the size
        s.set(b"foo".to_vec(), Some(Bytes::from(b"boop".to_vec())), None).await.unwrap();
        assert_eq!(metrics::TREE_MAP_SIZE_BYTES.get(), 8);

        // Deleting doesn't change the size
        s.set(b"foo".to_vec(), None, None).await.unwrap();
        assert_eq!(metrics::TREE_MAP_SIZE_BYTES.get(), 8);

        // Compacting a delete changes the size
        s.compact(3).unwrap();
        assert_eq!(metrics::TREE_MAP_SIZE_BYTES.get(), 0);
    }
}
