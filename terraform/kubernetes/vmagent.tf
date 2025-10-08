resource "kubernetes_namespace_v1" "vmagent" {
  metadata {
    name = "vmagent"
  }
}

resource "kubernetes_deployment_v1" "vmagent" {
  metadata {
    name      = "vmagent"
    namespace = kubernetes_namespace_v1.vmagent.metadata[0].name
  }
  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "vmagent"
      }
    }
    template {
      metadata {
        labels = {
          app = "vmagent"
        }
        annotations = {
          "config-sha" = sha256(templatefile("${path.module}/vmagent-scrape.yaml.tftpl", {
            domain = var.domain
          }))
        }
      }
      spec {
        service_account_name = kubernetes_service_account_v1.vmagent.metadata[0].name
        image_pull_secrets {
          name = kubernetes_secret_v1.pull_secret[kubernetes_namespace_v1.vmagent.metadata[0].name].metadata[0].name
        }
        container {
          name  = "vmagent"
          image = "docker.io/victoriametrics/vmagent:v1.107.0"
          args = [
            "-enableTCP6",
            "-promscrape.config=/etc/vmagent/scrape.yaml",
            "-remoteWrite.url=https://metrics.${var.monitoring_hostname}/api/v1/write",
            "-remoteWrite.tlsCAFile=/etc/vmagent/ca.crt",
            "-remoteWrite.basicAuth.passwordFile=/etc/vmagent-password/password",
            "-remoteWrite.basicAuth.username=${var.monitoring_auth.username}"
          ]
          volume_mount {
            name       = "vmagent-config"
            mount_path = "/etc/vmagent"
          }
          volume_mount {
            name       = "vmagent-password"
            mount_path = "/etc/vmagent-password"
          }
        }
        volume {
          name = "vmagent-config"
          config_map {
            name = kubernetes_config_map_v1.vmagent-config.metadata[0].name
          }
        }
        volume {
          name = "vmagent-password"
          secret {
            secret_name = kubernetes_secret_v1.vmagent-password.metadata[0].name
          }
        }
      }
    }
  }
  wait_for_rollout = false
}

resource "kubernetes_config_map_v1" "vmagent-config" {
  metadata {
    name      = "vmagent-config"
    namespace = kubernetes_namespace_v1.vmagent.metadata[0].name
  }
  data = {
    "scrape.yaml" = templatefile("${path.module}/vmagent-scrape.yaml.tftpl", {
      domain = var.domain
    })
    "ca.crt" = var.ca_crt
  }
}

resource "kubernetes_secret_v1" "vmagent-password" {
  metadata {
    name      = "vmagent-password"
    namespace = kubernetes_namespace_v1.vmagent.metadata[0].name
  }
  data = {
    "password" = var.monitoring_auth.password
  }
}

resource "kubernetes_service_account_v1" "vmagent" {
  metadata {
    name      = "vmagent"
    namespace = kubernetes_namespace_v1.vmagent.metadata[0].name
  }
}

resource "kubernetes_cluster_role_v1" "vmagent" {
  metadata {
    name = "vmagent"
  }
  rule {
    non_resource_urls = ["/metrics", "/metrics/cadvisor"]
    verbs             = ["get"]
  }
  rule {
    # TODO: maybe consider removing pods and snodes so that it doesn't get overwhelmed
    api_groups = [""]
    resources  = ["nodes", "nodes/metrics", "pods", "services", "endpoints"]
    verbs      = ["get", "list", "watch"]
  }
  rule {
    api_groups = ["discovery.k8s.io"]
    resources  = ["endpointslices"]
    verbs      = ["get", "list", "watch"]
  }
}

resource "kubernetes_cluster_role_binding_v1" "vmagent" {
  metadata {
    name = "vmagent"
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role_v1.vmagent.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.vmagent.metadata[0].name
    namespace = kubernetes_namespace_v1.vmagent.metadata[0].name
  }
}
