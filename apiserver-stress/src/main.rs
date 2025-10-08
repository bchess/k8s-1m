// SPDX-License-Identifier: Apache-2.0
// Copyright 2025 Benjamin Chess
use anyhow::Result;
use clap::Parser;
use kube::{
    api::{Api, WatchParams, WatchEvent, DynamicObject, GroupVersionKind},
    Client,
    discovery,
};
use metrics::{counter, gauge};
use metrics_exporter_prometheus::PrometheusBuilder;
use std::time::Instant;
use tokio::sync::mpsc;
use futures::{TryStreamExt};

#[derive(Parser, Debug)]
#[command(author, version, about, long_about = None)]
struct Args {
    /// Number of concurrent watch requests
    #[arg(short, long, default_value_t = 1)]
    concurrency: u32,

    /// Resource type to watch (e.g., "pods", "deployments")
    #[arg(short, long)]
    resource: String,

    /// Optional label selector
    #[arg(short, long)]
    label_selector: Option<String>,

    /// Optional field selector
    #[arg(short, long)]
    field_selector: Option<String>,
}

#[tokio::main]
async fn main() -> Result<()> {
    // Initialize metrics
    PrometheusBuilder::new()
        .with_http_listener(([0, 0, 0, 0], 9001))
        .install()?;

    let args = Args::parse();
    let client = Client::try_default().await?;

    // Create a channel for receiving watch events
    let (tx, mut rx) = mpsc::channel(1000);

    println!("Discovering resource: {}", args.resource);
    let (resource, _caps) = discovery::pinned_kind(&client, &GroupVersionKind::gvk("", "v1", &args.resource)).await?;
    println!("Discovered resource: {}", resource.kind);

    // Spawn watch tasks
    for i in 0..args.concurrency {
        let client = client.clone();
        let resource = resource.clone();
        let label_selector = args.label_selector.clone();
        let field_selector = args.field_selector.clone();
        let tx = tx.clone();

        tokio::spawn(async move {
            // Use DynamicObject for generic resource watching
            let api: Api<DynamicObject> = Api::all_with(client, &resource);
            let mut params = WatchParams::default();

            if let Some(ls) = label_selector {
                params = params.labels(&ls);
            }
            if let Some(fs) = field_selector {
                params = params.fields(&fs);
            }

            let stream = api.watch(&params, "0").await?;
            let start_time = Instant::now();
            let mut event_count = 0;
            let watch_id = i.to_string();
            let mut stream = Box::pin(stream);

            println!("Watching resource: {}", resource.kind);
            while let Some(status) = stream.try_next().await? {
                match status {
                    WatchEvent::Added(_) | WatchEvent::Modified(_) | WatchEvent::Deleted(_) => {
                        event_count += 1;
                        let elapsed = start_time.elapsed();
                        let rate = event_count as f64 / elapsed.as_secs_f64();

                        counter!("watch_events_total", "watch_id" => watch_id.clone()).increment(1);
                        gauge!("watch_events_rate", "watch_id" => watch_id.clone()).set(rate);

                        tx.send((i, event_count, rate)).await?;
                    }
                    _ => {}
                }
            }
            Ok::<_, anyhow::Error>(())
        });
    }

    // Print statistics
    while let Some((watch_id, count, rate)) = rx.recv().await {
        println!(
            "Watch {}: {} events, {:.2} events/sec",
            watch_id, count, rate
        );
    }

    Ok(())
}
