# 64 schedulers for 200k-300k nodes
aws_region = "us-east-1"

apiserver_replicas = 3
apiserver_cloud_details = {
  aws = {
    availability_zone = "us-east-1f"
    instance_type     = "m7g.16xlarge" # 64/256GB
    spot_price        = 6.00
  }
}
etcd_cloud_details = {
  aws = {
    availability_zone = "us-east-1f"
    # consider moving to c6in.8xlarge for same 64GB of memory but 50Gbps of network
    instance_type = "r7i.2xlarge" # 8/64G
    # instance_type = "m6in.4xlarge" # 16/64G
  }
}
kubelet_details = [
  {
    replicas = 36
    aws = {
      availability_zone = "us-east-1f"
      instance_type     = "c7g.8xlarge" # 32/64G
      spot_price        = 6.00
    }
  },
  {
    replicas = 2
    aws = {
      availability_zone = "us-east-1f"
      instance_type     = "m7g.8xlarge" # 32/128G
      # spot_price        = 6.00
    }
  },
]

victoriametrics_cloud_details = {
  aws = {
    availability_zone = "us-east-1f"
    instance_type     = "t3a.xlarge"
    disk_size_gb      = 20
  }
}

dist_scheduler = {
  replicas = 64
  gogc = 700
}
