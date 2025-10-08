aws_region         = "us-east-1"
apiserver_replicas = 5
apiserver_cloud_details = {
  gcp = {
    zone          = "us-central1-a"
    instance_type = "c4d-standard-192"
    # instance_type = "c4a-highmem-72" # 64/256GB $2.8736/hr
    preemptible = true
  }
}
etcd_cloud_details = {
  gcp = {
    zone          = "us-central1-a"
    instance_type = "c4d-highmem-16" # 16/128G $0.9637/hr
  }
}
kubelet_details = [
  {
    replicas = 1 # 285
    gcp = {
      zone          = "us-central1-a"
      instance_type = "c4d-highcpu-32" # 32/64G
      preemptible   = true
    }
  },
  {
    replicas = 15 # 480 cores total
    gcp = {
      zone          = "us-central1-c"
      instance_type = "c4a-highcpu-32" # 32/128G
      preemptible   = true
    }
  },
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
    instance_type = "c3-standard-22" # $1.11/hr
    disk_size_gb  = 20
  }
}

dist_scheduler = {
  replicas       = 256
  num_schedulers = 30
  cores          = 30
  gogc           = 700
  parallelism    = 2
  watch_pods     = false
}
