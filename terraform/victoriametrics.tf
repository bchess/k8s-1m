module "victoriametrics" {
  source = "./victoriametrics"

  ssh_key_url = local.ssh_key_url
  ipv4gateway = {
    hostname = module.ipv4_gateway.hostname
    password = module.ipv4_gateway.password
  }
  zone_id = module.dns.zone_id

  ca_cert = {
    cert_pem        = tls_self_signed_cert.ca_cert.cert_pem
    private_key_pem = tls_private_key.ca_key.private_key_pem
  }

  cloud_details = var.victoriametrics_cloud_details
  cloud_infra   = local.cloud_infra
}
