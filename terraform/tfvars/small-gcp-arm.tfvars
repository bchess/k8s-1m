victoriametrics_cloud_details = {
  gcp = {
    zone          = "us-central1-a"
    instance_type = "n1-standard-1"
  }
}

apiserver_replicas = 1
apiserver_cloud_details = {
  gcp = {
    zone          = "us-central1-a"
    instance_type = "c4a-standard-1"
  }
}

etcd_cloud_details = {
  gcp = {
    zone          = "us-central1-a"
    instance_type = "n1-standard-1"
  }
}

kubelet_details = [
  {
    replicas = 1,
    gcp = {
      zone          = "us-central1-a"
      instance_type = "c4a-standard-1"
    }
  }
]
