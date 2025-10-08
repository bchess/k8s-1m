use std::sync::Arc;
use tonic::Request;

use mem_etcd::etcdserverpb::kv_server::Kv;
use mem_etcd::etcdserverpb::{
    compare::{CompareResult, TargetUnion},
    request_op, CompactionRequest, Compare, DeleteRangeRequest, PutRequest, RangeRequest,
    RequestOp, TxnRequest,
};
use mem_etcd::kv_service::KvService;
use mem_etcd::store::Store;
// use bytes::Bytes;

macro_rules! as_bytes {
    ($v:expr) => {
        $v.to_vec()
    };
}

#[tokio::test]
async fn test_put_and_range() {
    let store = Arc::new(Store::new(None));
    let kv_service = KvService::new(store);

    // Test Put
    let put_req = PutRequest {
        key: b"foo".to_vec(),
        value: as_bytes!(b"bar"),
        lease: 0,
        prev_kv: false,
        ignore_value: false,
        ignore_lease: false,
    };

    let put_response = kv_service.put(Request::new(put_req)).await.unwrap();
    assert_eq!(put_response.get_ref().header.as_ref().unwrap().revision, 1);

    // Test Range
    let range_req = RangeRequest {
        key: b"foo".to_vec(),
        range_end: vec![],
        limit: 0,
        revision: 0,
        sort_order: 0,
        sort_target: 0,
        serializable: false,
        keys_only: false,
        count_only: false,
        min_mod_revision: 0,
        max_mod_revision: 0,
        min_create_revision: 0,
        max_create_revision: 0,
    };

    let range_response = kv_service.range(Request::new(range_req)).await.unwrap();
    let response = range_response.get_ref();
    assert_eq!(response.kvs.len(), 1);
    assert_eq!(response.count, 1);
    assert_eq!(response.kvs[0].key, b"foo");
    assert_eq!(response.kvs[0].value, as_bytes!(b"bar"));
}

#[tokio::test]
async fn test_delete_range() {
    let store = Arc::new(Store::new(None));
    let kv_service = KvService::new(store);

    // First put a key
    let put_req = PutRequest {
        key: b"foo".to_vec(),
        value: as_bytes!(b"bar"),
        ..Default::default()
    };
    kv_service.put(Request::new(put_req)).await.unwrap();

    // Then delete it
    let delete_req = DeleteRangeRequest {
        key: b"foo".to_vec(),
        range_end: vec![],
        prev_kv: false,
    };

    let delete_response = kv_service
        .delete_range(Request::new(delete_req))
        .await
        .unwrap();
    assert!(delete_response.get_ref().header.is_some());

    // Verify it's gone with a range request
    let range_req = RangeRequest {
        key: b"foo".to_vec(),
        ..Default::default()
    };

    let range_response = kv_service.range(Request::new(range_req)).await.unwrap();
    assert_eq!(range_response.get_ref().kvs.len(), 0);
}

#[tokio::test]
async fn test_range_count_only() {
    let store = Arc::new(Store::new(None));
    let kv_service = KvService::new(store);

    let put_req = PutRequest {
        key: b"foo".to_vec(),
        value: as_bytes!(b"bar"),
        ..Default::default()
    };
    kv_service.put(Request::new(put_req)).await.unwrap();

    let range_req = RangeRequest {
        key: b"foo".to_vec(),
        count_only: true,
        ..Default::default()
    };

    let range_response = kv_service.range(Request::new(range_req)).await.unwrap();
    assert_eq!(range_response.get_ref().count, 1);
    assert_eq!(range_response.get_ref().kvs.len(), 0);
}

#[tokio::test]
async fn test_range_limit() {
    let store = Arc::new(Store::new(None));
    let kv_service = KvService::new(store);

    for i in 0..10 {
        let put_req = PutRequest {
            key: vec![(b'a' + i)],
            value: vec![b'r', i],
            ..Default::default()
        };
        kv_service.put(Request::new(put_req)).await.unwrap();
    }

    let range_req = RangeRequest {
        key: b"a".to_vec(),
        range_end: b"z".to_vec(),
        limit: 4,
        ..Default::default()
    };

    let range_response = kv_service.range(Request::new(range_req)).await.unwrap();
    assert_eq!(range_response.get_ref().count, 10);
    assert_eq!(range_response.get_ref().kvs.len(), 4);
    assert_eq!(range_response.get_ref().more, true);

    let range_req = RangeRequest {
        key: b"a".to_vec(),
        range_end: b"z".to_vec(),
        limit: 10,
        ..Default::default()
    };

    let range_response = kv_service.range(Request::new(range_req)).await.unwrap();
    assert_eq!(range_response.get_ref().count, 10);
    assert_eq!(range_response.get_ref().kvs.len(), 10);
    assert_eq!(range_response.get_ref().more, false);

    let range_req = RangeRequest {
        key: b"a".to_vec(),
        range_end: b"z".to_vec(),
        limit: 15,
        ..Default::default()
    };

    let range_response = kv_service.range(Request::new(range_req)).await.unwrap();
    assert_eq!(range_response.get_ref().count, 10);
    assert_eq!(range_response.get_ref().kvs.len(), 10);
    assert_eq!(range_response.get_ref().more, false);
}

#[tokio::test]
async fn test_txn() {
    let store = Arc::new(Store::new(None));
    let kv_service = KvService::new(store);

    // First put a key
    let put_req = PutRequest {
        key: b"foo".to_vec(),
        value: as_bytes!(b"bar"),
        ..Default::default()
    };
    let put_response = kv_service.put(Request::new(put_req)).await.unwrap();
    let rev = put_response.get_ref().header.as_ref().unwrap().revision;

    // Create a transaction that checks modRevision
    let txn_req = TxnRequest {
        compare: vec![Compare {
            result: CompareResult::Equal as i32,
            target: 0, // MOD
            key: b"foo".to_vec(),
            range_end: vec![],
            target_union: Some(TargetUnion::ModRevision(rev)),
        }],
        success: vec![RequestOp {
            request: Some(request_op::Request::RequestPut(PutRequest {
                key: b"foo".to_vec(),
                value: as_bytes!(b"baz"),
                ..Default::default()
            })),
        }],
        failure: vec![RequestOp {
            request: Some(request_op::Request::RequestRange(RangeRequest {
                key: b"foo".to_vec(),
                ..Default::default()
            })),
        }],
    };

    let txn_response = kv_service.txn(Request::new(txn_req)).await.unwrap();
    assert!(txn_response.get_ref().succeeded);
    assert_eq!(txn_response.get_ref().responses.len(), 1);
}

#[tokio::test]
async fn test_txn_failure() {
    let store = Arc::new(Store::new(None));
    let kv_service = KvService::new(store);

    // First put a key
    let put_req = PutRequest {
        key: b"foo".to_vec(),
        value: as_bytes!(b"bar"),
        ..Default::default()
    };
    let put_response = kv_service.put(Request::new(put_req)).await.unwrap();
    let _rev = put_response.get_ref().header.as_ref().unwrap().revision;

    // Create a transaction that checks modRevision
    let txn_req = TxnRequest {
        compare: vec![Compare {
            result: CompareResult::Equal as i32,
            target: 0, // MOD
            key: b"foo".to_vec(),
            range_end: vec![],
            target_union: Some(TargetUnion::ModRevision(0)),  // mod is zero so this should fail
        }],
        success: vec![RequestOp {
            request: Some(request_op::Request::RequestPut(PutRequest {
                key: b"foo".to_vec(),
                value: as_bytes!(b"baz"),
                ..Default::default()
            })),
        }],
        failure: vec![], // No failure repsonse please
    };

    let txn_response = kv_service.txn(Request::new(txn_req)).await.unwrap();
    assert_eq!(txn_response.get_ref().succeeded, false);
    assert_eq!(txn_response.get_ref().responses.len(), 0);
}

#[tokio::test]
async fn test_compaction() {
    let store = Arc::new(Store::new(None));
    let kv_service = KvService::new(store.clone());

    // Create some revisions
    let put_req = PutRequest {
        key: b"foo".to_vec(),
        value: as_bytes!(b"bar1"),
        ..Default::default()
    };
    kv_service.put(Request::new(put_req)).await.unwrap();

    let put_req = PutRequest {
        key: b"foo".to_vec(),
        value: as_bytes!(b"bar2"),
        ..Default::default()
    };
    kv_service.put(Request::new(put_req)).await.unwrap();

    // Compact at revision 2
    let compact_req = CompactionRequest {
        revision: 2,
        physical: false,
    };

    let compact_response = kv_service.compact(Request::new(compact_req)).await.unwrap();
    assert!(compact_response.get_ref().header.is_some());

    // Try to get revision 1 (should fail)
    let range_req = RangeRequest {
        key: b"foo".to_vec(),
        revision: 1,
        ..Default::default()
    };

    let range_result = kv_service.range(Request::new(range_req)).await;
    assert!(
        range_result.is_err(),
        "Expected error when requesting compacted revision"
    );
}
