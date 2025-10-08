// SPDX-License-Identifier: Apache-2.0
// Copyright 2025 Benjamin Chess
use crate::etcdserverpb::{watch_server::Watch, ResponseHeader, WatchRequest, WatchResponse};
use crate::store::Store;
use crate::metrics;
use std::boxed::Box;
use std::pin::Pin;
use std::sync::Arc;
use tokio_stream::Stream;
use tonic::{Request, Response, Status, Streaming};
use async_stream::try_stream;

pub struct WatchService {
    store: Arc<Store>,
}

impl WatchService {
    pub fn new(store: Arc<Store>) -> Self {
        WatchService { store }
    }
}

pub type WatchStream = Pin<Box<dyn Stream<Item = Result<WatchResponse, Status>> + Send>>;

#[tonic::async_trait]
impl Watch for WatchService {
    type WatchStream = WatchStream;

    async fn watch(
        &self,
        request: Request<Streaming<WatchRequest>>,
    ) -> Result<Response<Self::WatchStream>, Status> {
        let _timer = metrics::REQUEST_LATENCY
            .with_label_values(&["watch"])
            .start_timer();
        metrics::REQUEST_COUNT
            .with_label_values(&["watch"])
            .inc();

        // tokio_stream::wrappers::ReceiverStream
        // Implement Watch RPC
        let remote_addr = request.remote_addr();
        let mut req_inner = request.into_inner();
        let watch_req = req_inner.message().await.unwrap().unwrap();
        let create_req = if let Some(
            crate::etcdserverpb::watch_request::RequestUnion::CreateRequest(create_req),
        ) = watch_req.request_union
        {
            create_req
        } else {
            return Err(Status::invalid_argument("Not supported"));
        };
        let key_dbg: String = String::from_utf8_lossy(&create_req.key).to_string();
        let key_dbg_end: String = String::from_utf8_lossy(&create_req.range_end).to_string();

        let key = create_req.key.clone();
        let watch_result = self.store.watch(
            create_req.key,
            create_req.range_end,
            create_req.start_revision,
            create_req.prev_kv,
        );
        if watch_result.is_err() {
            // Print the error
            println!("Error: in watch of {:?}", key_dbg);
            return Ok(Response::new(Box::pin(tokio_stream::once(Ok(
                WatchResponse {
                    header: Some(ResponseHeader {
                        ..Default::default()
                    }),
                    compact_revision: watch_result.err().unwrap(),
                    ..Default::default()
                },
            )))));
        }
        let (past_changes, watcher_id, mut rx) = watch_result.unwrap();
        println!("Watch stream opened watcher_id={:?} start={:?} end={:?} rev={:?} remote_addr={:?}", watcher_id, key_dbg, key_dbg_end, create_req.start_revision, remote_addr);

        // Clone necessary data to avoid lifetime issues
        let store = self.store.clone();
        let prev_kv = create_req.prev_kv;

        let stream = try_stream! {
            // First we send one response to confirm watch creation, just with 'created: true'
            yield WatchResponse {
                header: Some(ResponseHeader {
                    revision: store.current_revision(),
                    ..Default::default()
                }),
                watch_id: watcher_id,
                created: true,
                ..Default::default()
            };

            // If there are past changes, we send them next
            if !past_changes.is_empty() {
                yield WatchResponse {
                    header: Some(ResponseHeader {
                        revision: store.current_revision(),
                        ..Default::default()
                    }),
                    watch_id: watcher_id,
                    events: past_changes
                        .into_iter()
                        .map(|kv| crate::mvccpb::Event {
                            prev_kv: if prev_kv { kv.prev_kv } else { None },
                            r#type: if kv.kv.value.is_empty() {
                                crate::mvccpb::event::EventType::Delete as i32
                            } else {
                                crate::mvccpb::event::EventType::Put as i32
                            },
                            kv: Some(kv.kv),
                        })
                        .collect(),
                    ..Default::default()
                };
            }

            let mut max_event_stream_rev = 0;
            loop {
                let mut read_many = Vec::with_capacity(100);
                tokio::select! {
                    // Take any pending messages from the channel first, only then do progress messages. This is important for a Progress response to be correct
                    biased;

                    _num_read = rx.recv_many(&mut read_many, 1000) => {
                        let last_rev = read_many.last().unwrap().kv.mod_revision;
                        max_event_stream_rev = std::cmp::max(last_rev, max_event_stream_rev);
                        yield WatchResponse {
                            header: Some(ResponseHeader {
                                revision: last_rev,
                                ..Default::default()
                            }),
                            watch_id: watcher_id,
                            events: read_many.into_iter().map(|kv| crate::mvccpb::Event {
                                prev_kv: if prev_kv { kv.prev_kv } else { None },
                                r#type: if kv.kv.value.is_empty() {
                                    crate::mvccpb::event::EventType::Delete as i32
                                } else {
                                    crate::mvccpb::event::EventType::Put as i32
                                },
                                kv: Some(kv.kv),
                            }).collect(),
                            ..Default::default()
                        };
                    }
                    client_msg = req_inner.message() => {
                        // A message from the client
                        match client_msg {
                            Err(e) => {
                                println!("Error: in watch of {:?}: {:?}", key_dbg, e);
                                store.unwatch(key, watcher_id);
                                return;
                            }
                            Ok(None) => {
                                continue;
                            }
                            Ok(Some(client_msg)) => {
                                match client_msg.request_union {
                                    Some(crate::etcdserverpb::watch_request::RequestUnion::CancelRequest(cancel_req)) => {
                                        if cancel_req.watch_id == watcher_id {
                                            store.unwatch(key, watcher_id);
                                            return;
                                        } else {
                                            println!("watcher_id={:?} received cancel_req with watch_id={:?}, ignoring", watcher_id, cancel_req.watch_id);
                                        }
                                    }
                                    Some(crate::etcdserverpb::watch_request::RequestUnion::ProgressRequest(_progress_req)) => {
                                        // Progress is to send a Response whose Header contains the latest revision. The watch stream should not
                                        // subsequently return any revisions earlier than the progress revision.

                                        println!("watcher_id={:?} progress_revision={:?} max_event_stream_rev={:?}", watcher_id, store.progress_revision(), max_event_stream_rev);
                                        // store.progress_revision() is updated after items have been enqueued in the 'rx' stream.
                                        // There's a small potential race that items have been enqueued but store.progress_revision() hasn't been updated yet.
                                        // So we use the max of either the last rev we've delivered or the store's idea of progress_revision()
                                        let progress_revision = std::cmp::max(store.progress_revision(), max_event_stream_rev);
                                        let progress_response = WatchResponse {
                                            header: Some(ResponseHeader {
                                                revision: progress_revision,
                                                ..Default::default()
                                            }),
                                            watch_id: watcher_id,
                                            ..Default::default()
                                        };
                                        yield progress_response;
                                    }
                                    _ => {}
                                }
                            }
                        }
                    }
                }
            }
        };


        Ok(Response::new(Box::pin(stream) as WatchStream))
    }
}
