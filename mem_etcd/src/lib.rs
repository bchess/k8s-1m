// SPDX-License-Identifier: Apache-2.0
// Copyright 2025 Benjamin Chess
pub mod block_deque;
pub mod kv_service;
pub mod store;
pub mod wal;
mod metrics;
pub mod watch_service;
pub mod maintenance_service;

pub mod authpb {
    tonic::include_proto!("authpb");
}

pub mod mvccpb {
    tonic::include_proto!("mvccpb");
}

pub mod etcdserverpb {
    tonic::include_proto!("etcdserverpb");
}
