locals {
  pull_secret_namespaces = concat(
    var.pull_secret_namespaces,
    [
      kubernetes_namespace_v1.vmagent.metadata[0].name,
      local.dist_scheduler_namespace,
    ],
    [for ns in kubernetes_namespace_v1.parca : ns.metadata[0].name],
    [for ns in kubernetes_namespace_v1.fluentbit : ns.metadata[0].name]
  )
  pull_secret_name = "pull-secret"
}
resource "kubernetes_secret_v1" "pull_secret" {
  for_each = toset(local.pull_secret_namespaces)
  metadata {
    name      = local.pull_secret_name
    namespace = each.value
  }
  type = "kubernetes.io/dockerconfigjson"
  data = {
    ".dockerconfigjson" = jsonencode(jsondecode(file("${path.module}/pull-secret.json")))
  }
}
