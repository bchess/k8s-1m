# approx $0.03/hr
victoriametrics_cloud_details = {
  aws = {
    availability_zone = "us-west-2d"
    instance_type     = "t3a.micro"
    spot_price        = 0.01
  }
}

apiserver_replicas = 1
apiserver_cloud_details = {
  aws = {
    availability_zone = "us-west-2d"
    instance_type     = "t3a.small"
    spot_price        = 0.01
  }
}

etcd_cloud_details = {
  aws = {
    availability_zone = "us-west-2d"
    instance_type     = "t3a.small"
    spot_price        = 0.01
  }
}

kubelet_details = [
  {
    replicas = 4
    aws = {
      availability_zone = "us-west-2d"
      instance_type = "" # TODO
      min_vcpu          = 2
      min_memory_mib    = 4096
      spot_price        = 1.01
    }
  }
]
