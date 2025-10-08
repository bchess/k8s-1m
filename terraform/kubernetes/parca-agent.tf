# Create the parca namespace
resource "kubernetes_namespace_v1" "parca" {
  count = var.deploy_parca ? 1 : 0
  metadata {
    name = "parca"
    labels = {
      "pod-security.kubernetes.io/audit"   = "privileged"
      "pod-security.kubernetes.io/enforce" = "privileged"
      "pod-security.kubernetes.io/warn"    = "privileged"
    }
  }
}

# ClusterRole for parca-agent
resource "kubernetes_cluster_role_v1" "parca_agent" {
  count = var.deploy_parca ? 1 : 0
  metadata {
    name = "parca-agent"
    labels = {
      "app.kubernetes.io/component" = "observability"
      "app.kubernetes.io/instance"  = "parca-agent"
      "app.kubernetes.io/name"      = "parca-agent"
      "app.kubernetes.io/version"   = "v0.36.0"
    }
  }

  rule {
    api_groups = [""]
    resources  = ["pods"]
    verbs      = ["list", "watch"]
  }

  rule {
    api_groups = [""]
    resources  = ["nodes"]
    verbs      = ["get"]
  }
}

# ClusterRoleBinding for parca-agent
resource "kubernetes_cluster_role_binding_v1" "parca_agent" {
  count = var.deploy_parca ? 1 : 0
  metadata {
    name = "parca-agent"
    labels = {
      "app.kubernetes.io/component" = "observability"
      "app.kubernetes.io/instance"  = "parca-agent"
      "app.kubernetes.io/name"      = "parca-agent"
      "app.kubernetes.io/version"   = "v0.36.0"
    }
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role_v1.parca_agent[0].metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = "parca-agent"
    namespace = kubernetes_namespace_v1.parca[0].metadata[0].name
  }
}

# ConfigMap for parca-agent
resource "kubernetes_config_map_v1" "parca_agent" {
  count = var.deploy_parca ? 1 : 0
  metadata {
    name      = "parca-agent"
    namespace = kubernetes_namespace_v1.parca[0].metadata[0].name
    labels = {
      "app.kubernetes.io/component" = "observability"
      "app.kubernetes.io/instance"  = "parca-agent"
      "app.kubernetes.io/name"      = "parca-agent"
      "app.kubernetes.io/version"   = "v0.36.0"
    }
  }

  data = {
    "parca-agent.yaml" = <<-EOT
      "relabel_configs":
      - "source_labels":
        - "__meta_process_executable_compiler"
        "target_label": "compiler"
      - "source_labels":
        - "__meta_system_kernel_machine"
        "target_label": "arch"
      - "source_labels":
        - "__meta_system_kernel_release"
        "target_label": "kernel_version"
      - "source_labels":
        - "__meta_kubernetes_namespace"
        "target_label": "namespace"
      - "source_labels":
        - "__meta_kubernetes_pod_name"
        "target_label": "pod"
      - "source_labels":
        - "__meta_kubernetes_pod_container_name"
        "target_label": "container"
      - "source_labels":
        - "__meta_kubernetes_pod_container_image"
        "target_label": "container_image"
      - "source_labels":
        - "__meta_kubernetes_node_label_topology_kubernetes_io_region"
        "target_label": "region"
      - "source_labels":
        - "__meta_kubernetes_node_label_topology_kubernetes_io_zone"
        "target_label": "zone"
      - "action": "labelmap"
        "regex": "__meta_kubernetes_pod_label_(.+)"
        "replacement": "$${1}"
      - "action": "labeldrop"
        "regex": "apps_kubernetes_io_pod_index|controller_revision_hash|statefulset_kubernetes_io_pod_name|pod_template_hash"
    EOT
  }
}

# ServiceAccount for parca-agent
resource "kubernetes_service_account_v1" "parca_agent" {
  count = var.deploy_parca ? 1 : 0
  metadata {
    name      = "parca-agent"
    namespace = kubernetes_namespace_v1.parca[0].metadata[0].name
    labels = {
      "app.kubernetes.io/component" = "observability"
      "app.kubernetes.io/instance"  = "parca-agent"
      "app.kubernetes.io/name"      = "parca-agent"
      "app.kubernetes.io/version"   = "v0.36.0"
    }
  }
}

# DaemonSet for parca-agent
resource "kubernetes_daemon_set_v1" "parca_agent" {
  count = var.deploy_parca ? 1 : 0
  metadata {
    name      = "parca-agent"
    namespace = kubernetes_namespace_v1.parca[0].metadata[0].name
    labels = {
      "app.kubernetes.io/component" = "observability"
      "app.kubernetes.io/instance"  = "parca-agent"
      "app.kubernetes.io/name"      = "parca-agent"
      "app.kubernetes.io/version"   = "v0.36.0"
    }
  }

  spec {
    selector {
      match_labels = {
        "app.kubernetes.io/component" = "observability"
        "app.kubernetes.io/instance"  = "parca-agent"
        "app.kubernetes.io/name"      = "parca-agent"
      }
    }

    template {
      metadata {
        labels = {
          "app.kubernetes.io/component" = "observability"
          "app.kubernetes.io/instance"  = "parca-agent"
          "app.kubernetes.io/name"      = "parca-agent"
          "app.kubernetes.io/version"   = "v0.36.0"
        }
      }

      spec {
        host_pid = true

        affinity {
          node_affinity {
            required_during_scheduling_ignored_during_execution {
              node_selector_term {
                match_expressions {
                  key      = "type"
                  operator = "NotIn"
                  values   = ["kwok"]
                }
                match_expressions {
                  key      = "flavor"
                  operator = "NotIn"
                  values   = ["pod"]
                }
              }
            }
          }
        }

        security_context {
          seccomp_profile {
            type = "RuntimeDefault"
          }
        }

        service_account_name = kubernetes_service_account_v1.parca_agent[0].metadata[0].name

        toleration {
          operator = "Exists"
        }

        image_pull_secrets {
          name = kubernetes_secret_v1.pull_secret["parca"].metadata[0].name
        }

        container {
          name  = "parca-agent"
          image = "ghcr.io/parca-dev/parca-agent:v0.36.0"

          args = [
            "--http-address=:8080",
            "--node=$(NODE_NAME)",
            "--config-path=/etc/parca-agent/parca-agent.yaml",
            "--remote-store-address=parca.${var.monitoring_hostname}:443",
            "--remote-store-insecure-skip-verify",
          ]

          env {
            name = "NODE_NAME"
            value_from {
              field_ref {
                field_path = "spec.nodeName"
              }
            }
          }
          env {
            name = "PARCA_BEARER_TOKEN"
            value_from {
              secret_key_ref {
                name = "parca-agent-token"
                key  = "PARCA_BEARER_TOKEN"
              }
            }
          }

          port {
            container_port = 8080
            name           = "http"
          }

          security_context {
            allow_privilege_escalation = true
            privileged                 = true
            capabilities {
              add = ["SYS_ADMIN"]
            }
          }

          volume_mount {
            name       = "tmp"
            mount_path = "/tmp"
          }

          volume_mount {
            name       = "run"
            mount_path = "/run"
          }

          volume_mount {
            name       = "boot"
            mount_path = "/boot"
            read_only  = true
          }

          volume_mount {
            name       = "modules"
            mount_path = "/lib/modules"
          }

          volume_mount {
            name       = "debugfs"
            mount_path = "/sys/kernel/debug"
          }

          volume_mount {
            name       = "cgroup"
            mount_path = "/sys/fs/cgroup"
          }

          volume_mount {
            name       = "bpffs"
            mount_path = "/sys/fs/bpf"
          }

          volume_mount {
            name       = "config"
            mount_path = "/etc/parca-agent"
          }

          volume_mount {
            name       = "dbus-system"
            mount_path = "/var/run/dbus/system_bus_socket"
          }
        }

        volume {
          name = "tmp"
          empty_dir {}
        }

        volume {
          name = "run"
          host_path {
            path = "/run"
          }
        }

        volume {
          name = "boot"
          host_path {
            path = "/boot"
          }
        }

        volume {
          name = "cgroup"
          host_path {
            path = "/sys/fs/cgroup"
          }
        }

        volume {
          name = "modules"
          host_path {
            path = "/lib/modules"
          }
        }

        volume {
          name = "bpffs"
          host_path {
            path = "/sys/fs/bpf"
          }
        }

        volume {
          name = "debugfs"
          host_path {
            path = "/sys/kernel/debug"
          }
        }

        volume {
          name = "config"
          config_map {
            name = kubernetes_config_map_v1.parca_agent[0].metadata[0].name
          }
        }

        volume {
          name = "dbus-system"
          host_path {
            path = "/var/run/dbus/system_bus_socket"
          }
        }
      }
    }
  }
}

resource "random_password" "parca_bearer_token" {
  count   = var.deploy_parca ? 1 : 0
  length  = 48
  special = false
}

resource "kubernetes_secret_v1" "parca_agent_token" {
  count = var.deploy_parca ? 1 : 0
  metadata {
    name      = "parca-agent-token"
    namespace = kubernetes_namespace_v1.parca[0].metadata[0].name
  }
  data = {
    PARCA_BEARER_TOKEN = random_password.parca_bearer_token[0].result
  }
}
