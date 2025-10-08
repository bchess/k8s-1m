data "remote_file" "kube_scheduler_files" {
  for_each = var.kube_scheduler_cloud_details == null ? {} : {
    "cert"      = "/var/lib/rancher/k3s/server/tls/client-scheduler.crt"
    "key"       = "/var/lib/rancher/k3s/server/tls/client-scheduler.key"
    "server-ca" = "/var/lib/rancher/k3s/server/tls/server-ca.crt"
  }
  conn {
    host        = "[${module.k3s_server_first.ipv6_addresses[0]}]"
    user        = "root"
    private_key = tls_private_key.k3s_server_first.private_key_openssh
    timeout     = 300
  }
  path = each.value
  depends_on = [
    null_resource.wait_for_apiserver
  ]
}

module "kube_scheduler_vm" {
  count  = var.kube_scheduler_cloud_details != null ? 1 : 0
  source = "../modules/vm"

  unique_name            = "kube-scheduler"
  firewall_inbound_rules = local.inbound_rules
  startup_script         = <<EOT
#!/bin/bash
${local.preamble}
curl -L -o /usr/local/bin/kube-scheduler https://dl.k8s.io/v1.32.3/bin/linux/$${arch}/kube-scheduler
chmod +x /usr/local/bin/kube-scheduler
cat <<EOF > /etc/kube-scheduler.kubeconfig
apiVersion: v1
clusters:
- cluster:
    certificate-authority-data: ${base64encode(data.remote_file.kube_scheduler_files["server-ca"].content)}
    server: https://127.0.0.1:7443
  name: default
contexts:
- context:
    cluster: default
    user: default
  name: default
current-context: default
kind: Config
preferences: {}
users:
- name: default
  user:
    client-certificate-data: ${base64encode(data.remote_file.kube_scheduler_files["cert"].content)}
    client-key-data: ${base64encode(data.remote_file.kube_scheduler_files["key"].content)}
EOF
cat <<EOF > /etc/systemd/system/kube-scheduler.service
[Unit]
Description=Kubernetes Scheduler
Documentation=https://github.com/kubernetes/kubernetes

[Service]
ExecStart=/usr/local/bin/kube-scheduler \
  --authentication-kubeconfig=/etc/kube-scheduler.kubeconfig \
  --authorization-kubeconfig=/etc/kube-scheduler.kubeconfig \
  --bind-address=:: \
  --kube-api-burst=40000 \
  --kube-api-qps=20000 \
  --kubeconfig=/etc/kube-scheduler.kubeconfig \
  --profiling=false \
  --secure-port=10259
OOMPolicy=restart
Restart=always
RestartSec=5
MemoryMax=50G
KillMode=process
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable kube-scheduler
systemctl start kube-scheduler
EOT
  cloud_details          = var.kube_scheduler_cloud_details
  cloud_infra            = var.cloud_infra
}
