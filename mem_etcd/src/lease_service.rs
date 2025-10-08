// SPDX-License-Identifier: Apache-2.0
// Copyright 2025 Benjamin Chess
use crate::etcdserverpb::{
    lease_server::Lease, LeaseGrantRequest, LeaseGrantResponse, LeaseKeepAliveRequest,
    LeaseKeepAliveResponse, LeaseRevokeRequest, LeaseRevokeResponse, ResponseHeader,
};
use crate::store::Store; // Reuse or share store logic if desired.
use std::pin::Pin;
use std::sync::atomic::{AtomicI64, Ordering};
use std::sync::Arc;
use tokio_stream::wrappers::ReceiverStream;
use tokio_stream::Stream;
use tonic::Streaming;
use tonic::{Request, Response, Status};

// A minimal "LeaseService" struct.
pub struct LeaseService {
    _store: Arc<Store>,
    lease_id: AtomicI64,
}

// Provide a constructor if needed.
impl LeaseService {
    pub fn new(_store: Arc<Store>) -> Self {
        LeaseService {
            _store,
            lease_id: AtomicI64::new(0),
        }
    }
}

#[tonic::async_trait]
impl Lease for LeaseService {
    // Implements a minimal "LeaseGrant" RPC.
    async fn lease_grant(
        &self,
        request: Request<LeaseGrantRequest>,
    ) -> Result<Response<LeaseGrantResponse>, Status> {
        let req = request.into_inner();

        // For demonstration, just echo back the requested ID & TTL.
        // In a real implementation, store the lease info and track expiration.
        let granted_id = if req.id == 0 {
            // If 0, etcd normally generates a new ID. We'll just fake a minimal example (1234).
            self.lease_id.fetch_add(1, Ordering::Relaxed)
        } else {
            req.id
        };

        let response = LeaseGrantResponse {
            header: Some(ResponseHeader {
                cluster_id: 0,
                member_id: 0,
                raft_term: 0,
                // In real etcd, revision might reflect current store revision. We'll stub it as 1 here.
                revision: 1,
            }),
            id: granted_id,
            ttl: req.ttl,
            error: String::new(),
        };

        Ok(Response::new(response))
    }

    // Implements a minimal "LeaseRevoke" RPC.
    async fn lease_revoke(
        &self,
        request: Request<LeaseRevokeRequest>,
    ) -> Result<Response<LeaseRevokeResponse>, Status> {
        let req = request.into_inner();

        // In real etcd, we’d remove any keys attached to this lease.
        let response = LeaseRevokeResponse {
            header: Some(ResponseHeader {
                cluster_id: 0,
                member_id: 0,
                raft_term: 0,
                revision: 2,
            }),
        };

        // Just a placeholder log statement
        println!("Revoking lease: {}", req.id);

        Ok(Response::new(response))
    }

    async fn lease_time_to_live(
        &self,
        _request: tonic::Request<crate::etcdserverpb::LeaseTimeToLiveRequest>,
    ) -> Result<tonic::Response<crate::etcdserverpb::LeaseTimeToLiveResponse>, tonic::Status> {
        Err(Status::unimplemented("lease_time_to_live not implemented"))
    }

    async fn lease_leases(
        &self,
        _request: tonic::Request<crate::etcdserverpb::LeaseLeasesRequest>,
    ) -> Result<tonic::Response<crate::etcdserverpb::LeaseLeasesResponse>, tonic::Status> {
        Err(Status::unimplemented("lease_leases not implemented"))
    }

    type LeaseKeepAliveStream =
        Pin<Box<dyn Stream<Item = Result<LeaseKeepAliveResponse, Status>> + Send>>;

    async fn lease_keep_alive(
        &self,
        _request: Request<Streaming<LeaseKeepAliveRequest>>,
    ) -> Result<Response<Self::LeaseKeepAliveStream>, Status> {
        // For now, return an empty stream to satisfy the trait
        let (tx, rx) = tokio::sync::mpsc::channel(1);
        // tx.send(None).await.unwrap();
        tx.send(Ok(LeaseKeepAliveResponse {
            header: Some(ResponseHeader {
                cluster_id: 0,
                member_id: 0,
                raft_term: 0,
                revision: 1,
            }),
            ..Default::default()
        }))
        .await
        .unwrap();
        let stream = ReceiverStream::new(rx);
        /*
        .map(|item| Ok(LeaseKeepAliveResponse {
            header: Some(ResponseHeader {
                cluster_id: 0,
                member_id: 0,
                raft_term: 0,
                revision: 1,
            }),
            ..Default::default()
        }));*/
        Ok(Response::new(Box::pin(stream) as Self::LeaseKeepAliveStream))
    }
}
