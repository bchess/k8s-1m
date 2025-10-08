// SPDX-License-Identifier: Apache-2.0
// Copyright 2025 Benjamin Chess
use crate::etcdserverpb;
use crate::etcdserverpb::kv_server::Kv;
use crate::etcdserverpb::{
    CompactionRequest, CompactionResponse, DeleteRangeRequest, DeleteRangeResponse, PutRequest,
    PutResponse, RangeRequest, RangeResponse, ResponseHeader, TxnRequest, TxnResponse,
};
use crate::mvccpb::KeyValue;
use crate::store::{SetRequired, Store};
use std::sync::Arc;
use tonic::{Request, Response, Status};
use bytes::Bytes;
pub struct KvService {
    store: Arc<Store>,
}

impl KvService {
    pub fn new(store: Arc<Store>) -> Self {
        KvService { store }
    }
}

#[tonic::async_trait]
impl Kv for KvService {
    /// Implements the Range RPC method.
    async fn range(
        &self,
        request: Request<RangeRequest>,
    ) -> Result<Response<RangeResponse>, Status> {
        let req = request.into_inner();
        let rev = req.revision;

        // Perform the range query on the store
        let limit: Option<usize>;
        if req.count_only {
            limit = Some(0);
        } else if req.limit == 0 {
            limit = None;
        } else {
            limit = Some(req.limit as usize);
        }
        let range_result = self
            .store
            .range(req.key, req.range_end, rev, limit)?;


        // Construct the RangeResponse
        let more: bool;
        if req.count_only || limit.is_none() {
            more = false;
        } else {
            more = range_result.count > limit.unwrap() as i64;
        }

        let response = RangeResponse {
            header: Some(ResponseHeader {
                cluster_id: 0,
                member_id: 0,
                raft_term: 0,
                revision: range_result.latest_rev,
            }),
            count: range_result.count,
            kvs: range_result.kvs,
            more: more,
        };

        Ok(Response::new(response))
    }

    /// Implements the Put RPC method.
    async fn put(&self, request: Request<PutRequest>) -> Result<Response<PutResponse>, Status> {
        let req = request.into_inner();

        // Perform the put operation on the store
        let rev = self
            .store
            .set(req.key, Some(Bytes::from(req.value)), None)
            .await
            .map_err(|e| Status::internal(format!("Put operation failed: {:?}", e)))?;

        // Construct the PutResponse
        let response = PutResponse {
            header: Some(ResponseHeader {
                cluster_id: 0,
                member_id: 0,
                raft_term: 0,
                revision: rev,
            }),
            prev_kv: None,
            // Note: Previous key-value (PrevKv) is not handled here as per Go implementation.
            // To include PrevKv, additional logic is required.
            // prev_kv: None,
        };

        Ok(Response::new(response))
    }

    async fn delete_range(
        &self,
        request: Request<DeleteRangeRequest>,
    ) -> Result<Response<DeleteRangeResponse>, Status> {
        let req = request.into_inner();

        if !req.range_end.is_empty() {
            return Err(Status::invalid_argument("range end not supported in deleteRange"));
        }

        self.store
            .delete(req.key, None)
            .await
            .map_err(|e| Status::internal(format!("Delete operation failed: {:?}", e)))?;

        Ok(Response::new(DeleteRangeResponse {
            prev_kvs: Vec::new(),
            deleted: 1,
            header: Some(ResponseHeader {
                cluster_id: 0,
                member_id: 0,
                raft_term: 0,
                revision: 0,
            }),
        }))
    }

    async fn txn(&self, request: Request<TxnRequest>) -> Result<Response<TxnResponse>, Status> {
        /*
             Most will be of target MOD, e.g.:
                {
                  "method": "/etcdserverpb.KV/Txn",
                  "request": {
                    "compare": [
                      {
                        "key": "/registry/flowschemas/endpoint-controller",
                        "modRevision": "51",
                        "target": "MOD"
                      }
                    ],
                    "failure": [
                      {
                        "requestRange": {
                          "key": "/registry/flowschemas/endpoint-controller"
                        }
                      }
                    ],
                    "success": [
                      {
                        "requestPut": {
                          "key": "/registry/flowschemas/endpoint-controller",
                          "value": "azhzAAotCh9mbG93Y29udHJvbC5hcGlzZXJ2ZX..."
                        }
                      }
                    ]
                  },

            // We also need to support success.requestDeleteRange (with a single key, no range end)

            // Also need to support compare.key.version, wand compare.target == EQUAL
        */
        let mut req = request.into_inner();
        if req.compare.len() != 1 {
            println!("Unsupported txn: {:?}", req);
            return Err(Status::invalid_argument("only one compare supported"));
        }
        let required: Option<SetRequired>;
        match req.compare[0].target_union.as_ref().unwrap() {
            crate::etcdserverpb::compare::TargetUnion::ModRevision(mod_revision) => {
                required = Some(SetRequired {
                    required_last_revision: Some(*mod_revision),
                    required_version: None,
                });
            }
            crate::etcdserverpb::compare::TargetUnion::Version(version) => {
                required = Some(SetRequired {
                    required_last_revision: None,
                    required_version: Some(*version),
                });
            }
            _ => {
                println!("Unsupported compare: {:?}", req.compare[0]);
                return Err(Status::invalid_argument("only MOD or VERSION target supported"));
            }
        }
        if req.success.len() != 1 {
            println!("Unsupported txn: {:?}", req);
            return Err(Status::invalid_argument("only one success supported"));
        }
        if req.failure.len() > 1 {
            println!("Unsupported txn: {:?}", req);
            return Err(Status::invalid_argument("only one failure supported"));
        }
        if !req.failure.is_empty() {
            if let Some(op) = &req.failure[0].request {
                match op {
                    crate::etcdserverpb::request_op::Request::RequestRange(range_req) => {
                        let failure_key = &range_req.key;
                        if *failure_key != req.compare[0].key {
                            println!("Unsupported txn: {:?}", req);
                            return Err(Status::invalid_argument(
                                "compare key must match failure key",
                            ));
                        }
                        if !range_req.range_end.is_empty() {
                            println!("Unsupported txn: {:?}", req);
                            return Err(Status::invalid_argument(
                                "range end not supported in failure",
                            ));
                        }
                    }
                    _ => return Err(Status::invalid_argument("only range supported in failure")),
                }
            }
        }

        if req.success.len() != 1 {
            return Err(Status::invalid_argument("success must be a single request"));
        }

        let success_req = req.success.pop().unwrap().request.unwrap();
        let result: Result<i64, (i64, Option<KeyValue>)>;
        let mut success_is_delete = false;
        match success_req {
            crate::etcdserverpb::request_op::Request::RequestPut(put) => {
                if put.key.is_empty() {
                    return Err(Status::invalid_argument("key required in success put"));
                }
                /*
                put.value can be an empty string, which is a valid value

                if put.value.is_empty() {
                    return Err(Status::invalid_argument("value required in success put"));
                } */
                if put.key != req.compare[0].key {
                    return Err(Status::invalid_argument("compare key must match put key"));
                }
                result = self.store.set(put.key, Some(Bytes::from(put.value)), required).await;
            }
            crate::etcdserverpb::request_op::Request::RequestDeleteRange(delete_range) => {
                success_is_delete = true;
                if delete_range.key.is_empty() {
                    return Err(Status::invalid_argument(
                        "key required in success deleteRange",
                    ));
                }
                if !delete_range.range_end.is_empty() {
                    return Err(Status::invalid_argument(
                        "range end not supported in deleteRange",
                    ));
                }
                if delete_range.key != req.compare[0].key {
                    return Err(Status::invalid_argument(
                        "compare key must match deleteRange key",
                    ));
                }
                result = self.store.set(delete_range.key, None, required).await;
            }
            _ => {
                return Err(Status::invalid_argument(
                    "only put and deleteRange supported in success",
                ));
            }
        }

        match result {
            Err((rev, kv)) => {
                let kvs = kv.as_slice().to_vec();
                let responses = if req.failure.is_empty() { vec![] } else { vec![etcdserverpb::ResponseOp {
                    response: Some(etcdserverpb::response_op::Response::ResponseRange(
                        etcdserverpb::RangeResponse {
                            header: Some(etcdserverpb::ResponseHeader {
                                cluster_id: 0,
                                member_id: 0,
                                raft_term: 0,
                                revision: rev,
                            }),
                            count: 1,
                            kvs: kvs,
                            more: false,
                        },
                    )),
                }]};

                return Ok(tonic::Response::new(etcdserverpb::TxnResponse {
                    header: Some(etcdserverpb::ResponseHeader {
                        cluster_id: 0,
                        member_id: 0,
                        raft_term: 0,
                        revision: rev,
                    }),
                    responses: responses,
                    succeeded: false,
                }));
            }
            Ok(rev) => {
                let responses: Vec<etcdserverpb::ResponseOp>;
                match success_is_delete {
                    false => {
                        responses = vec![etcdserverpb::ResponseOp {
                            response: Some(etcdserverpb::response_op::Response::ResponsePut(
                                etcdserverpb::PutResponse {
                                    header: Some(etcdserverpb::ResponseHeader {
                                        revision: rev,
                                        ..Default::default()
                                    }),
                                    prev_kv: None,
                                }
                            ))
                        }];
                    }
                    true => {
                        responses = vec![etcdserverpb::ResponseOp {
                            response: Some(etcdserverpb::response_op::Response::ResponseDeleteRange (
                                etcdserverpb::DeleteRangeResponse {
                                    header: Some(etcdserverpb::ResponseHeader {
                                        revision: rev,
                                        ..Default::default()
                                    }),
                                    prev_kvs: vec![],
                                    deleted: 0, // TODO
                                }
                            ))
                        }];
                    }
                }
                return Ok(tonic::Response::new(etcdserverpb::TxnResponse {
                    header: Some(etcdserverpb::ResponseHeader {
                        cluster_id: 0,
                        member_id: 0,
                        raft_term: 0,
                        revision: rev,
                    }),
                    responses: responses,
                    succeeded: true,
                }));
            }
        }
    }

    async fn compact(
        &self,
        request: Request<CompactionRequest>,
    ) -> Result<Response<CompactionResponse>, Status> {
        self.store
            .compact(request.into_inner().revision)
            .map_err(|e| Status::internal(format!("Compaction operation failed: {:?}", e)))?;
        Ok(Response::new(CompactionResponse {
            header: Some(ResponseHeader {
                cluster_id: 0,
                member_id: 0,
                raft_term: 0,
                revision: 0,
            }),
        }))
    }
}
