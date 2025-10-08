// SPDX-License-Identifier: Apache-2.0
// Copyright 2025 Benjamin Chess
use etcdserverpb::kv_client::KvClient;
use etcdserverpb::PutRequest;
use etcdserverpb::RangeRequest;
use tonic::Request;
use bytes::Bytes;
use futures::stream::{self, StreamExt};
use clap::Parser;

mod etcdserverpb {
    tonic::include_proto!("etcdserverpb");
}

mod authpb {
    tonic::include_proto!("authpb");
}

mod mvccpb {
    tonic::include_proto!("mvccpb");
}

/// Stress client arguments.
#[derive(Parser, Debug)]
#[command(author, version, about, long_about = None)]
struct Args {
    /// Number of keys to use.
    #[arg(long, default_value_t = 100_000)]
    keys: usize,

    /// Number of iterations to run.
    #[arg(long, default_value_t = 10)]
    iterations: usize,

    #[arg(long, default_value_t = 4)]
    threads: usize,

    #[arg(long, default_value_t = false)]
    prompt: bool,
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args = Args::parse();
    let keys = args.keys;
    let iterations = args.iterations;
    let threads = args.threads;

    let mut clients = Vec::new();
    for _ in 0..threads {
        clients.push(KvClient::connect("http://localhost:2379").await?);
    }

    let mut value = Vec::from(b"hello");
    value.resize(4096, 0);
    let value = Bytes::from(value);

    println!("Starting to put {} keys {} times", keys, iterations);
    let concurrency_limit = 100; // Limit to 100 concurrent tasks

    for i in 0..iterations {
        stream::iter(0..keys)
            .for_each_concurrent(concurrency_limit, |i| {
                let mut client = clients[i % clients.len()].clone();
                let value = value.clone();
                async move {
                    let request = Request::new(PutRequest {
                        key: format!("/registry/minions/node-{}", i).into_bytes(),
                        value,
                        ..Default::default()
                    });
                    if let Err(e) = client.put(request).await {
                        eprintln!("Error: {:?}", e);
                    }
                }
            })
            .await;
        println!("Done writing {} keys", (i + 1) * keys);
    }

    println!("Done writing {} keys in {} iterations", keys * iterations, iterations);
    if args.prompt {
        println!("Press Enter to continue...");
        let _ = std::io::stdin().read_line(&mut String::new());
    }
    println!("Doing range queries");

    // For each 500 keys, do a range query
    let start = std::time::Instant::now();
    for i in (0..keys).step_by(500) {
        let request = Request::new(RangeRequest {
            key: format!("/registry/minions/node-{}", i).into_bytes(),
            range_end: format!("/registry/minions/z").into_bytes(),
            revision: ((iterations - 2) * keys) as i64,
            limit: 500,
            ..Default::default()
        });

        let response = clients[i % clients.len()].clone().range(request).await?;
        let v = response.into_inner();
        let kvs = v.kvs;
        println!("Range query for {} keys returned {} kvs", 500, kvs.len());
    }
    let duration = std::time::Instant::now().duration_since(start);
    println!("Done range queries. Duration: {:?}, or avg {:?} per request", duration, duration / (keys / 500) as u32);

    Ok(())
}
