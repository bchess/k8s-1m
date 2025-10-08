apiserver_replicas = 6
apiserver_cloud_details = {
  gcp = {
    zone          = "us-central1-a"
    instance_type = "c4d-standard-192"
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
      instance_type = "c4a-highcpu-32"
      preemptible   = true
    }
  },
  {
    replicas = 2 # 426
    gcp = {
      zone = "us-central1-a"
      # instance_type = "c4a-highmem-8"
      instance_type = "c4a-standard-32"
      preemptible   = true
      disk_size_gb  = 80
    },
    pin_cpus = false
  },
]

victoriametrics_cloud_details = {
  gcp = {
    zone          = "us-central1-a"
    instance_type = "c3-standard-22"
    disk_size_gb  = 20
  }
}


# kube_scheduler_cloud_details = {
#   gcp = {
#     zone          = "us-central1-a"
#     instance_type = "c4a-standard-16" # 16/64G # $0.7184/hr
#   }
# }

kubelet_pod_replicas = 1

# dist_scheduler = {
#   replicas   = 1
#   gogc       = 700
#   watch_pods = true
# }

deploy_parca     = false
deploy_fluentbit = true
