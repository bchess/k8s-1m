apiserver_replicas = 1
apiserver_cloud_details = {
  aws = {
    availability_zone = "us-west-2b"
    instance_type     = "m7a.16xlarge"
    disk_size_gb      = 100
  }
}
etcd_cloud_details = {
  aws = {
    availability_zone = "us-west-2b"
    instance_type     = "r7i.2xlarge"
  }
}
kubelet_details = [
  {
    replicas = 1
    aws = {
      availability_zone = "us-west-2b"
      instance_type     = "c7i.16xlarge"
      disk_size_gb      = 200
    }
  }
]

victoriametrics_cloud_details = {
  aws = {
    availability_zone = "us-west-2b"
    instance_type     = "t3a.small"
  }
}
