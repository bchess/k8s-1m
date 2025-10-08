aws_region         = "us-east-1"
apiserver_replicas = 11
apiserver_cloud_details = {
  gcp = {
    zone = "us-central1-c"
    # instance_type = "c3d-standard-180" # 180/720  $2.36/hr
    instance_type = "c4a-highmem-72" # 64/256GB $2.8736/hr
    preemptible   = true
  }
}
etcd_cloud_details = {
  gcp = {
    zone          = "us-central1-c"
    instance_type = "c4d-highmem-16" # 16/128G $0.9637/hr
  }
}
kubelet_details = [
  {
    replicas = 285 # 9120 cores total
    gcp = {
      zone          = "us-central1-c"
      instance_type = "c4a-highcpu-32" # 32/64G
      preemptible   = true
      # $0.48448/hr
    }
  },
  {
    replicas = 15 # 480 cores total
    gcp = {
      zone          = "us-central1-c"
      instance_type = "c4a-highcpu-32" # 32/64G
      preemptible   = true
    }
  },
]

kube_scheduler_cloud_details = {
  gcp = {
    zone          = "us-central1-c"
    instance_type = "c4a-standard-16" # 16/64G # $0.7184/hr
  }
}

victoriametrics_cloud_details = {
  gcp = {
    zone          = "us-central1-c"
    instance_type = "c3-standard-22" # $1.11/hr
    disk_size_gb  = 20
  }
}

dist_scheduler = {
  replicas    = 512
  gogc        = 700
  parallelism = 2
  watch_pods  = false
}
