// SPDX-License-Identifier: Apache-2.0
// Copyright 2025 Benjamin Chess
fn main() -> Result<(), Box<dyn std::error::Error>> {
    tonic_build::configure()
        .build_client(false)
        .build_server(true)
        .bytes(&["KeyValue.value"])
        .compile_protos(&["extern/etcd/api/rpc.proto"], &["extern", "extern/etcd/api"])?;
    Ok(())
}
