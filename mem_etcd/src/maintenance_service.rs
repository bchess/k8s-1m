// SPDX-License-Identifier: Apache-2.0
// Copyright 2025 Benjamin Chess
use crate::etcdserverpb::{
    maintenance_server::Maintenance, AlarmRequest, AlarmResponse,
    StatusRequest, StatusResponse, DefragmentRequest, DefragmentResponse, HashRequest, HashResponse,
    HashKvRequest, HashKvResponse, SnapshotRequest, SnapshotResponse, MoveLeaderRequest,
    MoveLeaderResponse, DowngradeRequest, DowngradeResponse, ResponseHeader,
};
use crate::metrics;
use crate::store::Store;
use std::sync::Arc;
use tonic::{Request, Response, Status};
use std::pin::Pin;
use tokio_stream::Stream;

pub struct MaintenanceService {
    store: Arc<Store>,
}

impl MaintenanceService {
    pub fn new(store: Arc<Store>) -> Self {
        MaintenanceService {
            store: Arc::clone(&store),
        }
    }
}

#[tonic::async_trait]
impl Maintenance for MaintenanceService {
    async fn alarm(
        &self,
        _request: Request<AlarmRequest>,
    ) -> Result<Response<AlarmResponse>, Status> {

        let response = AlarmResponse {
            header: Some(ResponseHeader {
                revision: self.store.current_revision(),
                ..Default::default()
            }),
            alarms: vec![],
        };

        Ok(Response::new(response))
    }

    async fn status(
        &self,
        _request: Request<StatusRequest>,
    ) -> Result<Response<StatusResponse>, Status> {
        let db_size = metrics::TREE_MAP_SIZE_BYTES.get();
        let response = StatusResponse {
            header: Some(ResponseHeader {
                revision: self.store.current_revision(),
                ..Default::default()
            }),
            version: "3.5.16".to_string(), // Needs to be >=3.5.13 for K8s to recognize support for watch progress
            db_size: db_size as i64,
            db_size_in_use: db_size as i64,
            ..Default::default()
        };

        Ok(Response::new(response))
    }

    async fn defragment(
        &self,
        _request: Request<DefragmentRequest>,
    ) -> Result<Response<DefragmentResponse>, Status> {
        // In a real implementation, this would defragment the backend database
        // For this in-memory implementation, we'll just return success
        let response = DefragmentResponse {
            header: Some(ResponseHeader {
                revision: self.store.current_revision(),
                ..Default::default()
            }),
        };

        Ok(Response::new(response))
    }

    async fn hash(
        &self,
        _request: Request<HashRequest>,
    ) -> Result<Response<HashResponse>, Status> {
        Err(Status::unimplemented("hash not implemented"))
    }

    async fn hash_kv(
        &self,
        _request: Request<HashKvRequest>,
    ) -> Result<Response<HashKvResponse>, Status> {
        Err(Status::unimplemented("hash_kv not implemented"))
    }

    type SnapshotStream = Pin<Box<dyn Stream<Item = Result<SnapshotResponse, Status>> + Send>>;

    async fn snapshot(
        &self,
        _request: Request<SnapshotRequest>,
    ) -> Result<Response<Self::SnapshotStream>, Status> {
        Err(Status::unimplemented("snapshot not implemented"))
    }

    async fn move_leader(
        &self,
        _request: Request<MoveLeaderRequest>,
    ) -> Result<Response<MoveLeaderResponse>, Status> {
        Err(Status::unimplemented("move_leader not implemented"))
    }

    async fn downgrade(
        &self,
        _request: Request<DowngradeRequest>,
    ) -> Result<Response<DowngradeResponse>, Status> {
        Err(Status::unimplemented("downgrade not implemented"))
    }
}
