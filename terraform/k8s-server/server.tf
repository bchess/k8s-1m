locals {
  tags         = ["k3s", "server"]
  service_cidr = "fd00:0:0:1226::/108"
  cluster_cidr = "2001:0:1:2::/64"
  common_args = join(" ", [
    "--token='${random_string.k3s_token.result}'",
    "--flannel-backend none",
    "--node-ip=$${ip6}",
    "--node-external-ip=$${ip6}",
    "--service-cidr=${local.service_cidr}",
    "--cluster-cidr=2001:0:1:2::/64",
    "--resolv-conf=/var/run/systemd/resolve/resolv.conf",
    "--pause-image=registry.k8s.io/pause:3.10",
    "--kubelet-arg max-pods=65535",
    "--kube-proxy-arg pod-interface-name-prefix=veth",
    "--kube-proxy-arg detect-local-mode=InterfaceNamePrefix",
    "--disable=metrics-server,servicelb,traefik,coredns",
    "--disable-cloud-controller",
    "--disable-controller-manager",
    "--disable-scheduler",
    # gcp doesn't provide an ipv6 internal resolver, so we override the default and need to set this specifically
    "--resolv-conf=/run/systemd/resolve/resolv.conf",
    "--enable-pprof",
    "--kubelet-arg cpu-manager-policy=static",
    "--kubelet-arg cpu-manager-policy-options=full-pcpus-only=true",
    "--kubelet-arg reserved-cpus=0,16",
    "--apiserver-bind-address=0.0.0.0",
    "--kube-apiserver-arg etcd-compaction-interval=20m",
    "--kube-apiserver-arg max-requests-inflight=5000",
    "--kube-apiserver-arg max-mutating-requests-inflight=1000",
    # "--kube-apiserver-arg audit-policy-file=/etc/k3s-audit-policy.yaml",
    # "--kube-apiserver-arg audit-log-path=/var/log/k3s-audit.log",
    # "--kube-apiserver-arg audit-log-maxsize=600",
    # "--kube-apiserver-arg audit-log-maxbackup=3",
    "--kube-apiserver-arg enable-priority-and-fairness=false",
    # "--kube-apiserver-arg contention-profiling=true", #if enabled, also set BLOCK_PROFILE_RATE=1 and MUTEX_PROFILE_FRACTION=1
    "--kube-apiserver-arg profiling=true",
    # "--kube-apiserver-arg feature-gates=kube:ConcurrentWatchObjectDecode=true",
    "--kube-apiserver-arg feature-gates=kube:BtreeWatchCache=false",
    "--disable-network-policy", # to alleviate iptables strain on pod-based kubelets
    # "--vmodule=reflector*=4,*cache*=4,*watch*=4,store=4",
  ])
  extra_k3s_args = var.separate_etcd ? "--datastore-endpoint=http://[${local.etcd_v6_addr}]:2379" : ""
}

module "k3s_server_first" {
  source = "../modules/vm"

  unique_name            = "k3s-server-0"
  firewall_inbound_rules = local.inbound_rules
  startup_script         = <<EOT
#!/bin/bash
mkdir -p /root/.ssh
echo '${tls_private_key.k3s_server_first.public_key_openssh}' >> /root/.ssh/authorized_keys
${local.kube_server_boot}
# First server, initialize the etcd cluster
curl -6sfL https://r2.bchess.net/k3s-install.sh | INSTALL_K3S_EXEC="server --cluster-init $common_args ${local.extra_k3s_args}" sh -
systemctl start k3s &
systemctl start kube-controller-manager &
%{if var.kube_scheduler_cloud_details == null}
systemctl start kube-scheduler &
%{endif}
EOT

  cloud_details = var.cloud_details
  cloud_infra   = var.cloud_infra
}

resource "tls_private_key" "k3s_server_first" {
  algorithm = "RSA"
}

module "k3s_servers" {
  source = "../modules/vm"
  count  = var.replicas > 1 ? 1 : 0

  replicas               = max(0, var.replicas - 1)
  offset                 = 1
  unique_name            = "k3s-server-"
  firewall_inbound_rules = local.inbound_rules
  startup_script         = <<EOT
#!/bin/bash
${local.kube_server_boot}
MASTER_HOSTNAME="${aws_route53_record.apiserver_each_first.fqdn}"  # Included to ensure we wait for DNS before joining
MASTER_IP="${module.k3s_server_first.ipv6_addresses[0]}"
curl -6sfL https://r2.bchess.net/k3s-install.sh | INSTALL_K3S_EXEC="server --server https://$MASTER_IP:6443 $common_args ${local.extra_k3s_args}" sh -
systemctl start k3s &
systemctl start kube-controller-manager &
%{if var.kube_scheduler_cloud_details == null}
systemctl start kube-scheduler &
%{endif}
EOT
  cloud_details          = var.cloud_details
  cloud_infra            = var.cloud_infra
}

locals {
  inbound_rules = [
    "tcp/22",    # ssh
    "udp/53",    # dns
    "tcp/1010",  # nginx reverse-proxy to metrics
    "tcp/2379",  # etcd port
    "tcp/2380",  # etcd port
    "tcp/6443",  # K3s API server port
    "tcp/6444",  # K3s API server port
    "tcp/7443",  # haproxy round-robin LB to API servers
    "tcp/8080",  # metrics and misc
    "tcp/8443",  # dist-scheduler webhook
    "tcp/9153",  # test port
    "tcp/10247", # kwok
    "tcp/10250", # kubelet
    "tcp/10257", # kube-controller-manager
    "tcp/10259", # kube-scheduler
    "tcp/50051", # dist-scheduler
  ]
}


locals {
  # Preamble is used for both apiservers and etcd
  preamble         = <<EOT
eth_if=$(ip -j -6 route show | jq -r '.[0].dev')
arch=$(dpkg --print-architecture)
cloud_id=$(cloud-id)
ufw disable
swapoff -a
apt-get update
apt-get install -y curl wireguard-tools nginx prometheus-node-exporter apache2-utils ndppd haproxy
wireguard_private_key=$(wg genkey)
wireguard_public_key=$(echo $wireguard_private_key | wg pubkey)
curl -k -X POST -u wireguard:${var.ipv4gateway.password} -d "$wireguard_public_key" https://${var.ipv4gateway.hostname}/wireguard | sed -e s.XXXXXX.$${wireguard_private_key}. > /etc/wireguard/wg0.conf
wg-quick up wg0
ip route add 0.0.0.0/0 dev wg0 via 10.0.0.1

mkdir -p /root/.ssh
curl -L ${var.ssh_key_url} >> /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys

mkdir -p /opt/cni/bin
curl -L https://r2.bchess.net/cni-plugins-linux-$${arch}-v1.5.1.tgz | tar -xz -C /opt/cni/bin

ip6_cidr=$(ip -6 addr show dev $${eth_if} | grep 'inet6 [23]' | awk '{print $2}')
ip6=$(echo $ip6_cidr | cut -d'/' -f1)
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
    location /etcd/metrics {
        proxy_pass http://127.0.0.1:9000/metrics;
    }
    location /node-exporter/metrics {
        proxy_pass http://127.0.0.1:9100/metrics;
    }
}
EOF
sudo htpasswd -cb /etc/nginx/.htpasswd victoriametrics '${var.victoriametrics_password}'
systemctl restart nginx
cat <<EOF > /etc/haproxy/haproxy.cfg
resolvers dns
  nameserver dns1 2606:4700:4700::1111:53
  hold valid 10s
  accepted_payload_size 8192

defaults
  mode tcp
  timeout connect 5s
  timeout client  30s
  timeout server  30s

frontend ft_ipv6_lb
  bind :::7443
  default_backend bk_ipv6_targets

backend bk_ipv6_targets
  mode tcp
  balance roundrobin
  server-template srv 5 _apiserver._tcp.${data.aws_route53_zone.main.name} resolvers dns resolve-prefer ipv6 check
EOF
systemctl restart haproxy
EOT
  kube_server_boot = <<EOT
${local.preamble}
cat <<EOF > /etc/k3s-audit-policy.yaml
apiVersion: audit.k8s.io/v1
kind: Policy
rules:
  - level: Request
    verbs: ["list", "watch"]
    resources:
      - group: "k8s-1m.dev"
        resources: ["fluffs"]
EOF
curl -L -o /usr/local/bin/kube-scheduler https://dl.k8s.io/v1.32.3/bin/linux/$${arch}/kube-scheduler
curl -L -o /usr/local/bin/kube-controller-manager https://dl.k8s.io/v1.32.3/bin/linux/$${arch}/kube-controller-manager
chmod +x /usr/local/bin/kube-scheduler /usr/local/bin/kube-controller-manager
cat <<EOF > /etc/systemd/system/kube-controller-manager.service
[Unit]
Description=Kubernetes Controller Manager
Documentation=https://github.com/kubernetes/kubernetes

[Service]
ExecStart=/usr/local/bin/kube-controller-manager \
--allocate-node-cidrs=false \
--authentication-kubeconfig=/var/lib/rancher/k3s/server/cred/controller.kubeconfig \
--authorization-kubeconfig=/var/lib/rancher/k3s/server/cred/controller.kubeconfig \
--bind-address=:: \
--cluster-cidr=2001:0:1:2::/64 \
--cluster-signing-kube-apiserver-client-cert-file=/var/lib/rancher/k3s/server/tls/client-ca.nochain.crt \
--cluster-signing-kube-apiserver-client-key-file=/var/lib/rancher/k3s/server/tls/client-ca.key \
--cluster-signing-kubelet-client-cert-file=/var/lib/rancher/k3s/server/tls/client-ca.nochain.crt \
--cluster-signing-kubelet-client-key-file=/var/lib/rancher/k3s/server/tls/client-ca.key \
--cluster-signing-kubelet-serving-cert-file=/var/lib/rancher/k3s/server/tls/server-ca.nochain.crt \
--cluster-signing-kubelet-serving-key-file=/var/lib/rancher/k3s/server/tls/server-ca.key \
--cluster-signing-legacy-unknown-cert-file=/var/lib/rancher/k3s/server/tls/server-ca.nochain.crt \
--cluster-signing-legacy-unknown-key-file=/var/lib/rancher/k3s/server/tls/server-ca.key \
--controllers=*,tokencleaner --kube-api-burst=40000 --kube-api-qps=20000 \
--kubeconfig=/var/lib/rancher/k3s/server/cred/controller.kubeconfig \
--profiling=false --root-ca-file=/var/lib/rancher/k3s/server/tls/server-ca.crt \
--secure-port=10257 \
--service-account-private-key-file=/var/lib/rancher/k3s/server/tls/service.current.key \
--service-cluster-ip-range=fd00:0:0:1226::/108 \
--use-service-account-credentials=true

Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable kube-controller-manager

mkdir -p /etc/systemd/system/k3s.service.d/
cat <<EOF > /etc/systemd/system/k3s.service.d/gomemlimit.conf
[Service]
Environment="GOMEMLIMIT=230GiB"
Environment="GOGC=400"
# Environment="BLOCK_PROFILE_RATE=1"
# Environment="MUTEX_PROFILE_FRACTION=1"
EOF

%{if var.kube_scheduler_cloud_details == null}
cat <<EOF > /etc/systemd/system/kube-scheduler.service
[Unit]
Description=Kubernetes Scheduler
Documentation=https://github.com/kubernetes/kubernetes

[Service]
ExecStart=/usr/local/bin/kube-scheduler \
  --authentication-kubeconfig=/var/lib/rancher/k3s/server/cred/scheduler.kubeconfig \
  --authorization-kubeconfig=/var/lib/rancher/k3s/server/cred/scheduler.kubeconfig \
  --bind-address=:: \
  --kube-api-burst=40000 \
  --kube-api-qps=20000 \
  --kubeconfig=/var/lib/rancher/k3s/server/cred/scheduler.kubeconfig \
  --profiling=false \
  --feature-gates=kube:SchedulerQueueingHints=false \
  --secure-port=10259
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable kube-scheduler
%{endif}
export INSTALL_K3S_SKIP_START=true
common_args="${local.common_args}"
export INSTALL_K3S_SKIP_DOWNLOAD=true
curl -6 -o /usr/local/bin/k3s https://r2.bchess.net/k3s-$${arch}+buffer
chmod +x /usr/local/bin/k3s
EOT
}

resource "random_string" "k3s_token" {
  length  = 64
  special = false
}
