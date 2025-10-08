// SPDX-License-Identifier: Apache-2.0
// Copyright 2025 Benjamin Chess
use once_cell::sync::Lazy;
use prometheus::{
    register_histogram_vec, register_counter_vec, register_int_counter_vec, register_int_gauge, register_int_gauge_vec,
    CounterVec, HistogramVec, IntCounterVec, IntGauge, IntGaugeVec,
};

/// A collection of Prometheus metrics for this application.
pub struct Metrics;

impl Metrics {
    /// Force initialization of all static metrics.
    /// You can call this in main() to ensure the metrics are registered.
    pub fn init() {
        // Accessing a static ref will trigger registration.
        let _ = &*REQUEST_COUNT;
        let _ = &*REQUEST_LATENCY;
        let _ = &*IN_FLIGHT_REQUESTS;
        let _ = &*LOCK_TIME_SECONDS;
        let _ = &*TREE_MAP_ITEM_COUNT;
        let _ = &*TREE_MAP_SIZE_BYTES;
        let _ = &*REVISION_COUNT;
        let _ = &*COMPACTED_REVISION_COUNT;
        let _ = &*WATCHER_COUNT;
        let _ = &*RANGE_RESPONSE_BYTES;
        let _ = &*RANGE_RESPONSE_COUNT;
        let _ = &*WATCH_RESPONSE_BYTES;
        let _ = &*WATCH_RESPONSE_COUNT;
        let _ = &*WATCH_RESPONSE_PER_WATCHER_COUNT;
        let _ = &*WATCH_RESPONSE_BLOCKING_TIME_SECONDS;
        let _ = &*WATCH_RESPONSE_BLOCKING_COUNT;
        let _ = &*WATCH_RESPONSE_CLOSED_COUNT;

        // Check if a Tokio runtime is running
        let runtime_running = tokio::runtime::Handle::try_current().is_ok();

        // Only register metrics if a Tokio runtime is running
        if runtime_running {
            prometheus::default_registry()
            .register(Box::new(
                tokio_metrics_collector::default_runtime_collector(),
            ))
            .unwrap();
        }
    }
}

/// Tracks the count of requests by type (get, set, compact, watch, etc.).
pub static REQUEST_COUNT: Lazy<IntCounterVec> = Lazy::new(|| {
    register_int_counter_vec!(
        "mem_etcd_requests_total",
        "Total requests received, labeled by request type",
        &["type"]
    )
    .expect("cannot create metric: mem_etcd_requests_total")
});

/// Tracks the latency of requests, labeled by request type.
pub static REQUEST_LATENCY: Lazy<HistogramVec> = Lazy::new(|| {
    register_histogram_vec!(
        "mem_etcd_request_latency_seconds",
        "Request latency distribution",
        &["type"],
        vec![0.001, 0.005, 0.01, 0.05, 0.1, 0.5, 1.0, 5.0, 10.0]
    )
    .expect("cannot create metric: mem_etcd_request_latency_seconds")
});

pub static IN_FLIGHT_REQUESTS: Lazy<IntGauge> = Lazy::new(|| {
    register_int_gauge!(
        "mem_etcd_in_flight_requests",
        "Number of in-flight requests"
    )
    .expect("cannot create metric: mem_etcd_in_flight_requests")
});

pub static LOCK_TIME_SECONDS: Lazy<CounterVec> = Lazy::new(|| {
    register_counter_vec!(
        "mem_etcd_lock_seconds",
        "Amount of time waiting for the lock",
        &["method", "structure", "rw"]
    )
    .expect("cannot create metric: mem_etcd_lock_seconds")
});

pub static LOCK_COUNT: Lazy<IntCounterVec> = Lazy::new(|| {
    register_int_counter_vec!(
        "mem_etcd_lock_count",
        "Number of times the lock was acquired",
        &["method", "structure", "rw"]
    )
    .expect("cannot create metric: mem_etcd_lock_count")
});

/// A gauge of how many items are in the tree_map.
pub static TREE_MAP_ITEM_COUNT: Lazy<IntGaugeVec> = Lazy::new(|| {
    register_int_gauge_vec!(
        "mem_etcd_tree_map_item_count",
        "Number of keys currently stored in the tree_map. Never goes down, including when an item is deleted or compacted.",
        &["prefix"]
    )
    .expect("cannot create metric: mem_etcd_tree_map_item_count")
});

/// A gauge of the approximate total size in bytes of items in the tree_map.
pub static TREE_MAP_SIZE_BYTES: Lazy<IntGauge> = Lazy::new(|| {
    register_int_gauge!(
        "mem_etcd_tree_map_size_bytes",
        "Approximate total size (in bytes) for items in the tree_map"
    )
    .expect("cannot create metric: mem_etcd_tree_map_size_bytes")
});

pub static REVISION_COUNT: Lazy<IntGauge> = Lazy::new(|| {
    register_int_gauge!(
        "mem_etcd_revision_count",
        "Current revision count"
    )
    .expect("cannot create metric: mem_etcd_revision_count")
});

pub static COMPACTED_REVISION_COUNT: Lazy<IntGauge> = Lazy::new(|| {
    register_int_gauge!(
        "mem_etcd_compacted_revision_count",
        "Current compacted revision"
    )
    .expect("cannot create metric: mem_etcd_compacted_revision_count")
});

pub static WATCHER_COUNT: Lazy<IntGauge> = Lazy::new(|| {
    register_int_gauge!(
        "mem_etcd_watcher_count",
        "Current watcher count"
    )
    .expect("cannot create metric: mem_etcd_watcher_count")
});

pub static RANGE_RESPONSE_BYTES: Lazy<IntCounterVec> = Lazy::new(|| {
    register_int_counter_vec!(
        "mem_etcd_range_response_bytes",
        "Total size in bytes of range response KVs",
        &["prefix"]
    )
    .expect("cannot create metric: mem_etcd_range_response_bytes")
});

pub static RANGE_RESPONSE_COUNT: Lazy<IntCounterVec> = Lazy::new(|| {
    register_int_counter_vec!(
        "mem_etcd_range_response_count",
        "Total number of range response KVs",
        &["prefix"]
    )
    .expect("cannot create metric: mem_etcd_range_response_count")
});

pub static WATCH_RESPONSE_BYTES: Lazy<IntCounterVec> = Lazy::new(|| {
    register_int_counter_vec!(
        "mem_etcd_watch_response_bytes",
        "Total size in bytes of watch response KVs",
        &["prefix"]
    )
    .expect("cannot create metric: mem_etcd_watch_response_bytes")
});

pub static WATCH_RESPONSE_COUNT: Lazy<IntCounterVec> = Lazy::new(|| {
    register_int_counter_vec!(
        "mem_etcd_watch_response_count",
        "Total number of watch response KVs sent",
        &["prefix"]
    )
    .expect("cannot create metric: mem_etcd_watch_response_count")
});

pub static WATCH_RESPONSE_PER_WATCHER_COUNT: Lazy<IntCounterVec> = Lazy::new(|| {
    register_int_counter_vec!(
        "mem_etcd_watch_response_per_watcher_count",
        "Total number of watch response KVs sent per watcher",
        &["prefix"]
    )
    .expect("cannot create metric: mem_etcd_watch_response_per_watcher_count")
});

pub static WATCH_RESPONSE_BLOCKING_TIME_SECONDS: Lazy<CounterVec> = Lazy::new(|| {
    register_counter_vec!(
        "mem_etcd_watch_response_blocking_time_seconds",
        "Total time spent blocking on watch response KVs",
        &["prefix"]
    )
    .expect("cannot create metric: mem_etcd_watch_response_blocking_time_seconds")
});

pub static WATCH_RESPONSE_BLOCKING_COUNT: Lazy<IntCounterVec> = Lazy::new(|| {
    register_int_counter_vec!(
        "mem_etcd_watch_response_blocking_count",
        "Total number of times watch response KVs were blocked",
        &["prefix"]
    )
    .expect("cannot create metric: mem_etcd_watch_response_blocking_count")
});

pub static WATCH_RESPONSE_CLOSED_COUNT: Lazy<IntCounterVec> = Lazy::new(|| {
    register_int_counter_vec!(
        "mem_etcd_watch_response_closed_count",
        "Total number of times we tried to send a watch response to a closed channel",
        &["prefix"]
    )
    .expect("cannot create metric: mem_etcd_watch_response_closed_count")
});