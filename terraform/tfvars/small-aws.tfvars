aws_region = "us-west-2"
# approx $0.03/hr
victoriametrics_cloud_details = {
  aws = {
    availability_zone = "us-west-2b"
    instance_type     = "t3a.micro"
    spot_price        = 0.01
  }
}

apiserver_replicas = 3
apiserver_cloud_details = {
  aws = {
    availability_zone = "us-west-2b"
    instance_type     = "t3a.small"
    spot_price        = 0.05
  }
}

etcd_cloud_details = {
  aws = {
    availability_zone = "us-west-2b"
    instance_type     = "t3a.micro"
    spot_price        = 0.05
  }
}

kube_scheduler_cloud_details = {
  aws = {
    availability_zone = "us-west-2b"
    instance_type     = "t3a.micro"
    spot_price        = 0.05
  }
}

kubelet_details = []
