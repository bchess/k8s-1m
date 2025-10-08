aws_region = "us-east-1"

apiserver_replicas = 3
apiserver_cloud_details = {
  aws = {
    availability_zone = "us-east-1a"
    instance_type     = "m7g.16xlarge" # 32/128GB
    spot_price        = 6.00
  }
}
etcd_cloud_details = {
  aws = {
    availability_zone = "us-east-1a"
    # consider moving to c6in.8xlarge for same 64GB of memory but 50Gbps of network
    instance_type = "r7i.2xlarge" # 8/64G
    # instance_type = "m6in.4xlarge" # 16/64G
  }
}
kubelet_details = [
  {
    replicas = 4
    aws = {
      availability_zone = "us-east-1a"
      instance_type     = "c7g.8xlarge" # 32/64G
      spot_price        = 6.00
    }
  },
  {
    replicas = 1
    aws = {
      availability_zone = "us-east-1a"
      instance_type     = "c7g.8xlarge" # 32/64G
      spot_price        = 6.00
    }
  },
]

victoriametrics_cloud_details = {
  aws = {
    availability_zone = "us-east-1a"
    instance_type     = "t3a.medium"
    disk_size_gb      = 20
  }
}

dist_scheduler = {
  replicas = 8
}