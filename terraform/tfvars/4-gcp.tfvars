apiserver_replicas = 1
apiserver_cloud_details = {
  gcp = {
    zone          = "us-central1-a"
    instance_type = "c3d-standard-8" # 8/32GB $0.29/hr
    preemptible   = true
  }
}
etcd_cloud_details = {
  gcp = {
    zone          = "us-central1-a"
    instance_type = "c4-highmem-8" # 8/62G $0.521356/hr
  }
}
kubelet_details = [
  {
    replicas = 0
    gcp = {
      zone          = "us-central1-a"
      instance_type = "c4a-highcpu-32" # 32/64G
      preemptible   = true
      # $0.48448/hr
    }
  },
  {
    replicas = 1
    gcp = {
      zone          = "us-central1-a"
      instance_type = "c4a-standard-32" # 32/128G
      preemptible   = true
      # $0.5741/hr
    }
  }
]

victoriametrics_cloud_details = {
  gcp = {
    zone          = "us-central1-a"
    instance_type = "c3-standard-4"
    disk_size_gb  = 20
  }
}

dist_scheduler = {
  replicas   = 4
  gogc       = 700
  watch_pods = true
}
