resource "google_compute_network" "self" {
  name                    = "k8s-1m"
  auto_create_subnetworks = false
  routing_mode            = "GLOBAL"
}

resource "google_compute_route" "default_ipv6" {
  name             = "default-ipv6"
  network          = google_compute_network.self.id
  dest_range       = "::/0"
  next_hop_gateway = "default-internet-gateway"
  priority         = 1000
}

resource "google_compute_subnetwork" "self" {
  for_each = toset(var.regions)

  name       = "k8s-1m-${each.key}"
  network    = google_compute_network.self.id
  region     = each.key
  stack_type = local.stack_type

  ip_cidr_range = "10.${index(var.regions, each.key)}.0.0/16"

  ipv6_access_type         = "EXTERNAL"
  private_ip_google_access = true

  lifecycle {
    replace_triggered_by = [
      null_resource.replace_subnetwork[each.key].id
    ]
  }
}

resource "null_resource" "replace_subnetwork" {
  for_each = toset(var.regions)
  triggers = {
    stack_type = local.stack_type
  }
}

locals {
  stack_type = "IPV4_IPV6"
}
