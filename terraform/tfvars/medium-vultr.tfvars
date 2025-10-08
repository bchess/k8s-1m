# approx $7.00/hr

apiserver_replicas = 3
apiserver_cloud_details = {
  vultr = {
    region = "lax"
    plan   = "voc-m-32c-256gb-1600s-amd"
  }
}
etcd_cloud_details = {
  vultr = {
    region = "lax"
    plan   = "voc-m-8c-64gb-400s-amd"
  }
}
kubelet_details = [
  {
    replicas = 6
    vultr = {
      region = "lax"
      plan   = "voc-c-32c-64gb-500s-amd"
      # plan   = "voc-g-32c-128gb-640s-amd"
    }
  }
]

victoriametrics_cloud_details = {
  vultr = {
    region = "lax"
    plan   = "vhp-4c-8gb-amd"
  }
}
