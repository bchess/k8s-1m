# tonic-mock

[tonic](https://docs.rs/tonic) is a great crate to build GRPC applications. However, testing RPC built with tonic is not straightforward, especially for the streaming interface. If you have an RPC like this:

```protobuf
rpc Push(stream RequestPush) returns (stream ResponsePush);
```

Testing it usually involves lots of effort on properly mocking the data. This little crate helps to make it easier to mock the incoming data and to manipulate the response so that you could focus on testing the logic itself. For example:

```rust
#[tokio::test]
async fn service_push_works() -> anyhow::Result<()> {
    let mut events: Vec<RequestPush> = Vec::with_capacity(3);
    for i in 0..3 {
        events.push(RequestPush::new(id: Bytes::from(i.to_string), data: Bytes::from("a".repeat(10))));
    }

    // preparing the streaming request
    let req = tonic_mock::streaming_request(events);

    let server = start_server();

    // call the service
    let res = server.push(req).await?;

    // iterate the response and assert the result
    tonic_mock::process_streaming_response(result, |msg, i| {
        assert!(msg.is_ok());
        assert_eq!(msg.as_ref().unwrap().code, i as i32);
    })
    .await;

    Ok(())
}
```

Three main functions provided:

- streaming_request: build streaming requests based on a vector of messages.
- process_streaming_response: iterate the streaming response and call the closure user provided.
- stream_to_vec: iterate the streaming response and generate a vector for further processing.

Note these functions are for testing purpose only. DO NOT use them in other cases.


## License

`prost-helper` is distributed under the terms of MIT.

See [LICENSE](LICENSE.md) for details.

Copyright 2021 Tyr Chen
