module "etcd" {
  count  = var.separate_etcd ? 1 : 0
  source = "../modules/vm"

  unique_name            = "etcd"
  firewall_inbound_rules = local.inbound_rules
  startup_script         = <<EOT
#!/bin/bash
${local.preamble}

DOWNLOAD_URL=https://r2.bchess.net/mem_etcd

mkdir -p /usr/local/bin
curl -6 -L $${DOWNLOAD_URL} -o /usr/local/bin/mem_etcd
chmod +x /usr/local/bin/mem_etcd
cat <<EOF > /etc/systemd/system/mem-etcd.service
[Unit]
Description=mem_etcd

[Service]
ExecStart=/usr/local/bin/mem_etcd
Restart=never
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl start mem-etcd
EOT
  cloud_details          = var.etcd_cloud_details
  cloud_infra            = var.cloud_infra
}

locals {
  etcd_v6_addr = module.etcd[0].ipv6_addresses[0]
}

# resource "vultr_startup_script" "etcd" {
#   name  = "etcd"
#   script = base64encode(<<EOT
# #!/bin/bash
# ${local.preamble}
# ETCD_VER=v3.5.17
# 
# DOWNLOAD_URL=https://storage.googleapis.com/etcd
# 
# curl -L $${DOWNLOAD_URL}/$${ETCD_VER}/etcd-$${ETCD_VER}-linux-amd64.tar.gz -o /tmp/etcd-$${ETCD_VER}-linux-amd64.tar.gz
# mkdir -p /usr/share/etcd
# tar xzvf /tmp/etcd-$${ETCD_VER}-linux-amd64.tar.gz -C /usr/share/etcd --strip-components=1
# /usr/share/etcd/etcd --listen-client-urls=http://0.0.0.0:2379 --advertise-client-urls=http://etcd.${data.aws_route53_zone.main.name}:2379 --listen-metrics-urls=http://0.0.0.0:9000 --quota-backend-bytes=8589934592
# EOT
#   )
# }
