locals {
  dist_scheduler_namespace      = "kube-system"
  dist_scheduler_image          = "docker.io/bchess/dist-scheduler:v5"
  wait_for_subschedulers        = local.dist_scheduler_replicas > 0 ? (local.dist_scheduler_replicas - 1) / (local.dist_scheduler_replicas) - 0.0001 : 0
  dist_scheduler_replicas       = var.dist_scheduler.replicas
  dist_scheduler_parallelism    = var.dist_scheduler.parallelism
  dist_scheduler_num_schedulers = var.dist_scheduler.num_schedulers
  dist_scheduler_cores          = var.dist_scheduler.cores
  dist_scheduler_gogc           = var.dist_scheduler.gogc

  # TLS configuration
  webhook_cert_org = "dist-scheduler"
  webhook_cert_dns_names = [
    "dist-scheduler-webhook.kube-system.svc",
    "dist-scheduler-webhook.kube-system.svc.cluster.local"
  ]
}

resource "tls_private_key" "webhook_ca" {
  count = var.dist_scheduler.watch_pods ? 0 : 1

  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_self_signed_cert" "webhook_ca" {
  count = var.dist_scheduler.watch_pods ? 0 : 1

  private_key_pem = tls_private_key.webhook_ca[0].private_key_pem

  subject {
    common_name  = "dist-scheduler-webhook-ca"
    organization = local.webhook_cert_org
  }

  validity_period_hours = 8760 # 1 year
  is_ca_certificate     = true

  allowed_uses = [
    "cert_signing",
    "key_encipherment",
    "digital_signature",
  ]
}

resource "tls_private_key" "webhook_server" {
  count     = var.dist_scheduler.watch_pods ? 0 : 1
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_cert_request" "webhook_server" {
  count           = var.dist_scheduler.watch_pods ? 0 : 1
  private_key_pem = tls_private_key.webhook_server[0].private_key_pem

  subject {
    common_name  = local.webhook_cert_dns_names[0]
    organization = local.webhook_cert_org
  }

  dns_names = local.webhook_cert_dns_names
}

resource "tls_locally_signed_cert" "webhook_server" {
  count              = var.dist_scheduler.watch_pods ? 0 : 1
  cert_request_pem   = tls_cert_request.webhook_server[0].cert_request_pem
  ca_private_key_pem = tls_private_key.webhook_ca[0].private_key_pem
  ca_cert_pem        = tls_self_signed_cert.webhook_ca[0].cert_pem

  validity_period_hours = 8760 # 1 year

  allowed_uses = [
    "key_encipherment",
    "digital_signature",
    "server_auth",
    "client_auth"
  ]
}

resource "kubernetes_secret_v1" "webhook_tls" {
  count = var.dist_scheduler.watch_pods ? 0 : 1
  metadata {
    name      = "dist-scheduler-webhook-tls"
    namespace = local.dist_scheduler_namespace
  }

  data = {
    "tls.crt" = tls_locally_signed_cert.webhook_server[0].cert_pem
    "tls.key" = tls_private_key.webhook_server[0].private_key_pem
    "ca.crt"  = tls_self_signed_cert.webhook_ca[0].cert_pem
  }
}

resource "kubernetes_deployment_v1" "dist_scheduler" {
  metadata {
    name      = "dist-scheduler"
    namespace = local.dist_scheduler_namespace
  }

  spec {
    replicas = local.dist_scheduler_replicas

    selector {
      match_labels = {
        app  = "dist-scheduler"
        role = "scheduler"
      }
    }

    strategy {
      type = "RollingUpdate"
      rolling_update {
        max_surge       = 0
        max_unavailable = "100%"
      }
    }

    template {
      metadata {
        annotations = {
          bump                  = "1"
          "fluentbit.io/parser" = "glog_format"
          config_hash           = sha256(jsonencode(kubernetes_config_map_v1.dist_scheduler_config.data))
        }
        labels = {
          app  = "dist-scheduler"
          role = "scheduler"
        }
      }

      spec {
        node_selector = {
          "role" = "kubelet"
        }
        affinity {
          node_affinity {
            required_during_scheduling_ignored_during_execution {
              node_selector_term {
                match_expressions {
                  key      = "node-role.kubernetes.io/control-plane"
                  operator = "DoesNotExist"
                }
                match_expressions {
                  key      = "pool-id"
                  operator = "In"
                  values   = ["0", "2", "3"]
                }
              }
            }
          }

          pod_anti_affinity {
            preferred_during_scheduling_ignored_during_execution {
              weight = 100
              pod_affinity_term {
                label_selector {
                  match_labels = {
                    app = "dist-scheduler"
                  }
                }
                topology_key = "kubernetes.io/hostname"
              }
            }
          }
        }

        service_account_name = "dist-scheduler"

        image_pull_secrets {
          name = kubernetes_secret_v1.pull_secret["kube-system"].metadata[0].name
        }

        container {
          name  = "dist-scheduler"
          image = local.dist_scheduler_image

          image_pull_policy = "IfNotPresent"

          args = [
            "--grpc-addr=:50051",
            "--secure-port=8080",
            "--config=/etc/dist-scheduler/config.yaml",
            "--kube-api-qps=200000",
            "--kube-api-burst=400000",
            "--authorization-always-allow-paths=/healthz,/readyz,/livez,/metrics,/debug/pprof/*",
            "--num-concurrent-schedulers=${local.dist_scheduler_num_schedulers}",
            "--leader-eligible=${local.dist_scheduler_replicas == 1 ? "true" : "false"}",
            "--wait-for-subschedulers=${local.wait_for_subschedulers}",
            "--watch-pods=${var.dist_scheduler.watch_pods}",
            "--node-selector=flavor!=pod"
          ]

          env {
            name = "POD_NAME"
            value_from {
              field_ref {
                field_path = "metadata.name"
              }
            }
          }

          env {
            name = "POD_NAMESPACE"
            value_from {
              field_ref {
                field_path = "metadata.namespace"
              }
            }
          }

          env {
            name = "POD_IP"
            value_from {
              field_ref {
                field_path = "status.podIP"
              }
            }
          }

          env {
            name  = "GOMEMLIMIT"
            value = "${floor(local.dist_scheduler_cores * 2 * 0.9)}GiB"
          }

          env {
            name  = "GOGC"
            value = local.dist_scheduler_gogc
          }

          port {
            container_port = 50051
            name           = "scheduler-rpc"
            protocol       = "TCP"
          }

          port {
            container_port = 8080
            name           = "metrics-https"
            protocol       = "TCP"
          }

          resources {
            limits = {
              cpu    = local.dist_scheduler_cores
              memory = "${local.dist_scheduler_cores * 2}Gi"
            }
            requests = {
              cpu    = local.dist_scheduler_cores
              memory = "${(local.dist_scheduler_cores - 1) * 2}Gi" # subtract 2Gi to work on c4d's that have slightly less memory
            }
          }

          readiness_probe {
            tcp_socket {
              port = 50051
            }
            initial_delay_seconds = 5
            period_seconds        = 5
          }

          liveness_probe {
            tcp_socket {
              port = 50051
            }
            initial_delay_seconds = 5
            period_seconds        = 5
          }

          startup_probe {
            tcp_socket {
              port = 50051
            }
            initial_delay_seconds = 5
            period_seconds        = 5
            failure_threshold     = 10
          }

          volume_mount {
            name       = "dist-scheduler-config"
            mount_path = "/etc/dist-scheduler"
          }

          dynamic "volume_mount" {
            for_each = var.dist_scheduler.watch_pods ? [] : [1]
            content {
              name       = "webhook-tls"
              mount_path = "/etc/webhook/certs"
              read_only  = true
            }
          }
        }

        volume {
          name = "dist-scheduler-config"

          config_map {
            name = "dist-scheduler-config"
          }
        }

        dynamic "volume" {
          for_each = var.dist_scheduler.watch_pods ? [] : [1]
          content {
            name = "webhook-tls"
            secret {
              secret_name = kubernetes_secret_v1.webhook_tls[0].metadata[0].name
            }
          }
        }
      }
    }
  }
  wait_for_rollout = false
}

resource "kubernetes_deployment_v1" "dist_scheduler_relay" {
  metadata {
    name      = "dist-scheduler-relay"
    namespace = local.dist_scheduler_namespace
  }

  spec {
    replicas = ceil((local.dist_scheduler_replicas - 1) / 9)

    selector {
      match_labels = {
        app  = "dist-scheduler"
        role = "relay"
      }
    }

    strategy {
      type = "RollingUpdate"
      rolling_update {
        max_surge       = 0
        max_unavailable = "100%"
      }
    }

    template {
      metadata {
        annotations = {
          bump                  = "1"
          "fluentbit.io/parser" = "glog_format"
        }
        labels = {
          app  = "dist-scheduler"
          role = "relay"
        }
      }

      spec {
        node_selector = {
          "role" = "kubelet"
        }
        affinity {
          node_affinity {
            required_during_scheduling_ignored_during_execution {
              node_selector_term {
                match_expressions {
                  key      = "node-role.kubernetes.io/control-plane"
                  operator = "DoesNotExist"
                }
                match_expressions {
                  key      = "pool-id"
                  operator = "In"
                  values   = ["0", "2", "3"]
                }
              }
            }
          }

          pod_anti_affinity {
            preferred_during_scheduling_ignored_during_execution {
              weight = 100
              pod_affinity_term {
                label_selector {
                  match_labels = {
                    app = "dist-scheduler"
                  }
                }
                topology_key = "kubernetes.io/hostname"
              }
            }
          }
        }

        service_account_name = "dist-scheduler"

        image_pull_secrets {
          name = kubernetes_secret_v1.pull_secret["kube-system"].metadata[0].name
        }

        container {
          name  = "relay"
          image = local.dist_scheduler_image

          image_pull_policy = "IfNotPresent"

          args = [
            "--grpc-addr=:50051",
            "--secure-port=8080",
            "--config=/etc/dist-scheduler/config.yaml",
            "--kube-api-qps=200000",
            "--kube-api-burst=400000",
            "--authorization-always-allow-paths=/healthz,/readyz,/livez,/metrics,/debug/pprof/*",
            "--num-concurrent-schedulers=${local.dist_scheduler_num_schedulers}",
            "--leader-eligible=true",
            "--relay-only=true",
            "--wait-for-subschedulers=${local.wait_for_subschedulers}",
            "--watch-pods=${var.dist_scheduler.watch_pods}",
            "--node-selector=flavor!=pod"
          ]

          env {
            name = "POD_NAME"
            value_from {
              field_ref {
                field_path = "metadata.name"
              }
            }
          }

          env {
            name = "POD_NAMESPACE"
            value_from {
              field_ref {
                field_path = "metadata.namespace"
              }
            }
          }

          env {
            name = "POD_IP"
            value_from {
              field_ref {
                field_path = "status.podIP"
              }
            }
          }

          env {
            name  = "GOGC"
            value = local.dist_scheduler_gogc
          }

          env {
            name  = "GOMEMLIMIT"
            value = "${floor(local.dist_scheduler_cores * 2 * 0.9)}GiB"
          }

          port {
            container_port = 50051
            name           = "scheduler-rpc"
            protocol       = "TCP"
          }

          port {
            container_port = 8080
            name           = "metrics-https"
            protocol       = "TCP"
          }

          port {
            container_port = 8443
            name           = "webhook"
            protocol       = "TCP"
          }

          resources {
            limits = {
              cpu    = local.dist_scheduler_cores
              memory = "${local.dist_scheduler_cores * 2}Gi"
            }
            requests = {
              cpu    = local.dist_scheduler_cores
              memory = "${(local.dist_scheduler_cores - 1) * 2}Gi" # subtract 2Gi to work on c4d's that have slightly less memory
            }
          }

          readiness_probe {
            tcp_socket {
              port = 50051
            }
            initial_delay_seconds = 5
            period_seconds        = 5
          }

          liveness_probe {
            tcp_socket {
              port = 50051
            }
            initial_delay_seconds = 5
            period_seconds        = 5
          }

          startup_probe {
            tcp_socket {
              port = 50051
            }
            initial_delay_seconds = 5
            period_seconds        = 5
            failure_threshold     = 10
          }

          volume_mount {
            name       = "dist-scheduler-config"
            mount_path = "/etc/dist-scheduler"
          }

          dynamic "volume_mount" {
            for_each = var.dist_scheduler.watch_pods ? [] : [1]
            content {
              name       = "webhook-tls"
              mount_path = "/etc/webhook/certs"
              read_only  = true
            }
          }
        }

        volume {
          name = "dist-scheduler-config"

          config_map {
            name = "dist-scheduler-config"
          }
        }

        dynamic "volume" {
          for_each = var.dist_scheduler.watch_pods ? [] : [1]
          content {
            name = "webhook-tls"
            secret {
              secret_name = kubernetes_secret_v1.webhook_tls[0].metadata[0].name
            }
          }
        }
      }
    }
  }
  wait_for_rollout = false
}

resource "kubernetes_config_map_v1" "dist_scheduler_config" {
  metadata {
    name      = "dist-scheduler-config"
    namespace = local.dist_scheduler_namespace
  }

  data = {
    "config.yaml" = <<-EOT
      apiVersion: kubescheduler.config.k8s.io/v1
      kind: KubeSchedulerConfiguration
      clientConnection:
        qps: 99999999
        burst: 99999999
      leaderElection:
        leaderElect: false
      parallelism: ${local.dist_scheduler_parallelism}
      profiles:
      - schedulerName: dist-scheduler
        percentageOfNodesToScore: 5
        plugins:
          postFilter:
            disabled:
            - name: DefaultPreemption
          permit:
            enabled:
            - name: DistPermit
    EOT
  }
}

resource "kubernetes_service_v1" "dist_scheduler" {
  metadata {
    name      = "dist-scheduler"
    namespace = local.dist_scheduler_namespace
  }

  spec {
    cluster_ip = "None"

    port {
      name        = "scheduler-rpc"
      port        = 50051
      target_port = "scheduler-rpc"
    }

    port {
      name        = "metrics-https"
      port        = 8080
      target_port = "metrics-https"
    }

    selector = {
      app = "dist-scheduler"
    }
  }
}

resource "kubernetes_service_account_v1" "dist_scheduler" {
  metadata {
    name      = "dist-scheduler"
    namespace = local.dist_scheduler_namespace
  }
}

resource "kubernetes_cluster_role_binding_v1" "dist_scheduler_kube_scheduler" {
  metadata {
    name = "dist-scheduler-kube-scheduler"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "system:kube-scheduler"
  }

  subject {
    kind      = "ServiceAccount"
    namespace = local.dist_scheduler_namespace
    name      = kubernetes_service_account_v1.dist_scheduler.metadata[0].name
  }
}

resource "kubernetes_role_v1" "dist_scheduler" {
  metadata {
    name      = "dist-scheduler"
    namespace = local.dist_scheduler_namespace
  }

  rule {
    api_groups = [""]
    resources  = ["configmaps"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = ["discovery.k8s.io"]
    resources  = ["endpointslices"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = [""]
    resources  = ["endpoints"]
    verbs      = ["create", "update", "delete"]
  }


  rule {
    api_groups = ["coordination.k8s.io"]
    resources  = ["leases"]
    verbs      = ["get", "list", "watch", "create", "update", "delete"]
  }
}

resource "kubernetes_role_binding_v1" "dist_scheduler" {
  metadata {
    name      = "dist-scheduler"
    namespace = local.dist_scheduler_namespace
  }

  subject {
    kind      = "ServiceAccount"
    namespace = local.dist_scheduler_namespace
    name      = kubernetes_service_account_v1.dist_scheduler.metadata[0].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.dist_scheduler.metadata[0].name
  }
}

resource "kubernetes_cluster_role_v1" "dist_scheduler" {
  metadata {
    name = "dist-scheduler"
  }

  rule {
    api_groups = [""]
    resources  = ["nodes"]
    verbs      = ["patch"]
  }

  rule {
    api_groups = ["storage.k8s.io"]
    resources  = ["storageclasses"]
    verbs      = ["get", "list", "watch"]
  }
}

resource "kubernetes_cluster_role_binding_v1" "dist_scheduler" {
  metadata {
    name = "dist-scheduler"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role_v1.dist_scheduler.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    namespace = local.dist_scheduler_namespace
    name      = kubernetes_service_account_v1.dist_scheduler.metadata[0].name
  }
}

resource "kubernetes_validating_webhook_configuration_v1" "dist_scheduler" {
  count = var.dist_scheduler.watch_pods ? 0 : 1
  metadata {
    name = "dist-scheduler-webhook"
  }

  webhook {
    name = "dist-scheduler.bchess.org"
    client_config {
      service {
        name      = "dist-scheduler-webhook"
        namespace = local.dist_scheduler_namespace
        path      = "/validate"
      }
      ca_bundle = tls_self_signed_cert.webhook_ca[0].cert_pem
    }
    rule {
      api_groups   = [""]
      api_versions = ["v1"]
      operations   = ["CREATE"]
      resources    = ["pods"]
      scope        = "Namespaced"
    }
    failure_policy            = "Ignore"
    side_effects              = "None"
    admission_review_versions = ["v1"]
  }
}

resource "kubernetes_service_v1" "dist_scheduler_webhook" {
  count = var.dist_scheduler.watch_pods ? 0 : 1

  metadata {
    name      = "dist-scheduler-webhook"
    namespace = local.dist_scheduler_namespace
  }

  spec {
    port {
      name        = "webhook"
      port        = 443
      target_port = "webhook"
    }

    # No selector defined. The leader will set endpoints for the service
  }
}
