use mem_etcd::store::Store;
use tokio::time::{timeout, Duration};
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

#[tokio::test]
async fn test_watch_past_results() {
    let s = Store::new(None);
    set_with_revision!(s, b"a", b"a1", None); // rev 1
    set_with_revision!(s, b"a", b"a2", None); // rev 2
    set_with_revision!(s, b"a", b"a3", None); // rev 3
    set_with_revision!(s, b"b", b"b1", None); // rev 4
    set_with_revision!(s, b"a", b"a4", None); // rev 5

    let (kvs, _, _) = s.watch(b"a".to_vec(), b"".to_vec(), 0, false).unwrap();
    assert_eq!(kvs.len(), 0, "unexpected kvs: {:?}", kvs);

    let (kvs, _, _) = s.watch(b"a".to_vec(), b"".to_vec(), 1, false).unwrap();
    assert_eq!(kvs.len(), 4, "unexpected kvs: {:?}", kvs);

    let (kvs, _, _) = s.watch(b"b".to_vec(), b"".to_vec(), 1, false).unwrap();
    assert_eq!(kvs.len(), 1, "unexpected kvs: {:?}", kvs);

    let (kvs, _, _) = s.watch(b"b".to_vec(), b"".to_vec(), 4, false).unwrap();
    assert_eq!(kvs.len(), 1, "unexpected kvs: {:?}", kvs);

    let (kvs, _, _) = s.watch(b"b".to_vec(), b"".to_vec(), 5, false).unwrap();
    assert_eq!(kvs.len(), 0, "unexpected kvs: {:?}", kvs);

    let (kvs, _, _) = s.watch(b"a".to_vec(), b"c".to_vec(), 1, false).unwrap();
    assert_eq!(kvs.len(), 5, "unexpected kvs: {:?}", kvs);
}

#[tokio::test]
async fn test_watch_at_compaction() {
    let s = Store::new(None);
    set_with_revision!(s, b"a", b"a1", None);
    set_with_revision!(s, b"a", b"a2", None);
    set_with_revision!(s, b"a", b"a3", None);
    set_with_revision!(s, b"b", b"b4", None);

    s.compact(3).unwrap();

    let (kvs, _, _) = s.watch(b"a".to_vec(), b"c".to_vec(), 3, false).unwrap();
    assert_eq!(kvs.len(), 2, "unexpected kvs: {:?}", kvs);
    assert_eq!(kvs[0].kv.value, b"a3".to_vec(), "unexpected value");
    assert_eq!(kvs[1].kv.value, b"b4".to_vec(), "unexpected value");
}

#[tokio::test]
async fn test_watch_single() {
    let s = Store::new(None);
    set_with_revision!(s, b"foo", b"v1", None);
    set_with_revision!(s, b"foo", b"v2", None);

    let (_, _, mut w) = s.watch(b"foo".to_vec(), b"".to_vec(), 0, false).unwrap();

    // Verify that w.ch is empty
    assert!(
        timeout(Duration::from_millis(10), w.recv()).await.is_err(),
        "unexpected event"
    );

    set_with_revision!(s, b"foo", b"v3", None);
    set_with_revision!(s, b"foo", b"v4", None);

    let c = timeout(Duration::from_millis(10), w.recv())
        .await
        .unwrap()
        .unwrap();
    assert_eq!(c.kv.value, b"v3".to_vec(), "unexpected value");

    let c = timeout(Duration::from_millis(10), w.recv())
        .await
        .unwrap()
        .unwrap();
    assert_eq!(c.kv.value, b"v4".to_vec(), "unexpected value");
}

#[tokio::test]
async fn test_watch_range() {
    let s = Store::new(None);
    set_with_revision!(s, b"a", b"a1", None);
    set_with_revision!(s, b"b", b"b1", None);

    let (_, _, mut a) = s.watch(b"a".to_vec(), b"".to_vec(), 0, false).unwrap();
    let (_, _, mut b) = s.watch(b"b".to_vec(), b"".to_vec(), 0, false).unwrap();
    let (_, _, mut ac) = s.watch(b"a".to_vec(), b"c".to_vec(), 0, false).unwrap();

    // Verify that all are empty
    assert!(
        timeout(Duration::from_millis(10), a.recv()).await.is_err(),
        "unexpected event"
    );
    assert!(
        timeout(Duration::from_millis(10), b.recv()).await.is_err(),
        "unexpected event"
    );
    assert!(
        timeout(Duration::from_millis(10), ac.recv()).await.is_err(),
        "unexpected event"
    );

    set_with_revision!(s, b"c", b"c1", None);
    // Verify that all are empty. Watch end range is exclusive.
    assert!(
        timeout(Duration::from_millis(10), a.recv()).await.is_err(),
        "unexpected event"
    );
    assert!(
        timeout(Duration::from_millis(10), b.recv()).await.is_err(),
        "unexpected event"
    );
    assert!(
        timeout(Duration::from_millis(10), ac.recv()).await.is_err(),
        "unexpected event"
    );

    set_with_revision!(s, b"a", b"a2", None);
    let v = timeout(Duration::from_millis(10), a.recv())
        .await
        .unwrap()
        .unwrap();
    assert_eq!(v.kv.value, b"a2".to_vec(), "unexpected value");

    let v = timeout(Duration::from_millis(10), ac.recv())
        .await
        .unwrap()
        .unwrap();
    assert_eq!(v.kv.value, b"a2".to_vec(), "unexpected value");

    assert!(
        timeout(Duration::from_millis(10), b.recv()).await.is_err(),
        "unexpected event"
    );

    set_with_revision!(s, b"b", b"b2", None);
    assert!(
        timeout(Duration::from_millis(10), a.recv()).await.is_err(),
        "unexpected event"
    );

    let v = timeout(Duration::from_millis(10), b.recv())
        .await
        .unwrap()
        .unwrap();
    assert_eq!(v.kv.key, b"b".to_vec(), "unexpected key");
    assert_eq!(v.kv.value, b"b2".to_vec(), "unexpected value");

    let v = timeout(Duration::from_millis(10), ac.recv())
        .await
        .unwrap()
        .unwrap();
    assert_eq!(v.kv.key, b"b".to_vec(), "unexpected key");
    assert_eq!(v.kv.value, b"b2".to_vec(), "unexpected value");

    assert!(
        timeout(Duration::from_millis(10), a.recv()).await.is_err(),
        "unexpected event"
    );
}

#[tokio::test]
async fn test_watch_revision_error() {
    let s = Store::new(None);
    set_with_revision!(s, b"a", b"a1", None);
    set_with_revision!(s, b"a", b"a2", None);
    set_with_revision!(s, b"a", b"a3", None);

    s.compact(2).unwrap();

    let result = s.watch(b"a".to_vec(), b"".to_vec(), 1, false);
    assert!(result.is_err(), "expected ErrCompacted");
}

#[tokio::test]
async fn test_watch_future_revision() {
    let s = Store::new(None);
    set_with_revision!(s, b"a", b"a1", None); // rev 1
    set_with_revision!(s, b"a", b"a2", None); // rev 2
    set_with_revision!(s, b"a", b"a3", None); // rev 3

    let (_, _, mut a) = s.watch(b"a".to_vec(), b"".to_vec(), 4, false).unwrap();
    assert!(
        timeout(Duration::from_millis(10), a.recv()).await.is_err(),
        "unexpected event"
    );

    set_with_revision!(s, b"a", b"a4", None); // rev 4
    let v = timeout(Duration::from_millis(10), a.recv())
        .await
        .unwrap()
        .unwrap();
    assert_eq!(v.kv.value, b"a4".to_vec(), "unexpected value");
}

#[tokio::test]
async fn test_watch_delete() {
    let s = Store::new(None);

    set_with_revision!(s, b"a", b"r1", None);
    set_with_revision!(s, b"a", b"r2", None);

    let rev = s.delete(b"a".to_vec(), None).await.unwrap();
    assert_eq!(rev, 3, "unexpected revision");

    let (revs, _, _) = s.watch(b"a".to_vec(), b"".to_vec(), 1, false).unwrap();
    assert_eq!(revs.len(), 3, "Expected 3 revisions, got {}", revs.len());
    assert_eq!(
        revs[0].kv.value,
        b"r1".to_vec(),
        "Expected r1, got {:?}",
        revs[0].kv.value
    );
    assert_eq!(
        revs[1].kv.value,
        b"r2".to_vec(),
        "Expected r2, got {:?}",
        revs[1].kv.value
    );
    assert_eq!(
        revs[2].kv.value,
        b"".to_vec(),
        "Expected value to be None, got {:?}",
        revs[2].kv.value
    );

    set_with_revision!(s, b"a", b"r3", None);
    let (_, _, mut w) = s.watch(b"a".to_vec(), b"".to_vec(), 4, false).unwrap();
    assert!(
        timeout(Duration::from_millis(10), w.recv()).await.is_err(),
        "unexpected event"
    );

    s.delete(b"a".to_vec(), None).await.unwrap();
    let v = timeout(Duration::from_millis(10), w.recv())
        .await
        .unwrap()
        .unwrap();
    assert_eq!(
        v.kv.value,
        b"".to_vec(),
        "Expected value to be None, got {:?}",
        v.kv.value
    );
}
