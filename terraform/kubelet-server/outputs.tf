output "ips" {
  value = var.replicas > 0 ? module.k3s_kubelet[0].ipv6_addresses : []
}
