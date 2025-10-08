// SPDX-License-Identifier: Apache-2.0
// Copyright 2025 Benjamin Chess
mod block_deque;
mod kv_service;
mod lease_service;
mod metrics;
mod store;
mod watch_service;
mod wal;
mod maintenance_service;

use etcdserverpb::kv_server::KvServer;
use etcdserverpb::maintenance_server::MaintenanceServer;
use etcdserverpb::lease_server::LeaseServer;
use etcdserverpb::watch_server::WatchServer;

use bytes::Bytes;
use std::sync::Arc;
use std::path::PathBuf;
use clap::{Parser, ValueEnum};
use dashmap::DashSet;

use kv_service::KvService;
use lease_service::LeaseService;
use maintenance_service::MaintenanceService;
use std::net::SocketAddr;
use tonic::transport::Server;
use tower_http::metrics::InFlightRequestsLayer;
use watch_service::WatchService;

use prometheus::{TextEncoder, Encoder};
use axum::{
    routing::get,
    Router,
};

// use watch_service::WatchService;

mod authpb {
    tonic::include_proto!("authpb");
}

mod mvccpb {
    tonic::include_proto!("mvccpb");
}

mod etcdserverpb {
    tonic::include_proto!("etcdserverpb");
}

#[derive(Copy, Clone, Debug, ValueEnum, PartialEq)]
enum CliWalMode { None, Buffered, Fsync }

impl From<CliWalMode> for crate::wal::WalMode {
    fn from(m: CliWalMode) -> Self {
        match m { CliWalMode::None => Self::None, CliWalMode::Buffered => Self::Async, CliWalMode::Fsync => Self::Sync }
    }
}

#[derive(Parser, Debug)]
#[command(name = "mem_etcd", version, about = "In-memory etcd-like server", long_about = None)]
struct Cli {
    /// gRPC listen port
    #[arg(long = "port", env = "ETCD_PORT", default_value_t = 2379)]
    port: u16,

    /// Metrics port
    #[arg(long = "metrics-port", env = "ETCD_METRICS_PORT", default_value_t = 9000)]
    metrics_port: u16,

    /// WAL directory path
    #[arg(long = "wal-dir", env = "ETCD_WAL_DIR", default_value = "./wal")]
    wal_dir: PathBuf,

    /// Default WAL mode for prefixes without explicit override
    #[arg(long = "wal-default", value_enum, default_value_t = CliWalMode::Buffered)]
    wal_default: CliWalMode,

    #[arg(long = "wal-no-write-prefix", value_parser, num_args = 0.., value_delimiter = ' ')]
    wal_no_write_prefixes: Vec<String>,
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    env_logger::init();
    let cli = Cli::parse();
    let addr: SocketAddr = format!("[::]:{}", cli.port).parse()?;

    let wal_settings = Some(store::WalSettings {
        wal_dir: cli.wal_dir.clone(),
        default_mode: cli.wal_default.into(),
        load_wal_dir: true,
        prefix_modes_no_persist: {
            let set = DashSet::new();
            for prefix in cli.wal_no_write_prefixes.into_iter() {
                set.insert(prefix.as_bytes().to_vec());
            }
            set
        }
    });
    let store = Arc::new(store::Store::new(wal_settings));

    // etcd initializes with rev at 1, so set a dummy key to take rev 0
    store.set(b"~".to_vec(), Some(Bytes::from(b"".to_vec())), None).await.unwrap();

    let kv_service = KvServer::new(KvService::new(Arc::clone(&store)));
    let maintenance_service = MaintenanceServer::new(MaintenanceService::new(Arc::clone(&store)));
    let watch_service = WatchServer::new(WatchService::new(Arc::clone(&store)));
    let lease_service = LeaseServer::new(LeaseService::new(Arc::clone(&store)));

    // Build the Axum metrics app
    let metrics_app = Router::new().route("/metrics", get(move || {
        let store = Arc::clone(&store);
        async move {
            metrics::REVISION_COUNT.set(store.current_revision() as i64);
            metrics::COMPACTED_REVISION_COUNT.set(store.compacted_revision() as i64);
            metrics::WATCHER_COUNT.set(store.watcher_count());

            let metric_families = prometheus::gather();
            let mut buf = Vec::new();
            let encoder = TextEncoder::new();
            encoder.encode(&metric_families, &mut buf).unwrap();
            String::from_utf8(buf).unwrap()
        }
    }));

    // Bind a listener for the metrics endpoint
    let metrics_listener = tokio::net::TcpListener::bind(format!("[::]:{}", cli.metrics_port)).await.unwrap();

    // Spawn the metrics server in its own task
    tokio::spawn(async move {
        axum::serve(metrics_listener, metrics_app).await.unwrap();
    });


    let (in_flight_requests_layer, in_flight_requests_counter) = InFlightRequestsLayer::pair();
    tokio::spawn(
        in_flight_requests_counter.run_emitter(std::time::Duration::from_secs(5), |counter| async move {
            metrics::IN_FLIGHT_REQUESTS.set(counter as i64);
        }),
    );

    // Now run the gRPC server on the main task
    println!("Starting gRPC server on {}", addr);
    Server::builder()
        .max_concurrent_streams(100)
        .http2_adaptive_window(Some(true))
        .layer(in_flight_requests_layer)
        .add_service(kv_service)
        .add_service(maintenance_service)
        .add_service(lease_service)
        .add_service(watch_service)
        .serve(addr)
        .await?;

    Ok(())
}
