output "kubelet_ips" {
  value = flatten(module.kubelet[*].ips)
}

output "obs_auth" {
  value = nonsensitive(module.victoriametrics.auth.password)
}
