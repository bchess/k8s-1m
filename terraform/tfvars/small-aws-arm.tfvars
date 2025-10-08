victoriametrics_cloud_details = {
  aws = {
    availability_zone = "us-west-2b"
    instance_type     = "t3a.small" # VM not supporting arm
  }
}

apiserver_replicas = 1
apiserver_cloud_details = {
  aws = {
    availability_zone = "us-west-2b"
    instance_type     = "t4g.small"
  }
}

etcd_cloud_details = {
  aws = {
    availability_zone = "us-west-2b"
    instance_type     = "t3a.micro" # etcd not supporting arm
  }
}

kubelet_details = [
  {
    replicas = 1
    aws = {
      availability_zone = "us-west-2b"
      instance_type     = "t4g.micro"
    }
  }
]
