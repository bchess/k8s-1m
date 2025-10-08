apiserver_replicas = 3
apiserver_cloud_details = {
  aws = {
    availability_zone = "us-west-2d"
    instance_type     = "m7g.16xlarge" # 64/256GB
    spot_price        = 6.00
  }
}
etcd_cloud_details = {
  aws = {
    availability_zone = "us-west-2d"
    # consider moving to c6in.8xlarge for same 64GB of memory but 50Gbps of network
    instance_type = "r7i.2xlarge" # 8/64G
    # instance_type = "m6in.4xlarge" # 16/64G
  }
}
kubelet_details = [
  {
    replicas = 9
    aws = {
      availability_zone = "us-west-2d"
      instance_type     = "c7g.8xlarge" # 32/64G
      spot_price        = 6.00
    }
  },
  {
    replicas = 10
    aws = {
      availability_zone = "us-west-2d"
      instance_type     = "c7g.8xlarge" # 32/64G
      # spot_price        = 6.00
    }
  },
]

victoriametrics_cloud_details = {
  aws = {
    availability_zone = "us-west-2d"
    instance_type     = "t3a.xlarge"
    disk_size_gb      = 100
  }
}
