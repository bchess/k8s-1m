use mem_etcd::store::{Store, RangeResult, SetRequired};
use std::io::Write;
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
async fn test_range_revision() {
    let s = Store::new(None);
    let rev = s.set(b"foo".to_vec(), Some(as_bytes!(b"bar")),
        Some(SetRequired{required_last_revision: Some(0), required_version: None})).await.unwrap();
    assert_eq!(rev, 1, "unexpected revision");

    let RangeResult { kvs, latest_rev: rev, .. } = s.range(b"foo".to_vec(), b"".to_vec(), 0, None).unwrap();
    assert_eq!(kvs.len(), 1, "unexpected kv {:?}", kvs);
    assert_eq!(kvs[0].key, b"foo".to_vec(), "unexpected key");
    assert_eq!(kvs[0].value, b"bar".to_vec(), "unexpected value");
    assert_eq!(rev, 1, "unexpected revision");

    let rev = s.set(b"foo".to_vec(), Some(as_bytes!(b"baz")), None).await.unwrap();
    assert_eq!(rev, 2, "unexpected revision");

    let RangeResult { kvs, latest_rev: rev, .. } = s.range(b"foo".to_vec(), b"".to_vec(), 0, None).unwrap();
    assert_eq!(kvs.len(), 1, "unexpected kv {:?}", kvs);
    assert_eq!(rev, 2, "unexpected revision");
    assert_eq!(kvs[0].key, b"foo".to_vec(), "unexpected key");
    assert_eq!(kvs[0].value, b"baz".to_vec(), "unexpected value");

    let RangeResult { kvs, latest_rev: rev, .. } = s.range(b"foo".to_vec(), b"".to_vec(), 1, None).unwrap();
    assert_eq!(kvs.len(), 1, "unexpected kv {:?}", kvs);
    assert_eq!(rev, 2, "unexpected revision");
    assert_eq!(kvs[0].key, b"foo".to_vec(), "unexpected key");
    assert_eq!(kvs[0].value, b"bar".to_vec(), "unexpected value");

    let result = s.range(b"foo".to_vec(), b"".to_vec(), 3, None);
    assert!(result.is_err(), "expected error");
}

#[tokio::test]
async fn test_range() {
    let s = Store::new(None);
    set_with_revision!(s, b"foo", b"bar", None);
    set_with_revision!(s, b"foo1", b"bar1", None);
    set_with_revision!(s, b"foo2", b"bar2", None);
    set_with_revision!(s, b"foo3", b"bar3", None);
    set_with_revision!(s, b"foo4", b"bar4", None);
    set_with_revision!(s, b"foo", b"baz", None);

    let RangeResult { kvs, latest_rev: rev, .. } = s.range(b"foo".to_vec(), b"fooz".to_vec(), 0, None).unwrap();
    assert_eq!(kvs.len(), 5, "unexpected kvs: {:?}", kvs);
    assert_eq!(rev, 6, "unexpected revision");
    assert_eq!(kvs[0].key, b"foo".to_vec(), "unexpected key");
    assert_eq!(kvs[0].value, b"baz".to_vec(), "unexpected value");
    assert_eq!(kvs[1].key, b"foo1".to_vec(), "unexpected key");
    assert_eq!(kvs[4].key, b"foo4".to_vec(), "unexpected key");

    let RangeResult { kvs, latest_rev: rev, .. }  = s.range(b"foo".to_vec(), b"fooz".to_vec(), 3, None).unwrap();
    assert_eq!(kvs.len(), 3, "unexpected kvs: {:?}", kvs);
    assert_eq!(rev, 6, "unexpected revision");
    assert_eq!(kvs[0].key, b"foo".to_vec(), "unexpected key");
    assert_eq!(kvs[1].key, b"foo1".to_vec(), "unexpected key");
    assert_eq!(kvs[2].key, b"foo2".to_vec(), "unexpected key");
}

#[tokio::test]
async fn test_range_slashes() {
    let s = Store::new(None);
    let RangeResult { kvs, .. } = s
        .range(b"/a/b/c/".to_vec(), b"/a/b/c0".to_vec(), 0, None)
        .unwrap();
    assert_eq!(kvs.len(), 0, "unexpected kvs: {:?}", kvs);

    set_with_revision!(s, b"/registry/apiextensions.k8s.io/customresourcedefinitions/addons", b"bar", None);
    let RangeResult { kvs, .. } = s.range(b"/registry/apiextensions.k8s.io/customresourcedefinitions/addons".to_vec(), b"".to_vec(), 0, None).unwrap();
    assert_eq!(kvs.len(), 1, "unexpected kvs: {:?}", kvs);

    set_with_revision!(s, b"/bootstrap/aaa", b"bar", None);
    let RangeResult { kvs, .. } = s
        .range(b"/bootstrap".to_vec(), b"/bootstraq".to_vec(), 0, None)
        .unwrap();
    assert_eq!(kvs.len(), 1, "unexpected kvs: {:?}", kvs);
}

#[tokio::test]
async fn test_compaction_one() {
    let s = Store::new(None);
    // rev 1
    let rev = s.set(b"foo".to_vec(), Some(as_bytes!(b"bar")), None).await.unwrap();
    assert_eq!(rev, 1, "unexpected revision");

    s.compact(1).unwrap();

    let RangeResult { kvs, latest_rev: rev, .. } = s.range(b"foo".to_vec(), b"".to_vec(), 0, None).unwrap();
    assert_eq!(kvs.len(), 1, "unexpected kvs after compaction");
    assert_eq!(kvs[0].value, b"bar".to_vec(), "unexpected value");
    assert_eq!(rev, 1, "expected revision 1");
}

#[tokio::test]
async fn test_compaction() {
    let s = Store::new(None);
    set_with_revision!(s, b"foo", b"bar1", None); // rev 1
    set_with_revision!(s, b"foo2", b"v2", None); // rev 2
    set_with_revision!(s, b"foo", b"bar2", None); // rev 3
    set_with_revision!(s, b"foo", b"bar3", None); // rev 4
    set_with_revision!(s, b"foo", b"bar4", None); // rev 5
    set_with_revision!(s, b"foo", b"bar5", None); // rev 6

    let RangeResult { latest_rev: rev, .. } = s.range(b"foo".to_vec(), b"".to_vec(), 0, None).unwrap();
    assert_eq!(rev, 6, "unexpected revision after sets");

    // Compact everything <= 3
    s.compact(3).unwrap();

    // Trying to get revision 2 or 3 for "foo" should fail now
    let should_fail = s.range(b"foo".to_vec(), b"".to_vec(), 2, None);
    assert!(should_fail.is_err(), "expected error after compaction");

    // We can still read at or after 3 for "foo2"
    let RangeResult { kvs, latest_rev: rev, .. } = s.range(b"foo2".to_vec(), b"".to_vec(), 3, None).unwrap();

    assert_eq!(rev, 6, "unexpected revision from range on foo2");
    assert_eq!(kvs.len(), 1, "unexpected kvs for foo2 at rev 3");
    assert_eq!(kvs[0].key, b"foo2".to_vec(), "unexpected key");
    assert_eq!(kvs[0].value, b"v2".to_vec(), "unexpected value");
}

#[tokio::test]
async fn test_set_txn_revision() {
    let s = Store::new(None);
    // revision 1
    let rev = set_with_revision!(s, b"foo", b"r1", None);
    assert_eq!(rev, 1, "unexpected revision");

    // Set with required revision = 1
    let rev = set_with_revision!(s, b"foo", b"r2", Some(SetRequired{required_last_revision: Some(1), required_version: None}));
    assert_eq!(rev, 2, "unexpected revision");

    // Another set
    let rev = set_with_revision!(s, b"foo", b"r3", None);
    assert_eq!(rev, 3, "unexpected revision");

    let (rev, _val) = s.set(b"foo".to_vec(), Some(as_bytes!(b"r4")), Some(SetRequired{required_last_revision: Some(1), required_version: None})).await.unwrap_err();
    assert_eq!(rev, 3, "unexpected revision");

    let RangeResult { kvs, .. } = s.range(b"foo".to_vec(), b"".to_vec(), 0, None).unwrap();
    assert!(kvs[0].value == b"r3".to_vec())
}

#[tokio::test]
async fn test_set_txn_version() {
    let s = Store::new(None);
    let _ = s.set(b"a".to_vec(), Some(as_bytes!(b"r1")), None).await.unwrap();

    // revision 2, version 1
    s.set(b"foo".to_vec(), Some(as_bytes!(b"r2")), None).await.unwrap();

    // Set with required version == 1
    let rev = set_with_revision!(s, b"foo", b"r3", Some(SetRequired{required_last_revision: None, required_version: Some(1)}));
    assert_eq!(rev, 3, "unexpected revision");

    // Another set, version 2
    let rev = set_with_revision!(s, b"foo", b"r4", None);
    assert_eq!(rev, 4, "unexpected revision");

    // Set with required version == 1 should fail
    let (rev, _val) = s.set(b"foo".to_vec(), Some(as_bytes!(b"r5")), Some(SetRequired{required_last_revision: None, required_version: Some(1)})).await.unwrap_err();
    assert_eq!(rev, 4, "unexpected revision");

    // Delete the key, then set with required version 0 should work
    s.delete(b"foo".to_vec(), None).await.unwrap(); // rev 5
    let rev = set_with_revision!(s, b"foo", b"r6", Some(SetRequired{required_last_revision: None, required_version: Some(0)}));
    assert_eq!(rev, 6, "unexpected revision");

    // Creating a new key with required version 0 should work
    let rev = set_with_revision!(s, b"bar", b"r7", Some(SetRequired{required_last_revision: None, required_version: Some(0)}));
    assert_eq!(rev, 7, "unexpected revision");
}

#[tokio::test]
async fn test_delete() {
    let s = Store::new(None);
    set_with_revision!(s, b"a", b"r1", None);
    set_with_revision!(s, b"a", b"r2", None);

    // Delete a non-existent key
    let (rev, _) = s.delete(b"b".to_vec(), None).await.unwrap_err();
    assert_eq!(rev, 2, "unexpected revision"); // negative rev indicates the key does not exist

    let rev = s.delete(b"a".to_vec(), None).await.unwrap();
    assert_eq!(rev, 3, "unexpected revision");

    let RangeResult { kvs, .. } = s.range(b"a".to_vec(), b"".to_vec(), 0, None).unwrap();
    assert!(kvs.is_empty(), "unexpected kvs: {:?}", kvs);

    // Delete a key that's already deleted
    let (rev, _) = s.delete(b"a".to_vec(), None).await.unwrap_err();
    assert_eq!(rev, 3, "unexpected revision"); // negative rev indicates the key does not exist

    // Re-create a deleted key
    s.set(b"a".to_vec(), Some(as_bytes!(b"r3")), None).await.unwrap();
    let RangeResult { kvs, .. } = s.range(b"a".to_vec(), b"".to_vec(), 0, None).unwrap();
    assert_eq!(
        kvs[0].create_revision, 4,
        "CreateRevision expected to be 4, was instead {}",
        kvs[0].create_revision
    );
    assert_eq!(
        kvs[0].value,
        b"r3".to_vec(),
        "Expected r3, got {:?}",
        kvs[0].value
    );
}

#[tokio::test]
async fn test_delete_revision() {
    let s = Store::new(None);
    set_with_revision!(s, b"a", b"r1", None);
    set_with_revision!(s, b"a", b"r2", None);

    let (rev, v) = s.delete(b"a".to_vec(), Some(SetRequired{required_last_revision: Some(1), required_version: None})).await.unwrap_err();
    assert_eq!(rev, 2, "unexpected revision");
    assert!(
        v.is_some(),
        "Expected Delete to fail and value to be returned"
    );

    let rev = s.delete(b"a".to_vec(), Some(SetRequired{required_last_revision: Some(2), required_version: None})).await.unwrap();
    assert_eq!(rev, 3, "unexpected revision");
}

#[tokio::test]
async fn test_range_large() {
    let s = Store::new(None);
    for _d in 0..10 {
        for i in 0..100_000 {
            let mut value = Vec::from(format!("value{}", i).as_bytes());
            value.resize(4096, 0);
            s.set(format!("key{}", i).as_bytes().to_vec(), Some(Bytes::from(value)), None).await.unwrap();
        }

        /*
        let start = std::time::Instant::now();
        let RangeResult { kvs, .. } = s.range(b"a".to_vec(), b"z".to_vec(), 1_000_000 * d, None).unwrap();
        let end = std::time::Instant::now();
        let full_duration = end.duration_since(start);
        assert_eq!(kvs.len(), 1000000, "unexpected kvs length {:?}", kvs.len());
        println!("Full range # {:?} took {:?}", d, full_duration);
        */
    }

    write_perf_marker("measurement_start");
    std::thread::sleep(std::time::Duration::from_secs(1));
    let start = std::time::Instant::now();
    let RangeResult { kvs, count, .. } = s.range(b"a".to_vec(), b"z".to_vec(), 500_000, Some(500)).unwrap();
    let end = std::time::Instant::now();
    std::thread::sleep(std::time::Duration::from_secs(1));
    write_perf_marker("measurement_end");

    assert_eq!(kvs.len(), 500, "unexpected kv length: {:?}", kvs.len());
    assert_eq!(count, 100_000, "unexpected count: {:?}", count);
    std::hint::black_box(kvs);
    let partial_duration = end.duration_since(start);
    println!("Limit 500 Range took {:?}", partial_duration);
}

fn write_perf_marker(marker: &str) {
    if let Ok(mut file) = std::fs::OpenOptions::new()
        .write(true)
        .open("/sys/kernel/debug/tracing/trace_marker")
    {
        let _ = writeln!(file, "{}", marker);
    }
}