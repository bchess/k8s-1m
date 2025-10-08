locals {
  plan = "vc2-1c-1gb" # 1 vCPU, 1GB RAM
  tags = ["k3s", "ipv4-gateway"]
  fqdn = "${var.hostname}.${data.aws_route53_zone.main.name}"
}

data "vultr_os" "ubuntu" {
  filter {
    name   = "name"
    values = ["Ubuntu 24.04 LTS x64"]
  }
}

resource "vultr_instance" "gateway" {
  os_id       = data.vultr_os.ubuntu.id
  plan        = local.plan
  region      = var.region
  ssh_key_ids = [vultr_ssh_key.me.id]
  hostname    = "gateway"
  label       = "ipv4-gateway"
  script_id   = vultr_startup_script.gateway_install.id

  enable_ipv6         = true
  disable_public_ipv4 = false

  firewall_group_id = vultr_firewall_group.gateway.id

  tags = local.tags

  lifecycle {
    replace_triggered_by = [
      vultr_startup_script.gateway_install.script
    ]
  }
}

resource "vultr_firewall_group" "gateway" {
  description = "Ipv4 gateway firewall"
}

resource "vultr_firewall_rule" "wg_inbound" {
  firewall_group_id = vultr_firewall_group.gateway.id
  protocol          = "udp"
  port              = "51820"
  subnet            = "::"
  ip_type           = "v6"
  subnet_size       = 0
}

resource "vultr_firewall_rule" "https_inbound" {
  firewall_group_id = vultr_firewall_group.gateway.id
  protocol          = "tcp"
  port              = "443" # https
  subnet            = "::"
  ip_type           = "v6"
  subnet_size       = 0
}

resource "vultr_firewall_rule" "ssh_6_inbound" {
  firewall_group_id = vultr_firewall_group.gateway.id
  protocol          = "tcp"
  port              = "22" # ssh
  subnet            = "::"
  ip_type           = "v6"
  subnet_size       = 0
}

resource "vultr_firewall_rule" "ssh_4_inbound" {
  firewall_group_id = vultr_firewall_group.gateway.id
  protocol          = "tcp"
  port              = "22" # ssh
  subnet            = "0.0.0.0"
  ip_type           = "v4"
  subnet_size       = 0
}

resource "vultr_startup_script" "gateway_install" {
  name = "gateway-install"
  script = base64encode(<<EOT
#!/bin/bash
apt-get update
apt-get install -y wireguard-tools python3 python3-aiohttp
ufw disable
echo 1 > /proc/sys/net/ipv4/ip_forward
default_iface=$(ip route show default | awk '{print $5}')
iptables -t nat -A POSTROUTING -o "$default_iface" -j MASQUERADE
cat <<EOF > /wireguard_manager.py
${file("${path.module}/wireguard-manager/wireguard_manager.py")}
EOF
cat <<EOF > /server.key
${tls_private_key.gateway.private_key_pem}
EOF
cat <<EOF > /server.crt
${tls_self_signed_cert.gateway.cert_pem}
EOF

WIREGUARD_ENDPOINT="${local.fqdn}" WIREGUARD_USERNAME=wireguard WIREGUARD_PASSWORD="${random_string.wireguard_password.result}" python3 /wireguard_manager.py
EOT
  )
}

resource "random_string" "wireguard_password" {
  length  = 16
  special = false
}

resource "tls_private_key" "gateway" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "tls_self_signed_cert" "gateway" {
  private_key_pem = tls_private_key.gateway.private_key_pem

  subject {
    common_name  = "example.com"
    organization = "ACME Examples, Inc"
  }

  validity_period_hours = 24 * 365

  allowed_uses = [
    "key_encipherment",
    "digital_signature",
    "server_auth",
  ]
}

data "http" "ssh_keys" {
  url = var.ssh_key_url
}

resource "vultr_ssh_key" "me" {
  name    = "ipv4-gateway-ssh-key"
  ssh_key = data.http.ssh_keys.response_body

  lifecycle {
    ignore_changes = [ssh_key]
  }
}
