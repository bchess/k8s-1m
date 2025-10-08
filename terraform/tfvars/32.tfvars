# 32 schedulers for 200k nodes
aws_region = "us-east-1"

apiserver_replicas = 3
apiserver_cloud_details = {
  aws = {
    availability_zone = "us-east-1a"
    instance_type     = "m7g.16xlarge" # 64/256GB $0.6905/hr
    spot_price        = 6.00
  }
}
etcd_cloud_details = {
  aws = {
    availability_zone = "us-east-1a"
    instance_type     = "r7i.2xlarge" # 8/64G
  }
}
kubelet_details = [
  {
    replicas = 16
    aws = {
      availability_zone = "us-east-1a"
      instance_type     = "c7g.8xlarge" # 32/64G $0.3082/hr
      spot_price        = 6.00
    }
  },
  {
    replicas = 2
    aws = {
      availability_zone = "us-east-1a"
      instance_type     = "m7g.8xlarge" # 32/64G $0.3817
      spot_price        = 6.00
    }
  },
]

victoriametrics_cloud_details = {
  aws = {
    availability_zone = "us-east-1a"
    instance_type     = "t3a.xlarge"
    disk_size_gb      = 20
  }
}

dist_scheduler = {
  replicas = 32
}
