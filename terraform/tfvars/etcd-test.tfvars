aws_region         = "us-east-1"
apiserver_replicas = 1
apiserver_cloud_details = {
  gcp = {
    # for running benchmark
    zone          = "us-central1-c"
    instance_type = "c4d-highcpu-192"
    preemptible   = true
  }
}
etcd_cloud_details = {
  gcp = {
    zone          = "us-central1-c"
    instance_type = "c4d-highcpu-192" # 16/128G $0.9637/hr
    preemptible   = true
  }
}
kubelet_details = [
  {
    replicas = 0
    gcp = {
      zone          = "us-central1-c"
      instance_type = "c4a-highcpu-32" # 32/64G
      preemptible   = true
    }
  },
  {
    replicas = 0
    gcp = {
      zone          = "us-central1-c"
      instance_type = "c4a-highcpu-32" # 32/64G
      preemptible   = true
      # $0.48448/hr
    }
  },
]

victoriametrics_cloud_details = {
  gcp = {
    zone          = "us-central1-c"
    instance_type = "c3d-standard-16" # $0.7236hr
    disk_size_gb  = 20
  }
}

dist_scheduler = {
  replicas    = 0
  gogc        = 700
  parallelism = 2
  watch_pods  = false
}
