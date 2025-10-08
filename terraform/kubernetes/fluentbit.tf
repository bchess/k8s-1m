resource "kubernetes_namespace_v1" "fluentbit" {
  count = var.deploy_fluentbit ? 1 : 0
  metadata {
    name = "fluentbit"
  }
}

resource "kubernetes_service_account_v1" "fluentbit" {
  count = var.deploy_fluentbit ? 1 : 0
  metadata {
    name      = "fluent-bit"
    namespace = kubernetes_namespace_v1.fluentbit[0].metadata[0].name
  }
}

resource "kubernetes_config_map_v1" "fluentbit" {
  count = var.deploy_fluentbit ? 1 : 0
  metadata {
    name      = "fluent-bit"
    namespace = kubernetes_namespace_v1.fluentbit[0].metadata[0].name
  }
  data = {
    "ca.crt"              = var.ca_crt
    "custom_parsers.conf" = <<-EOC
[PARSER]
  Name docker_no_time
  Format json
  Time_Keep Off
  Time_Key time
  Time_Format %Y-%m-%dT%H:%M:%S.%L

[Parser]
  Name        glog_format
  Format      regex
  Regex       ^(?<severity>[IWECF])(?<timestamp>\d{4} \d{2}:\d{2}:\d{2}\.\d{6}) +(?<thread>\d+) (?<src_file>[^:]+):(?<src_line>\d+)\] (?<log>(?:.|\n)*)
  Time_Key    timestamp
  Time_Format %m%d %H:%M:%S.%L
  Time_Keep   Off
  Types thread:integer src_line:integer
EOC

    "fluent-bit.conf" = <<-EOF
[SERVICE]
    Daemon Off
    Flush 1
    Log_Level info
    Parsers_File /fluent-bit/etc/parsers.conf
    Parsers_File /fluent-bit/etc/conf/custom_parsers.conf
    HTTP_Server On
    HTTP_Listen ::0
    HTTP_Port 2020
    Health_Check On
    ipv6 On

[INPUT]
    Name tail
    Path /var/log/containers/*.log
    multiline.parser docker, cri
    Tag kube.*
    Mem_Buf_Limit 50MB
    Refresh_Interval 10
    Skip_Long_Lines On

[INPUT]
    Name systemd
    Tag host.*
    Systemd_Filter _SYSTEMD_UNIT=k3s.service
    Systemd_Filter _SYSTEMD_UNIT=k3s-agent.service
    Systemd_Filter _SYSTEMD_UNIT=kube-scheduler.service
    Systemd_Filter _SYSTEMD_UNIT=kube-controller-manager.service
    Systemd_Filter _SYSTEMD_UNIT=haproxy.service
    Systemd_Filter _TRANSPORT=kernel
    Read_From_Tail On

[FILTER]
    Name Modify
    Match kube.*
    Remove time

[FILTER]
    Name Modify
    Match host.*
    Rename MESSAGE _msg

[FILTER]
    Name kubernetes
    Match kube.*
    Merge_Log On
    Keep_Log On
    K8S-Logging.Parser On
    K8S-Logging.Exclude On
    Use_Kubelet On
    Buffer_Size 1MB

[FILTER]
    Name Modify
    Match kube.*
    Rename msg log

[Output]
    Name http
    Match *
    host logs.${var.monitoring_hostname}
    port 443
    tls On
    tls.verify On
    tls.ca_file /fluent-bit/etc/conf/ca.crt
    http_User ${var.monitoring_auth.username}
    http_Passwd $${MONITORING_AUTH_PASSWORD}
    json_date_key _time
    uri /insert/jsonline?_stream_fields=stream&_msg_field=log
    format json_lines
    json_date_format iso8601
EOF
  }
}

resource "kubernetes_cluster_role_v1" "fluentbit" {
  count = var.deploy_fluentbit ? 1 : 0
  metadata {
    name = "fluent-bit"
  }
  rule {
    api_groups = [""]
    resources  = ["namespaces", "pods", "nodes", "nodes/proxy"]
    verbs      = ["get", "list", "watch"]
  }
}

resource "kubernetes_cluster_role_binding_v1" "fluentbit" {
  count = var.deploy_fluentbit ? 1 : 0
  metadata {
    name = "fluent-bit"
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "fluent-bit"
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.fluentbit[0].metadata[0].name
    namespace = kubernetes_namespace_v1.fluentbit[0].metadata[0].name
  }
}

resource "kubernetes_service_v1" "fluentbit" {
  count = var.deploy_fluentbit ? 1 : 0
  metadata {
    name      = "fluent-bit"
    namespace = kubernetes_namespace_v1.fluentbit[0].metadata[0].name
  }
  spec {
    type = "ClusterIP"
    port {
      port        = 2020
      target_port = "http"
      protocol    = "TCP"
      name        = "http"
    }
    selector = {
      "app.kubernetes.io/name"     = "fluent-bit"
      "app.kubernetes.io/instance" = "fluent-bit"
    }
  }
}

resource "kubernetes_daemon_set_v1" "fluentbit" {
  count = var.deploy_fluentbit ? 1 : 0
  metadata {
    name      = "fluent-bit"
    namespace = kubernetes_namespace_v1.fluentbit[0].metadata[0].name
    labels = {
      "app.kubernetes.io/name"     = "fluent-bit"
      "app.kubernetes.io/instance" = "fluent-bit"
      "app.kubernetes.io/version"  = "3.2.6"
    }
  }
  spec {
    selector {
      match_labels = {
        "app.kubernetes.io/name"     = "fluent-bit"
        "app.kubernetes.io/instance" = "fluent-bit"
      }
    }
    strategy {
      type = "RollingUpdate"
      rolling_update {
        max_unavailable = "50%"
      }
    }
    template {
      metadata {
        labels = {
          "app.kubernetes.io/name"     = "fluent-bit"
          "app.kubernetes.io/instance" = "fluent-bit"
        }
        annotations = {
          "fluentbit.io/exclude" = "true"
          "config_checksum"      = md5(kubernetes_config_map_v1.fluentbit[0].data["fluent-bit.conf"])
          "parser_checksum"      = md5(kubernetes_config_map_v1.fluentbit[0].data["custom_parsers.conf"])
        }
      }
      spec {
        service_account_name = kubernetes_service_account_v1.fluentbit[0].metadata[0].name
        host_network         = true # required for Use_Kubelet On https://docs.fluentbit.io/manual/pipeline/filters/kubernetes#configuration-setup
        dns_policy           = "ClusterFirstWithHostNet"
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
        image_pull_secrets {
          name = kubernetes_secret_v1.pull_secret[kubernetes_namespace_v1.fluentbit[0].metadata[0].name].metadata[0].name
        }
        container {
          name  = "fluent-bit"
          image = "gke.gcr.io/fluent-bit:v3.2.8-gke.8"
          # image             = "docker.io/fluent/fluent-bit:3.2.6"
          image_pull_policy = "IfNotPresent"
          command = [
            "/fluent-bit/bin/fluent-bit"
          ]
          args = [
            "--workdir=/fluent-bit/etc",
            "--config=/fluent-bit/etc/conf/fluent-bit.conf"
          ]
          env {
            name = "MONITORING_AUTH_PASSWORD"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.monitoring_auth[0].metadata[0].name
                key  = "MONITORING_AUTH_PASSWORD"
              }
            }
          }
          port {
            name           = "http"
            container_port = 2020
            protocol       = "TCP"
          }
          liveness_probe {
            http_get {
              path = "/"
              port = "http"
            }
          }
          readiness_probe {
            http_get {
              path = "/api/v1/health"
              port = "http"
            }
          }
          volume_mount {
            name       = "config"
            mount_path = "/fluent-bit/etc/conf"
          }
          volume_mount {
            name       = "varlog"
            mount_path = "/var/log"
          }
          # volume_mount {
          #   name       = "varlibdockercontainers"
          #   mount_path = "/var/lib/docker/containers"
          #   read_only  = true
          # }
          volume_mount {
            name       = "etcmachineid"
            mount_path = "/etc/machine-id"
            read_only  = true
          }
        }

        volume {
          name = "config"
          config_map {
            name = kubernetes_config_map_v1.fluentbit[0].metadata[0].name
          }
        }
        volume {
          name = "varlog"
          host_path {
            path = "/var/log"
          }
        }
        # volume {
        #   name = "varlibdockercontainers"
        #   host_path {
        #     path = "/var/lib/docker/containers"
        #   }
        # }
        volume {
          name = "etcmachineid"
          host_path {
            path = "/etc/machine-id"
            type = "File"
          }
        }
      }
    }
  }
}


resource "kubernetes_secret_v1" "monitoring_auth" {
  count = var.deploy_fluentbit ? 1 : 0
  metadata {
    name      = "monitoring-auth"
    namespace = kubernetes_namespace_v1.fluentbit[0].metadata[0].name
  }
  data = {
    "MONITORING_AUTH_PASSWORD" = var.monitoring_auth.password
  }
}
