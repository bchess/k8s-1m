resource "kubernetes_service_account_v1" "coredns" {
  metadata {
    name      = "coredns"
    namespace = "kube-system"
  }
}

resource "kubernetes_cluster_role_v1" "system_coredns" {
  metadata {
    name = "system:coredns"
    labels = {
      "kubernetes.io/bootstrapping" = "rbac-defaults"
    }
  }

  rule {
    api_groups = [""]
    resources  = ["endpoints", "services", "pods", "namespaces"]
    verbs      = ["list", "watch"]
  }

  rule {
    api_groups = ["discovery.k8s.io"]
    resources  = ["endpointslices"]
    verbs      = ["list", "watch"]
  }
}

resource "kubernetes_cluster_role_binding_v1" "system_coredns" {
  metadata {
    name = "system:coredns"
    labels = {
      "kubernetes.io/bootstrapping" = "rbac-defaults"
    }
    annotations = {
      "rbac.authorization.kubernetes.io/autoupdate" = "true"
    }
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "system:coredns"
  }

  subject {
    kind      = "ServiceAccount"
    name      = "coredns"
    namespace = "kube-system"
  }
}

resource "kubernetes_config_map_v1" "coredns" {
  metadata {
    name      = "coredns"
    namespace = "kube-system"
  }

  data = {
    Corefile = <<-EOF
      .:53 {
          errors
          health
          ready
          kubernetes cluster.local in-addr.arpa ip6.arpa {
            pods insecure
            fallthrough in-addr.arpa ip6.arpa
          }
          prometheus :9153
          forward . /etc/resolv.conf
          cache 30
          loop
          reload
          loadbalance
          import /etc/coredns/custom/*.override
      }
      import /etc/coredns/custom/*.server
    EOF
  }
}

resource "kubernetes_deployment_v1" "coredns" {
  metadata {
    name      = "coredns"
    namespace = "kube-system"
    labels = {
      "k8s-app"            = "kube-dns"
      "kubernetes.io/name" = "CoreDNS"
    }
  }

  spec {
    revision_history_limit = 0

    strategy {
      type = "RollingUpdate"
      rolling_update {
        max_unavailable = 1
      }
    }

    selector {
      match_labels = {
        "k8s-app" = "kube-dns"
      }
    }

    template {
      metadata {
        labels = {
          "k8s-app" = "kube-dns"
        }
      }

      spec {
        priority_class_name  = "system-cluster-critical"
        service_account_name = kubernetes_service_account_v1.coredns.metadata[0].name

        toleration {
          key      = "CriticalAddonsOnly"
          operator = "Exists"
        }
        toleration {
          key      = "node-role.kubernetes.io/control-plane"
          operator = "Exists"
          effect   = "NoSchedule"
        }
        toleration {
          key      = "node-role.kubernetes.io/master"
          operator = "Exists"
          effect   = "NoSchedule"
        }

        node_selector = {
          "kubernetes.io/os" = "linux"
        }

        topology_spread_constraint {
          max_skew           = 1
          topology_key       = "kubernetes.io/hostname"
          when_unsatisfiable = "DoNotSchedule"
          label_selector {
            match_labels = {
              "k8s-app" = "kube-dns"
            }
          }
        }

        image_pull_secrets {
          name = kubernetes_secret_v1.pull_secret["kube-system"].metadata[0].name
        }

        container {
          name              = "coredns"
          image             = "docker.io/rancher/mirrored-coredns-coredns:1.12.1"
          image_pull_policy = "IfNotPresent"

          resources {
            limits = {
              memory = "1Gi"
            }
            requests = {
              cpu    = "100m"
              memory = "1Gi"
            }
          }

          args = ["-conf", "/etc/coredns/Corefile"]

          port {
            container_port = 53
            name           = "dns"
            protocol       = "UDP"
          }
          port {
            container_port = 53
            name           = "dns-tcp"
            protocol       = "TCP"
          }
          port {
            container_port = 9153
            name           = "metrics"
            protocol       = "TCP"
          }

          security_context {
            allow_privilege_escalation = false
            capabilities {
              add  = ["NET_BIND_SERVICE"]
              drop = ["all"]
            }
            read_only_root_filesystem = true
          }

          liveness_probe {
            http_get {
              path   = "/health"
              port   = 8080
              scheme = "HTTP"
            }
            initial_delay_seconds = 60
            period_seconds        = 10
            timeout_seconds       = 1
            success_threshold     = 1
            failure_threshold     = 3
          }

          readiness_probe {
            http_get {
              path   = "/ready"
              port   = 8181
              scheme = "HTTP"
            }
            initial_delay_seconds = 0
            period_seconds        = 2
            timeout_seconds       = 1
            success_threshold     = 1
            failure_threshold     = 3
          }

          volume_mount {
            name       = "config-volume"
            mount_path = "/etc/coredns"
            read_only  = true
          }
          volume_mount {
            name       = "custom-config-volume"
            mount_path = "/etc/coredns/custom"
            read_only  = true
          }
        }

        dns_policy = "Default"

        volume {
          name = "config-volume"
          config_map {
            name = kubernetes_config_map_v1.coredns.metadata[0].name
            items {
              key  = "Corefile"
              path = "Corefile"
            }
          }
        }

        volume {
          name = "custom-config-volume"
          config_map {
            name     = "coredns-custom"
            optional = true
          }
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "kube_dns" {
  metadata {
    name      = "kube-dns"
    namespace = "kube-system"
    labels = {
      "k8s-app"                       = "kube-dns"
      "kubernetes.io/cluster-service" = "true"
      "kubernetes.io/name"            = "CoreDNS"
    }
    annotations = {
      "prometheus.io/port"   = "9153"
      "prometheus.io/scrape" = "true"
    }
  }

  spec {
    selector = {
      "k8s-app" = "kube-dns"
    }

    // In k3s is service cidr + 10
    // https://github.com/k3s-io/k3s/blob/2b244eade5b9567c93340fb6a7d4efcada9dd462/pkg/cli/server/server.go#L378
    cluster_ip       = cidrhost(var.service_cidr, 10)
    cluster_ips      = [cidrhost(var.service_cidr, 10)]
    ip_family_policy = "SingleStack"

    port {
      name        = "dns"
      port        = 53
      protocol    = "UDP"
      target_port = 53
    }
    port {
      name        = "dns-tcp"
      port        = 53
      protocol    = "TCP"
      target_port = 53
    }
    port {
      name        = "metrics"
      port        = 9153
      protocol    = "TCP"
      target_port = 9153
    }
  }
}
