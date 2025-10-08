module "kubelet" {
  count = length(var.kubelet_details)

  offset = count.index > 0 ? sum([for k, v in slice(var.kubelet_details, 0, count.index) : v.replicas]) : 0

  source = "./kubelet-server"

  apiserver_hostname = module.k8s_server[0].server_hostname
  k3s_token          = module.k8s_server[0].k3s_token
  ssh_key_url        = local.ssh_key_url
  replicas           = var.kubelet_details[count.index].replicas
  ipv4gateway = {
    hostname = module.ipv4_gateway.hostname
    password = module.ipv4_gateway.password
  }
  victoriametrics_password = module.victoriametrics.password

  cloud_details = var.kubelet_details[count.index]
  cloud_infra   = local.cloud_infra

  pin_cpus = var.kubelet_details[count.index].pin_cpus

  extra_labels = {
    "pool-id" = count.index
  }

  zone_id = module.dns.zone_id
}

resource "kubernetes_namespace_v1" "kubelet" {
  count = var.kubelet_pod_replicas > 0 ? 1 : 0
  metadata {
    name = "kubelet"
  }
}

module "kubelet_pod" {
  count              = var.kubelet_pod_replicas > 0 ? 1 : 0
  source             = "./kubelet-pod"
  apiserver_hostname = module.k8s_server[0].server_hostname
  k3s_token          = module.k8s_server[0].k3s_token
  replicas           = var.kubelet_pod_replicas
  namespace          = kubernetes_namespace_v1.kubelet[0].metadata[0].name
  node_selector = {
    "pool-id" = "1"
  }
  pull_secret_name = module.kubernetes.pull_secret_name
}

locals {
  kubelet_replicas_sum = length(var.kubelet_details) > 0 ? sum([for k, v in var.kubelet_details : v.replicas]) : 0
}
resource "aws_route53_record" "kubelets" {
  count   = ceil(local.kubelet_replicas_sum / 10)
  name    = "kubelets-${count.index}"
  zone_id = module.dns.zone_id
  type    = "AAAA"
  ttl     = 60
  records = slice(
    flatten(module.kubelet[*].ips),
    count.index * 10,
  min(local.kubelet_replicas_sum, count.index * 10 + 10))
}
