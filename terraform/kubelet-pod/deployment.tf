locals {
  common_args = join(" ", [
    "--token='${var.k3s_token}'",
    "--with-node-id",
    "--node-ip=$${ip6}",
    "--node-external-ip=$${ip6}",
    "--pause-image=registry.k8s.io/pause:3.10",
    "--kube-proxy-arg pod-interface-name-prefix=veth",
    "--kube-proxy-arg detect-local-mode=InterfaceNamePrefix",
    "--kubelet-arg max-pods=65535",
    "--node-label role=kubelet",
    "--node-label flavor=pod",
    "--kubelet-arg cgroup-root=$${POD_NAME}",
    "--kubelet-arg healthz-bind-address=::",
    "--kube-proxy-arg proxy-mode=nftables",
  ])
}

resource "kubernetes_deployment_v1" "kubelet" {
  metadata {
    name      = "kubelet"
    namespace = var.namespace
  }
  spec {
    replicas = var.replicas
    selector {
      match_labels = {
        app = "kubelet"
      }
    }
    strategy {
      type = "RollingUpdate"
      rolling_update {
        max_unavailable = "100%"
        max_surge       = "0%"
      }
    }
    template {
      metadata {
        name = "kubelet"
        labels = {
          app = "kubelet"
        }
        annotations = {
          "config-sha" = sha256(jsonencode(kubernetes_config_map_v1.start.data))
        }
      }
      spec {
        node_selector = var.node_selector
        affinity {
          node_affinity {
            required_during_scheduling_ignored_during_execution {
              node_selector_term {
                match_expressions {
                  key      = "flavor"
                  operator = "NotIn"
                  values   = ["pod"]
                }
              }
            }
          }
        }
        image_pull_secrets {
          name = var.pull_secret_name
        }
        scheduler_name = "dist-scheduler"
        container {
          image   = "docker.io/bchess/k3s:v1.32.4-k3s1-custom"
          name    = "kubelet"
          command = ["/start.sh"]
          security_context {
            privileged = true
          }
          env {
            name  = "TOKEN"
            value = var.k3s_token
          }
          env {
            name  = "APISERVER_HOSTNAME"
            value = var.apiserver_hostname
          }
          env {
            name = "POD_NAME"
            value_from {
              field_ref {
                field_path = "metadata.name"
              }
            }
          }
          resources {
            requests = {
              memory = "266Mi"
            }
          }
          volume_mount {
            name       = "start"
            mount_path = "/start.sh"
            sub_path   = "start"
          }
          volume_mount {
            name       = "cni-bin"
            mount_path = "/opt/cni/bin"
          }
          port {
            container_port = 10250
            name           = "metrics-https"
          }
          liveness_probe {
            http_get {
              path = "/healthz"
              port = 10248
            }
            period_seconds    = 10
            failure_threshold = 2
          }
          startup_probe {
            http_get {
              path = "/healthz"
              port = 10248
            }
            failure_threshold = 12
            period_seconds    = 10
          }
        }
        volume {
          name = "cni-bin"
          host_path {
            path = "/opt/cni/bin"
          }
        }
        volume {
          name = "start"
          config_map {
            name         = kubernetes_config_map_v1.start.metadata[0].name
            default_mode = "0755"
          }
        }
      }
    }
  }
  wait_for_rollout = false
}

resource "kubernetes_config_map_v1" "start" {
  metadata {
    name      = "kubelet-start"
    namespace = var.namespace
  }
  data = {
    # ufw disable
    # apt-get update
    # apt-get install -y curl wireguard-tools
    # wireguard_private_key=$(wg genkey)
    # wireguard_public_key=$(echo $wireguard_private_key | wg pubkey)
    # curl -k -X POST -u wireguard:${var.ipv4gateway.password} -d "$wireguard_public_key" https://${var.ipv4gateway.hostname}/wireguard | sed -e s.XXXXXX.$${wireguard_private_key}. > /etc/wireguard/wg0.conf
    # wg-quick up wg0
    # ip route add 0.0.0.0/0 dev wg0 via 10.0.0.1
    start = <<-EOT
      #!/bin/sh

      # mkdir -p /opt/cni/bin
      # curl -L https://github.com/containernetworking/plugins/releases/download/v1.5.1/cni-plugins-linux-amd64-v1.5.1.tgz | tar -xz -C /opt/cni/bin
      ip6_cidr=$(ip -6 addr show dev eth0 | grep 'inet6 [23]' | awk '{print $2}')
      ip6=$(echo $ip6_cidr | cut -d'/' -f1)
      # AWS
      # mask_size=96
      # pod_gw=$(echo $ip6 | cut -d':' -f1-4):1:1::1
      # pod_cidr=$(echo $ip6 | cut -d':' -f1-4):1:1::/$mask_size
      # GCP
      mask_size=112
      pod_num=$(echo $ip6 | cut -d':' -f8)
      pod_gw=$(echo $ip6 | cut -d':' -f1-6):$pod_num:1
      pod_cidr=$(echo $ip6 | cut -d':' -f1-6):$pod_num::/$mask_size

      # Setup CNI
       ip link add cni0 type bridge
      # ip link set cni0 up
      # ip addr add $pod_gw/$mask_size dev cni0
      # ip link set eth0 master cni0
      # ip addr add $ip6_cidr dev cni0
      # ip addr del $ip6_cidr dev eth0
      # ip -6 route change $(ip -6 route | grep default | sed -e 's/eth0/cni0/')

      # rm /etc/netplan/*
      # cat <<EOF > /etc/netplan/01-containerd-net.yaml
      # network:
      # version: 2
      # ethernets:
      #     enp1s0:
      #       dhcp4: false
      #       dhcp6: false
      # bridges:
      #     cni0:
      #       dhcp4: true
      #       dhcp6: true
      #       interfaces:
      #       - enp1s0
      #       addresses:
      #       - $pod_gw/80
      #       - $ip6_cidr # Order matters; last one becomes the primary address
      # EOF
      # chmod 600 /etc/netplan/01-containerd-net.yaml

      mkdir -p /etc/cni/net.d
      cat <<EOF > /etc/cni/net.d/10-containerd-net.conflist
      {
      "cniVersion": "1.0.0",
      "name": "containerd-net",
      "plugins": [
          {
          "type": "bridge",
          "bridge": "cni0",
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
      head -c 16 /dev/urandom | xxd -p > /etc/machine-id
      set -x
      mkdir -p /sys/fs/cgroup/$${POD_NAME}/besteffort
      rm /bin/aux/*ip*tables*
      exec k3s agent ${local.common_args} --server https://${var.apiserver_hostname}:6443
    EOT
  }
}

resource "kubernetes_service_v1" "kubelet" {
  metadata {
    name      = "kubelet"
    namespace = var.namespace
  }
  spec {
    selector = {
      app = "kubelet"
    }
    port {
      port        = 10250
      target_port = "metrics-https"
    }
  }
}

resource "kubernetes_daemon_set_v1" "ndppd" {
  metadata {
    name      = "ndppd"
    namespace = var.namespace
    labels = {
      app = "ndppd"
    }
  }

  spec {
    selector {
      match_labels = {
        app = "ndppd"
      }
    }

    strategy {
      type = "RollingUpdate"
      rolling_update {
        max_unavailable = "100%"
      }
    }

    template {
      metadata {
        labels = {
          app = "ndppd"
        }
      }

      spec {
        host_network   = true
        restart_policy = "Always"

        node_selector = {
          role   = "kubelet"
          flavor = "pod"
        }

        image_pull_secrets {
          name = var.pull_secret_name
        }

        container {
          name  = "ndppd"
          image = "docker.io/moechs/almalinux-ndppd:0.2.5"

          security_context {
            capabilities {
              drop = ["ALL"]
              add  = ["NET_ADMIN", "NET_RAW"]
            }
          }

          volume_mount {
            name       = "config"
            mount_path = "/etc/ndppd.conf"
            sub_path   = "ndppd.conf"
          }
        }

        volume {
          name = "config"
          config_map {
            name = kubernetes_config_map_v1.ndppd.metadata[0].name
          }
        }

      }
    }
  }
}

resource "kubernetes_config_map_v1" "ndppd" {
  metadata {
    name      = "ndppd-config"
    namespace = var.namespace
  }
  data = {
    "ndppd.conf" = <<-EOT
      proxy eth0 {
        rule ::/0 {
          auto
        }
      }
    EOT
  }
}
