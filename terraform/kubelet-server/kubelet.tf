locals {
  tags = ["k3s", "kubelet"]
  cpu_pinning_args = var.pin_cpus ? join(" ", [
    "--kubelet-arg cpu-manager-policy=static",
    "--kubelet-arg cpu-manager-policy-options=full-pcpus-only=true",
    "--kubelet-arg reserved-cpus=0,16"
  ]) : ""
  common_args = join(" ", [
    "--token='${var.k3s_token}'",
    "--with-node-id",
    "--node-ip=$${ip6}",
    "--node-external-ip=$${ip6}",
    "--pause-image=registry.k8s.io/pause:3.10",
    # gcp doesn't provide an ipv6 internal resolver, so we override the default and need to set this specifically
    "--resolv-conf=/run/systemd/resolve/resolv.conf",
    "--kube-proxy-arg pod-interface-name-prefix=veth",
    "--kube-proxy-arg detect-local-mode=InterfaceNamePrefix",
    "--kubelet-arg max-pods=65535",
    "--node-label role=kubelet",
    join(" ", [for k, v in var.extra_labels : "--node-label ${k}=${v}"]),
    local.cpu_pinning_args,
  ])
}

resource "random_string" "unique_name" {
  length  = 4
  special = false
  upper   = false
}

module "k3s_kubelet" {
  count    = var.replicas > 0 ? 1 : 0
  source   = "../modules/vm"
  replicas = var.replicas

  unique_name            = "k3s-kubelet-${random_string.unique_name.result}"
  startup_script         = <<EOT
#!/bin/bash
${local.preamble}
export INSTALL_K3S_SKIP_DOWNLOAD=true
curl -6 -o /usr/local/bin/k3s https://r2.bchess.net/k3s-$${arch}
chmod +x /usr/local/bin/k3s
curl -6sfL --max-time 10 --retry 3 --retry-delay 0 --retry-max-time 30 https://r2.bchess.net/k3s-install.sh | INSTALL_K3S_EXEC="agent --server https://${var.apiserver_hostname}:6443 $common_args" sh -
netplan apply
systemctl start k3s-agent &
EOT
  firewall_inbound_rules = local.inbound_rules
  tags                   = local.tags
  cloud_details          = var.cloud_details
  cloud_infra            = var.cloud_infra
}

locals {
  inbound_rules = [
    "udp/53",    # dns
    "tcp/53",    # dns
    "tcp/22",    # ssh
    "tcp/1010",  # nginx reverse-proxy to metrics
    "tcp/10247", # kwok
    "tcp/10250", # kubelet
    "tcp/8080",  # metrics and misc
    "tcp/8443",  # dist-scheduler webhook
    "tcp/9153",  # test port
    "tcp/50051", # dist-scheduler
  ]
}

locals {
  preamble = <<EOT
eth_if=$(ip -j route show | jq -r '.[0].dev')
arch=$(dpkg --print-architecture)
ufw disable
apt-get update
apt-get install -y curl wireguard-tools nginx prometheus-node-exporter apache2-utils ndppd
wireguard_private_key=$(wg genkey)
wireguard_public_key=$(echo $wireguard_private_key | wg pubkey)
curl -k -X POST -u wireguard:${var.ipv4gateway.password} -d "$wireguard_public_key" https://${var.ipv4gateway.hostname}/wireguard | sed -e s.XXXXXX.$${wireguard_private_key}. > /etc/wireguard/wg0.conf
wg-quick up wg0
ip route add 0.0.0.0/0 dev wg0 via 10.0.0.1

mkdir -p /root/.ssh
curl -L ${var.ssh_key_url} -o /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys

mkdir -p /opt/cni/bin
curl -L https://r2.bchess.net/cni-plugins-linux-$${arch}-v1.5.1.tgz | tar -xz -C /opt/cni/bin
ip6_cidr=$(ip -6 addr show dev $${eth_if} | grep 'inet6 [23]' | awk '{print $2}')
ip6=$(echo $ip6_cidr | cut -d'/' -f1)
ip6=$(python3 -c "import ipaddress, sys; print(ipaddress.IPv6Address(sys.argv[1]).exploded)" $${ip6})
# vultr gives a /64. AWS gives a /80. GCP gives a /96
if [ -z "$pod_cidr" ]; then
  pod_cidr=$(echo $ip6 | cut -d':' -f1-6):ffff::/112
fi
# AWS
pod_gw=$(echo $pod_cidr | cut -d':' -f1-6):ffff:1
ip link add mybr0 type bridge
ip link set mybr0 up
ip -6 route add $pod_gw/96 dev mybr0

sysctl -w net.ipv6.conf.all.forwarding=1
sysctl -w net.ipv6.conf.all.proxy_ndp=1
sysctl -w fs.inotify.max_user_instances=2099999999
sysctl -w fs.inotify.max_user_watches=2099999999
sysctl -w fs.inotify.max_queued_events=2099999999

mkdir -p /etc/cni/net.d
cat <<EOF > /etc/cni/net.d/10-containerd-net.conflist
{
  "cniVersion": "1.0.0",
  "name": "containerd-net",
  "plugins": [
    {
      "name": "mybridge",
      "type": "bridge",
      "bridge": "mybr0",
      "hairpinMode": true,
      "isGateway": true,
      "isDefaultGateway": true,
      "ipam": {
        "type": "host-local",
        "ranges": [
          [{
            "subnet": "$pod_cidr"
          }]
        ],
        "routes": [
          { "dst": "::/0", "gw": "$pod_gw" }
        ]
      }
    },
    {
      "type": "portmap",
      "capabilities": {"portMappings": true}
    }
  ]
}
EOF
iptables -P FORWARD ACCEPT

cat <<EOF > /etc/ndppd.conf
route-ttl 30000
proxy $${eth_if} {
    rule $pod_cidr {
        auto
    }
}
EOF
systemctl restart ndppd

# Setup nginx reverse-proxy for metrics
openssl req -x509 -nodes -days 365 -newkey rsa:2048 -keyout /etc/nginx/server.key -out /etc/nginx/server.crt \
  -subj "/C=US/ST=State/L=City/O=Organization/OU=Department/CN=CommonName"
rm /etc/nginx/sites-enabled/default
cat <<EOF > /etc/nginx/sites-enabled/metrics
server {
    listen [::]:1010 ssl;
    listen 1010 ssl;

    ssl_certificate /etc/nginx/server.crt;
    ssl_certificate_key /etc/nginx/server.key;
    auth_basic "Restricted";
    auth_basic_user_file /etc/nginx/.htpasswd;
    location /k3s/metrics {
        proxy_pass http://127.0.0.1:10249/metrics;
    }
    location /node-exporter/metrics {
        proxy_pass http://127.0.0.1:9100/metrics;
    }
}
EOF
sudo htpasswd -cb /etc/nginx/.htpasswd victoriametrics '${var.victoriametrics_password}'
systemctl restart nginx

export INSTALL_K3S_SKIP_START=true
common_args="${local.common_args}"
EOT
}
