use std::sync::Arc;
use tokio_stream::StreamExt;

use mem_etcd::etcdserverpb::watch_server::Watch;
use mem_etcd::etcdserverpb::{watch_request, WatchCreateRequest, WatchRequest, WatchResponse};
use mem_etcd::store::Store;
use mem_etcd::watch_service::WatchService;
use bytes::Bytes;

macro_rules! set_with_revision {
    ($store:expr, $key:expr, $value:expr, $expected_rev:expr) => {
        $store.set($key.to_vec(), Some(as_bytes!($value)), None).await.unwrap()
    };
}
macro_rules! as_bytes {
    ($v:expr) => {
        Bytes::from_static($v)
    };
}

macro_rules! assert_kv_value {
    ($events:expr, $index:expr, $expected_value:expr) => {
        assert_eq!(
            $events[$index].kv.as_ref().unwrap().value,
            as_bytes!($expected_value),
            "Expected value at index {} to be {:?}",
            $index,
            $expected_value
        );
    };
}

#[tokio::test]
async fn test_watch_create_request_success() {
    let store = Arc::new(Store::new(None));
    let watch_service = WatchService::new(store.clone());

    let create_req = WatchRequest {
        request_union: Some(watch_request::RequestUnion::CreateRequest(
            WatchCreateRequest {
                key: b"foo".to_vec(),
                range_end: vec![],
                start_revision: 0,
                ..Default::default()
            },
        )),
    };

    let request = tonic_mock::streaming_request(vec![create_req]);
    let response = watch_service.watch(request).await.unwrap();
    let mut response_stream = response.into_inner();

    // 5) Read the first message -> should show "created: true"
    let first_msg = response_stream
        .next()
        .await
        .expect("expected a response")
        .unwrap();
    assert!(
        first_msg.created,
        "Expected 'created' to be true for a new watch"
    );
    let watch_id = first_msg.watch_id;
    assert!(
        watch_id != 0,
        "Expected a non-zero watch_id for a newly created watch"
    );
    assert!(
        first_msg.events.is_empty(),
        "Expected new watch with no prior events"
    );

    // 6) Trigger a Store change and see if watch yields an event
    // Here we set "foo" -> "bar"
    store
        .set(b"foo".to_vec(), Some(as_bytes!(b"bar")), None)
        .await.unwrap();

    // 7) The watch stream should emit exactly one event with the updated key
    let second_msg = response_stream
        .next()
        .await
        .expect("expected another response")
        .unwrap();
    assert_eq!(second_msg.watch_id, watch_id, "Watch ID should match");
    assert_eq!(second_msg.events.len(), 1, "Expected 1 event");
    let event = &second_msg.events[0];
    let kv = event.kv.as_ref().expect("Expected KeyValue in event");
    assert_eq!(kv.key, b"foo");
    assert_eq!(kv.value, as_bytes!(b"bar"));
}

#[tokio::test]
async fn test_watch_invalid_argument() {
    // 1) Create the Store and service
    let store = Arc::new(Store::new(None));
    let watch_service = WatchService::new(store.clone());

    // 2) Prepare a watch request with None request_union -> triggers invalid_argument
    let invalid_req = WatchRequest {
        request_union: None,
    };
    let request = tonic_mock::streaming_request(vec![invalid_req]);

    // 3) Make the call -> Expect an error
    let result = watch_service.watch(request).await;
    assert!(result.is_err(), "should produce invalid_argument error");
    let status = result.err().unwrap();
    assert_eq!(status.code(), tonic::Code::InvalidArgument);
    assert!(
        status.message().contains("Not supported"),
        "expected 'Not supported' error message"
    );
}

#[tokio::test]
async fn test_watch_compacted_revision() {
    // 1) Make some revisions in Store
    let store = Arc::new(Store::new(None));
    set_with_revision!(store, b"foo", b"v1", None); // rev 1
    set_with_revision!(store, b"foo", b"v2", None); // rev 2
    set_with_revision!(store, b"foo", b"v3", None); // rev 3

    // Compact at revision 3
    store.compact(3).unwrap();

    // 2) Attempt to watch from revision 1 (which is already compacted)
    let watch_service = WatchService::new(store.clone());
    let create_req = WatchRequest {
        request_union: Some(watch_request::RequestUnion::CreateRequest(
            WatchCreateRequest {
                key: b"foo".to_vec(),
                range_end: Vec::new(),
                start_revision: 1,
                ..Default::default()
            },
        )),
    };

    let request = tonic_mock::streaming_request(vec![create_req]);

    // 3) Check the response
    let response = watch_service.watch(request).await.unwrap();
    let mut response_stream = response.into_inner();

    // The first (and only) message should signal a compacted revision
    if let Some(Ok(WatchResponse {
        compact_revision,
        events,
        ..
    })) = response_stream.next().await
    {
        assert!(
            compact_revision != 0,
            "Expected a non-zero compact_revision for a watch request < compaction"
        );
        assert!(
            events.is_empty(),
            "Expected no events when the watch request is below the compacted revision"
        );
    } else {
        panic!("Expected watch stream to return a compact_revision response");
    }
}

#[tokio::test]
async fn test_watch_past_changes_on_create() {
    // 1) Create and populate store
    let store = Arc::new(Store::new(None));
    set_with_revision!(store, b"a", b"a1", None); // rev 1
    set_with_revision!(store, b"a", b"a2", None); // rev 2
    set_with_revision!(store, b"a", b"a3", None); // rev 3
    set_with_revision!(store, b"b", b"b1", None); // rev 4

    // 2) Create WatchService
    let watch_service = WatchService::new(store.clone());

    // 3) Watch from revision 2, which should catch "a2", "a3", and "b" changes
    let create_req = WatchRequest {
        request_union: Some(watch_request::RequestUnion::CreateRequest(
            WatchCreateRequest {
                key: b"a".to_vec(),
                range_end: b"z".to_vec(), // get a range so "b" is included
                start_revision: 2,
                ..Default::default()
            },
        )),
    };

    let request = tonic_mock::streaming_request(vec![create_req]);
    let response = watch_service.watch(request).await.unwrap();
    let mut response_stream = response.into_inner();

    // 4) The first messages returned from watch_service are the initial creation msg
    //    and then one containing the "past changes" (a2, a3, b1).
    //    The first message should have created: true, no events
    let first_msg = response_stream.next().await.unwrap().unwrap();
    assert!(first_msg.created, "expected created == true");
    assert!(
        first_msg.events.is_empty(),
        "expected no events in the creation response"
    );

    // 5) The second message should contain the past changes
    let second_msg = response_stream.next().await.unwrap().unwrap();
    let events = second_msg.events;
    assert_eq!(events.len(), 3, "expected 3 events for revs 2..4");
    assert_kv_value!(events, 0, b"a2");
    assert_kv_value!(events, 1, b"a3");
    assert_kv_value!(events, 2, b"b1");

    // 6) Now do a new set and see if it streams in
    set_with_revision!(store, b"a", b"a4", None);
    let next_msg = response_stream.next().await.unwrap().unwrap();
    assert_eq!(next_msg.events.len(), 1);
    assert_kv_value!(next_msg.events, 0, b"a4");
}

#[tokio::test]
async fn test_watch_delete_event() {
    // 1) Set up store and watch
    let store = Arc::new(Store::new(None));
    set_with_revision!(store, b"foo", b"bar", None); // rev 1
    let watch_service = WatchService::new(store.clone());

    let create_req = WatchRequest {
        request_union: Some(watch_request::RequestUnion::CreateRequest(
            WatchCreateRequest {
                key: b"foo".to_vec(),
                range_end: vec![],
                start_revision: 0,
                ..Default::default()
            },
        )),
    };

    let request = tonic_mock::streaming_request(vec![create_req]);
    let response = watch_service.watch(request).await.unwrap();
    let mut response_stream = response.into_inner();

    // Skip the initial creation event
    let _ = response_stream
        .next()
        .await
        .expect("missing creation msg")
        .unwrap();

    // 2) Delete the key
    let rev = store.delete(b"foo".to_vec(), None).await.unwrap();
    assert_eq!(rev, 2, "unexpected revision after delete");

    // 3) Confirm the watch sees a delete event
    let msg = response_stream
        .next()
        .await
        .expect("expected delete event")
        .unwrap();
    let events = msg.events;
    assert_eq!(events.len(), 1);
    let kv = events[0].kv.as_ref().expect("missing KV in event");
    assert_eq!(kv.key, b"foo");
    assert!(
        kv.value.is_empty(),
        "delete event should have an empty value field"
    );
}

#[tokio::test]
async fn test_watch_prev_kv_delete() {
    let store = Arc::new(Store::new(None));
    set_with_revision!(store, b"foo", b"bar", None); // rev 1
    let watch_service = WatchService::new(store.clone());

    let create_req = WatchRequest {
        request_union: Some(watch_request::RequestUnion::CreateRequest(
            WatchCreateRequest {
                key: b"foo".to_vec(),
                range_end: vec![],
                start_revision: 0,
                prev_kv: true,
                ..Default::default()
            },
        )),
    };

    let request = tonic_mock::streaming_request(vec![create_req]);
    let response = watch_service.watch(request).await.unwrap();
    let mut response_stream = response.into_inner();

    // Skip the initial creation event
    let _ = response_stream
        .next()
        .await
        .expect("missing creation msg")
        .unwrap();

    // 2) Delete the key
    let rev = store.delete(b"foo".to_vec(), None).await.unwrap();
    assert_eq!(rev, 2, "unexpected revision after delete");

    // 3) Confirm the watch sees a delete event
    let msg = response_stream
        .next()
        .await
        .expect("expected delete event")
        .unwrap();
    let events = msg.events;
    assert_eq!(events.len(), 1);
    let kv = events[0].kv.as_ref().expect("missing KV in event");
    assert_eq!(kv.key, b"foo");
    assert!(
        kv.value.is_empty(),
        "delete event should have an empty value field"
    );
    assert!(
        events[0].prev_kv.is_some(),
        "delete event should have a prev_kv field"
    );
}

#[tokio::test]
async fn test_watch_prev_kv_put() {
    let store = Arc::new(Store::new(None));
    set_with_revision!(store, b"foo", b"bar", None); // rev 1
    let watch_service = WatchService::new(store.clone());

    let create_req = WatchRequest {
        request_union: Some(watch_request::RequestUnion::CreateRequest(
            WatchCreateRequest {
                key: b"foo".to_vec(),
                range_end: vec![],
                start_revision: 0,
                prev_kv: true,
                ..Default::default()
            },
        )),
    };

    let request = tonic_mock::streaming_request(vec![create_req]);
    let response = watch_service.watch(request).await.unwrap();
    let mut response_stream = response.into_inner();

    // Skip the initial creation event
    let _ = response_stream
        .next()
        .await
        .expect("missing creation msg")
        .unwrap();

    // 2) Set the key
    set_with_revision!(store, b"foo", b"baz", None);

    // 3) Confirm the watch sees a put event
    let msg = response_stream
        .next()
        .await
        .expect("expected put event")
        .unwrap();
    let events = msg.events;
    assert_eq!(events.len(), 1);
    let kv = events[0].kv.as_ref().expect("missing KV in event");
    assert_eq!(kv.key, b"foo");
    assert_kv_value!(events, 0, b"baz");
    assert_eq!(
        events[0].prev_kv.as_ref().unwrap().value,
        as_bytes!(b"bar"),
        "prev_kv should be bar"
    );
}

#[tokio::test]
async fn test_watch_prev_kv_put_latest_rev() {
    // If client does a watch with prev_kv=tru and revision>0, still include prev_kv's whose modRevision < revision
    // 1) Create and populate store
    let store = Arc::new(Store::new(None));
    set_with_revision!(store, b"a", b"a1", None); // rev 1
    set_with_revision!(store, b"a", b"a2", None); // rev 2
    set_with_revision!(store, b"z", b"z3", None); // rev 3
    set_with_revision!(store, b"a", b"a4", None); // rev 4
    set_with_revision!(store, b"a", b"a5", None); // rev 5

    // 2) Create WatchService
    let watch_service = WatchService::new(store.clone());

    // Try both rev 3 (where key is different) and rev 4 (where key is the same)
    for start_revision in 3..=4 {
        let create_req = WatchRequest {
            request_union: Some(watch_request::RequestUnion::CreateRequest(
                WatchCreateRequest {
                key: b"a".to_vec(),
                range_end: b"b".to_vec(),
                start_revision: start_revision,
                prev_kv: true,
                ..Default::default()
                },
            )),
        };

        let request = tonic_mock::streaming_request(vec![create_req]);
        let response = watch_service.watch(request).await.unwrap();
        let mut response_stream = response.into_inner();

        // 4) The first messages returned from watch_service are the initial creation msg
        //    and then one containing the "past changes" (a2, a3, b1).
        //    The first message should have created: true, no events
        let first_msg = response_stream.next().await.unwrap().unwrap();
        assert!(first_msg.created, "expected created == true");
        assert!(
            first_msg.events.is_empty(),
            "expected no events in the creation response"
        );

        // 5) The second message should contain the past changes
        let second_msg = response_stream.next().await.unwrap().unwrap();
        let events = second_msg.events;
        assert_eq!(events.len(), 2, "expected 1 events for revs 4&5");
        assert_eq!(events[1].kv.as_ref().unwrap().value, as_bytes!(b"a5"));
        assert_eq!(events[1].prev_kv.as_ref().unwrap().mod_revision, 4);
        assert_eq!(events[0].kv.as_ref().unwrap().value, as_bytes!(b"a4"));

        // This is the critical part of the test
        assert_eq!(events[0].prev_kv.as_ref().unwrap().mod_revision, 2);
        assert_eq!(events[0].prev_kv.as_ref().unwrap().value, as_bytes!(b"a2"));
    }
}
