apiserver_replicas = 3
apiserver_cloud_details = {
  gcp = {
    zone = "us-central1-a"
    # instance_type = "c4a-standard-64" # 64/256GB $2.8736/hr
    instance_type = "c3d-standard-180" # 180/720 
    preemptible   = true
  }
}
etcd_cloud_details = {
  gcp = {
    zone = "us-central1-a"
    # instance_type = "c4-highmem-8" # 8/62G $0.521356/hr
    instance_type     = "c4-highcpu-48" # 48/192G
    tier_1_networking = true
  }
}
kubelet_details = [
  {
    replicas = 9
    gcp = {
      zone          = "us-central1-a"
      instance_type = "c4d-highcpu-32" # 32/64G
      preemptible   = true
      # $0.48448/hr
    }
  },
  {
    replicas = 2
    gcp = {
      zone          = "us-central1-a"
      instance_type = "c4a-standard-32" # 32/128G
      preemptible   = true
      # $0.5741/hr
    }
  }
]

kube_scheduler_cloud_details = {
  gcp = {
    zone          = "us-central1-a"
    instance_type = "c4a-standard-16" # 16/64G # $0.7184/hr
  }
}

victoriametrics_cloud_details = {
  gcp = {
    zone          = "us-central1-a"
    instance_type = "c3-standard-22" # 	$1.11/hr
    disk_size_gb  = 20
  }
}

dist_scheduler = {
  replicas    = 16
  cores       = 14
  parallelism = 2
  gogc        = 700
  watch_pods  = true
}
