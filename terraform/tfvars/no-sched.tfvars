# 16 schedulers for 100k nodes
aws_region = "us-east-1"

apiserver_replicas = 3
apiserver_cloud_details = {
  gcp = {
    zone          = "us-central1-a"
    instance_type = "c3d-standard-180" # 180/720  $2.36/hr
    preemptible   = true
  }
}
etcd_cloud_details = {
  gcp = {
    zone          = "us-central1-a"
    instance_type = "c4-highmem-8" # 8/62G $0.521356/hr
    # tier_1_networking = true
  }
}
kubelet_details = [
  {
    replicas = 1
    gcp = {
      zone          = "us-central1-a"
      instance_type = "c4a-highcpu-32" # 32/64G
      preemptible   = true
      # $0.48448/hr
    }
  },
]

victoriametrics_cloud_details = {
  gcp = {
    zone          = "us-central1-a"
    instance_type = "c3-standard-8"
    disk_size_gb  = 20
  }
}

dist_scheduler = {
  replicas = 0
}
