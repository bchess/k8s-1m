fn main() -> Result<(), Box<dyn std::error::Error>> {
    tonic_build::configure()
        .build_client(true)
        .build_server(false)
        .bytes(&["KeyValue.value", "PutRequest.value"])
        .compile_protos(&["../extern/etcd/api/rpc.proto"], &["../extern", "../extern/etcd/api"])?;
    Ok(())
}

