output "server_ipv6_address" {
  value = concat([module.k3s_server_first.ipv6_addresses[0]], module.k3s_servers[*].ipv6_addresses[*])
}

output "server_hostname" {
  value = "${aws_route53_record.apiservers.name}.${data.aws_route53_zone.main.name}"
}

output "k3s_token" {
  value     = random_string.k3s_token.result
  sensitive = true
}

locals {
  k3s_kubelet_config = yamldecode(data.remote_file.k3s_kubelet_config.content)

  host = "https://${aws_route53_record.apiservers.name}.${data.aws_route53_zone.main.name}:6443"
  # host = (local.lb_count > 1 ?
  #   "https://${aws_route53_record.apiserverlb[0].name}.${data.aws_route53_zone.main.name}:6443" :
  # "https://${aws_route53_record.apiservers.name}.${data.aws_route53_zone.main.name}:6443")
}

output "kube_config" {
  sensitive = true
  value = {
    content                = replace(data.remote_file.k3s_kubelet_config.content, "https://[::1]:6443", "${local.host}\n    tls-server-name: kubernetes")
    host                   = local.host
    client_certificate     = base64decode(local.k3s_kubelet_config.users[0].user.client-certificate-data)
    client_key             = base64decode(local.k3s_kubelet_config.users[0].user.client-key-data)
    cluster_ca_certificate = base64decode(local.k3s_kubelet_config.clusters[0].cluster.certificate-authority-data)
  }
  # value = {
  #   content                = ""
  #   host                   = ""
  #   client_certificate     = ""
  #   client_key             = ""
  #   cluster_ca_certificate = ""
  # }
}

output "service_cidr" {
  value = local.service_cidr
}
