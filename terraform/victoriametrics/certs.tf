resource "tls_private_key" "caddy_key" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_cert_request" "caddy_csr" {
  private_key_pem = tls_private_key.caddy_key.private_key_pem

  subject {
    common_name  = "*.${local.monitoring_segment}.${data.aws_route53_zone.main.name}"
    organization = "k8s-1m"
  }

  dns_names = [for name in local.dns_names : "${name}.${local.monitoring_segment}.${data.aws_route53_zone.main.name}"]
}

# Sign the certificate with our CA
resource "tls_locally_signed_cert" "caddy_cert" {
  cert_request_pem   = tls_cert_request.caddy_csr.cert_request_pem
  ca_private_key_pem = var.ca_cert.private_key_pem
  ca_cert_pem        = var.ca_cert.cert_pem

  validity_period_hours = 8760 # 1 year

  allowed_uses = [
    "key_encipherment",
    "digital_signature",
    "server_auth",
  ]
}
