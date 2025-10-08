locals {
  tags                 = ["victoriametrics"]
  auth_username        = "u"
  auth_password_bcrypt = random_password.caddy_password.bcrypt_hash
}

module "victoriametrics_vm" {
  source = "../modules/vm"

  unique_name    = "victoriametrics"
  startup_script = <<EOT
#!/bin/bash
ufw disable
apt-get update
# llvm binutils elfutils for parca
# debian-keyring debian-archive-keyring apt-transport-https for caddy
apt-get install -y curl wireguard-tools llvm binutils elfutils debian-keyring debian-archive-keyring apt-transport-https
wireguard_private_key=$(wg genkey)
wireguard_public_key=$(echo $wireguard_private_key | wg pubkey)
curl --retry 3 -6 -k -X POST -u wireguard:${var.ipv4gateway.password} -d "$wireguard_public_key" https://${var.ipv4gateway.hostname}/wireguard | sed -e s.XXXXXX.$${wireguard_private_key}. > /etc/wireguard/wg0.conf
wg-quick up wg0
ip route add 0.0.0.0/0 dev wg0 via 10.0.0.1

mkdir -p /root/.ssh
curl -L ${var.ssh_key_url} -o /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys

###################
### VICTORIAMETRICS
###################
curl -L https://github.com/VictoriaMetrics/VictoriaMetrics/releases/download/v1.107.0/victoria-metrics-linux-amd64-v1.107.0.tar.gz | tar xz -C /usr/bin

cat <<EOF > /etc/victoriametrics-promscrape.yml
global:
  scrape_interval: 10s
  scrape_timeout: 9s

scrape_configs:
- job_name: 'k3s'
  dns_sd_configs:
  - names:
    - 'apiserver.${data.aws_route53_zone.main.name}'
    - 'kubelets-0.${data.aws_route53_zone.main.name}'
    - 'kubelets-1.${data.aws_route53_zone.main.name}'
    - 'kubelets-2.${data.aws_route53_zone.main.name}'
    - 'kubelets-3.${data.aws_route53_zone.main.name}'
    - 'kubelets-4.${data.aws_route53_zone.main.name}'
    - 'kubelets-5.${data.aws_route53_zone.main.name}'
    - 'kubelets-6.${data.aws_route53_zone.main.name}'
    - 'kubelets-7.${data.aws_route53_zone.main.name}'
    - 'kubelets-8.${data.aws_route53_zone.main.name}'
    - 'kubelets-9.${data.aws_route53_zone.main.name}'
    - 'kubelets-10.${data.aws_route53_zone.main.name}'
    - 'kubelets-11.${data.aws_route53_zone.main.name}'
    - 'kubelets-12.${data.aws_route53_zone.main.name}'
    - 'kubelets-13.${data.aws_route53_zone.main.name}'
    - 'kubelets-14.${data.aws_route53_zone.main.name}'
    - 'kubelets-15.${data.aws_route53_zone.main.name}'
    - 'kubelets-16.${data.aws_route53_zone.main.name}'
    - 'kubelets-17.${data.aws_route53_zone.main.name}'
    - 'kubelets-18.${data.aws_route53_zone.main.name}'
    - 'kubelets-19.${data.aws_route53_zone.main.name}'
    - 'kubelets-20.${data.aws_route53_zone.main.name}'
    - 'kubelets-21.${data.aws_route53_zone.main.name}'
    - 'kubelets-22.${data.aws_route53_zone.main.name}'
    - 'kubelets-23.${data.aws_route53_zone.main.name}'
    - 'kubelets-24.${data.aws_route53_zone.main.name}'
    - 'kubelets-25.${data.aws_route53_zone.main.name}'
    - 'kubelets-26.${data.aws_route53_zone.main.name}'
    - 'kubelets-27.${data.aws_route53_zone.main.name}'
    - 'kubelets-28.${data.aws_route53_zone.main.name}'
    - 'kubelets-29.${data.aws_route53_zone.main.name}'
    type: 'AAAA'
    port: 1010
  scheme: https
  basic_auth:
    username: 'victoriametrics'
    password: '${random_string.password.result}'
  tls_config:
    insecure_skip_verify: true
  metrics_path: /k3s/metrics
  relabel_configs:
  - source_labels: [__meta_dns_name]
    regex: ^([^\.-]+)(-?.*)$
    target_label: host
    replacement: $1
- job_name: 'etcd'
  dns_sd_configs:
  - names:
    - 'etcd.${data.aws_route53_zone.main.name}'
    type: 'AAAA'
    port: 1010
  scheme: https
  basic_auth:
    username: 'victoriametrics'
    password: '${random_string.password.result}'
  tls_config:
    insecure_skip_verify: true
  metrics_path: /etcd/metrics
- job_name: 'node-exporter'
  dns_sd_configs:
  - names:
    - 'apiserver.${data.aws_route53_zone.main.name}'
    - 'etcd.${data.aws_route53_zone.main.name}'
    - 'kube-scheduler.${data.aws_route53_zone.main.name}'
    - 'kubelets-0.${data.aws_route53_zone.main.name}'
    - 'kubelets-1.${data.aws_route53_zone.main.name}'
    - 'kubelets-2.${data.aws_route53_zone.main.name}'
    - 'kubelets-3.${data.aws_route53_zone.main.name}'
    - 'kubelets-4.${data.aws_route53_zone.main.name}'
    - 'kubelets-5.${data.aws_route53_zone.main.name}'
    - 'kubelets-6.${data.aws_route53_zone.main.name}'
    - 'kubelets-7.${data.aws_route53_zone.main.name}'
    - 'kubelets-8.${data.aws_route53_zone.main.name}'
    - 'kubelets-9.${data.aws_route53_zone.main.name}'
    - 'kubelets-10.${data.aws_route53_zone.main.name}'
    - 'kubelets-11.${data.aws_route53_zone.main.name}'
    - 'kubelets-12.${data.aws_route53_zone.main.name}'
    - 'kubelets-13.${data.aws_route53_zone.main.name}'
    - 'kubelets-14.${data.aws_route53_zone.main.name}'
    - 'kubelets-15.${data.aws_route53_zone.main.name}'
    - 'kubelets-16.${data.aws_route53_zone.main.name}'
    - 'kubelets-17.${data.aws_route53_zone.main.name}'
    - 'kubelets-18.${data.aws_route53_zone.main.name}'
    - 'kubelets-19.${data.aws_route53_zone.main.name}'
    - 'kubelets-20.${data.aws_route53_zone.main.name}'
    - 'kubelets-21.${data.aws_route53_zone.main.name}'
    - 'kubelets-22.${data.aws_route53_zone.main.name}'
    - 'kubelets-23.${data.aws_route53_zone.main.name}'
    - 'kubelets-24.${data.aws_route53_zone.main.name}'
    - 'kubelets-25.${data.aws_route53_zone.main.name}'
    - 'kubelets-26.${data.aws_route53_zone.main.name}'
    - 'kubelets-27.${data.aws_route53_zone.main.name}'
    - 'kubelets-28.${data.aws_route53_zone.main.name}'
    - 'kubelets-29.${data.aws_route53_zone.main.name}'
    type: 'AAAA'
    port: 1010
  scheme: https
  basic_auth:
    username: 'victoriametrics'
    password: '${random_string.password.result}'
  tls_config:
    insecure_skip_verify: true
  metrics_path: /node-exporter/metrics
  relabel_configs:
  - source_labels: [__meta_dns_name]
    regex: ^([^\.-]+)(-?.*)$
    target_label: host
    replacement: $1
- job_name: 'victorialogs'
  static_configs:
  - targets:
    - localhost:9428
  scheme: http
  metrics_path: /metrics
EOF

cat <<EOF > /etc/systemd/system/victoriametrics.service
[Unit]
Description=VictoriaMetrics Service
After=network.target

[Service]
ExecStart=/usr/bin/victoria-metrics-prod -promscrape.config /etc/victoriametrics-promscrape.yml -enableTCP6
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

################
### VICTORIALOGS
################
curl -L https://github.com/VictoriaMetrics/VictoriaMetrics/releases/download/v1.19.0-victorialogs/victoria-logs-linux-amd64-v1.19.0-victorialogs.tar.gz | tar xz -C /usr/bin
mkdir -p /victorialogs

cat <<EOF > /etc/systemd/system/victorialogs.service
[Unit]
Description=VictoriaLogs Service
After=network.target

[Service]
ExecStart=/usr/bin/victoria-logs-prod -storageDataPath /victorialogs -enableTCP6
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

#########
### PARCA
#########
curl -sL https://github.com/parca-dev/parca/releases/download/v0.23.1/parca_0.23.1_`uname -s`_`uname -m`.tar.gz | tar xvz -C /usr/bin

adduser --system --no-create-home --group parca
mkdir /parca
cat << EOF > /etc/parca.yaml
object_storage:
  bucket:
    type: "FILESYSTEM"
    config:
      directory: "/parca"
EOF
chown parca:parca /parca

cat << EOF > /etc/systemd/system/parca.service
[Unit]
Description=Parca Service
After=network.target

[Service]
User=parca
Group=parca
Restart=on-failure
RestartSec=10
ExecStart=/usr/bin/parca --config-path=/etc/parca.yaml --http-address=:7070 --cors-allowed-origins=* --enable-persistence
ExecReload=/bin/kill -HUP $MAINPID
WorkingDirectory=/parca
LimitNOFILE=65535
NoNewPrivileges=true
ProtectHome=true
ProtectSystem=full
ProtectHostname=true
ProtectControlGroups=true
ProtectKernelModules=true
ProtectKernelTunables=true
LockPersonality=true
RestrictRealtime=yes
RestrictNamespaces=yes
MemoryDenyWriteExecute=yes
PrivateDevices=yes
SyslogIdentifier=parca

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
for service in victoriametrics victorialogs parca caddy; do
  systemctl enable $service
  systemctl start $service
done

########
### CADDY
########
# Install Caddy
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list
apt-get update
apt-get install -y caddy

# Setup TLS certificates for Caddy
mkdir -p /etc/caddy/certs
cat <<'EOF' > /etc/caddy/certs/caddy.crt
${tls_locally_signed_cert.caddy_cert.cert_pem}
EOF

cat <<'EOF' > /etc/caddy/certs/caddy.key
${tls_private_key.caddy_key.private_key_pem}
EOF

chmod 600 /etc/caddy/certs/caddy.key
chown caddy:caddy /etc/caddy/certs/caddy.key

# Configure Caddy
cat << 'EOF' > /etc/caddy/Caddyfile
{
auto_https disable_certs
}
metrics.${local.monitoring_segment}.${data.aws_route53_zone.main.name}:443 {
    tls /etc/caddy/certs/caddy.crt /etc/caddy/certs/caddy.key
    basic_auth {
        ${local.auth_username} ${local.auth_password_bcrypt}
    }
    reverse_proxy localhost:8428
}
logs.${local.monitoring_segment}.${data.aws_route53_zone.main.name}:443 {
    tls /etc/caddy/certs/caddy.crt /etc/caddy/certs/caddy.key
    basic_auth {
        ${local.auth_username} ${local.auth_password_bcrypt}
    }
    reverse_proxy localhost:9428
}
parca.${local.monitoring_segment}.${data.aws_route53_zone.main.name}:443 {
    tls /etc/caddy/certs/caddy.crt /etc/caddy/certs/caddy.key
    @bearerAuth header Authorization "Bearer k8s1minsecuretoken"
    @basicAuth header Authorization Basic*
    basic_auth @basicAuth {
        u $2a$10$hpefBRzLQwn7b.CWts9BDu22dbXvsgRZmBxz1kwaCF1VZdnHEGnua
    }
    route {
	    reverse_proxy @bearerAuth h2c://localhost:7070
	    reverse_proxy @basicAuth localhost:7070
	    header +www-authenticate "Basic realm=\"restricted\""
	    respond "Unauthorized" 401
    }
}
EOF

systemctl restart caddy.service
EOT

  firewall_inbound_rules = local.inbound_rules
  tags                   = local.tags

  cloud_details = var.cloud_details
  cloud_infra   = var.cloud_infra
}

locals {
  inbound_rules = [
    "tcp/22",   # ssh
    "tcp/80",   # http (caddy)
    "tcp/443",  # https (caddy)
    "tcp/7070", # parca
    "tcp/8428", # vm
    "tcp/9428", # victorialogs
  ]
}

resource "random_string" "password" {
  length  = 16
  special = false
}

resource "random_password" "caddy_password" {
  length  = 16
  special = false
}
