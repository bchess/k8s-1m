aws_region         = "us-east-1"
apiserver_replicas = 3
apiserver_cloud_details = {
  gcp = {
    zone = "us-central1-b"
    # instance_type = "c4a-standard-64" # 64/256GB $2.8736/hr
    instance_type = "c3d-standard-180" # 180/720  $2.36/hr
    # preemptible   = true
  }
}
etcd_cloud_details = {
  gcp = {
    zone          = "us-central1-b"
    instance_type = "c4-highmem-8" # 8/62G $0.521356/hr
    # instance_type     = "c4-highcpu-96" # 96/384G $4.08/hr
    # tier_1_networking = true
  }
}
kubelet_details = [
  {
    replicas = 2
    gcp = {
      zone          = "us-central1-b"
      instance_type = "c4d-highcpu-2" # 2/3G
      preemptible   = true
      # $0.48448/hr
    }
  }
]

victoriametrics_cloud_details = {
  gcp = {
    zone          = "us-central1-b"
    instance_type = "c3-standard-22" # $1.11/hr
    disk_size_gb  = 20
  }
}

dist_scheduler = {
  replicas    = 0
  gogc        = 700
  parallelism = 2
  // watch_pods  = true
}
