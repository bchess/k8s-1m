# Kubernetes API Server Stress Test

This tool helps stress test a Kubernetes API server by creating multiple concurrent watch requests and monitoring the event rates.

## Features

- Create multiple concurrent watch requests
- Support for label and field selectors
- Real-time event rate monitoring
- Prometheus metrics export
- Configurable resource types

## Prerequisites

- Rust toolchain
- Access to a Kubernetes cluster
- kubectl configured with proper credentials

## Building

```bash
cargo build --release
```

## Usage

Basic usage:

```bash
./target/release/apiserver-stress --resource pods --concurrency 10
```

With selectors:

```bash
./target/release/apiserver-stress \
  --resource pods \
  --concurrency 5 \
  --label-selector "app=nginx" \
  --field-selector "status.phase=Running"
```

## Metrics

The application exposes Prometheus metrics on port 9000:

- `watch_events_total`: Counter of total events received per watch
- `watch_events_rate`: Gauge of current event rate per watch

## Command Line Arguments

- `-c, --concurrency`: Number of concurrent watch requests (default: 1)
- `-r, --resource`: Resource type to watch (e.g., "pods", "deployments")
- `-l, --label-selector`: Optional label selector
- `-f, --field-selector`: Optional field selector 