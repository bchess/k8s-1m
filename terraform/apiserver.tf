module "dns" {
  source = "./dns"
  domain = var.domain
}

module "ipv4_gateway" {
  source = "./ipv4-gateway"

  zone_id     = module.dns.zone_id
  ssh_key_url = local.ssh_key_url
  region      = var.ipv4_gateway_vultr_region
}

module "k8s_server" {
  count = var.apiserver_replicas > 0 ? 1 : 0

  source = "./k8s-server"

  ipv4gateway = {
    hostname = module.ipv4_gateway.hostname
    password = module.ipv4_gateway.password
  }

  replicas = var.apiserver_replicas
  zone_id  = module.dns.zone_id

  separate_etcd = var.separate_etcd
  ssh_key_url   = local.ssh_key_url

  victoriametrics_password = module.victoriametrics.password

  cloud_details                = var.apiserver_cloud_details
  etcd_cloud_details           = var.etcd_cloud_details
  cloud_infra                  = local.cloud_infra
  kube_scheduler_cloud_details = var.kube_scheduler_cloud_details
}


provider "kubernetes" {
  # config_path            = local_file.kubeconfig.filename
  host                   = module.k8s_server[0].kube_config.host
  client_certificate     = module.k8s_server[0].kube_config.client_certificate
  client_key             = module.k8s_server[0].kube_config.client_key
  cluster_ca_certificate = module.k8s_server[0].kube_config.cluster_ca_certificate
  tls_server_name        = "kubernetes"
}

resource "local_file" "kubeconfig" {
  content  = module.k8s_server[0].kube_config.content
  filename = "kube_config.yaml"
}

module "kubernetes" {
  source = "./kubernetes"

  monitoring_hostname = module.victoriametrics.monitoring_hostname
  monitoring_auth     = module.victoriametrics.auth
  ca_crt              = tls_self_signed_cert.ca_cert.cert_pem
  dist_scheduler      = var.dist_scheduler
  pull_secret_namespaces = [
    for ns in kubernetes_namespace_v1.kubelet[*] : ns.metadata[0].name
  ]
  deploy_parca     = var.deploy_parca
  deploy_fluentbit = var.deploy_fluentbit
  service_cidr     = module.k8s_server[0].service_cidr
  domain           = var.domain
}
