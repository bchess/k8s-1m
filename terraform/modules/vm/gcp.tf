locals {
  enable_gcp    = var.cloud_details.gcp != null ? true : false
  firewall_tags = [trim(var.unique_name, "-")]
  arch = (var.cloud_details.gcp != null ?
    substr(split("-", var.cloud_details.gcp.instance_type)[0], -1, 1) == "a" ? "arm64" : "amd64"
  : "amd64")
}

data "google_compute_image" "ubuntu" {
  count = local.enable_gcp ? 1 : 0
  # ubuntu-2404-noble-amd64-v20250409 has 6.8.0-1027-gcp, has ip6tables --set-xmark bug https://github.com/k3s-io/k3s/issues/11175
  # ubuntu-2404-noble-amd64-v20250228 has 6.8.0-1024-gcp, works
  # family    = "ubuntu-2404-lts-${local.arch}-v20250228"
  name    = "ubuntu-2404-noble-${local.arch}-v20250228"
  project = "ubuntu-os-cloud"
}

# Note: we can't use managed instance groups because they do not support IPV6-only
resource "google_compute_instance_template" "self" {
  count        = local.enable_gcp ? 1 : 0
  name         = trim(var.offset > 0 ? "${var.unique_name}${var.offset}" : var.unique_name, "-")
  machine_type = var.cloud_details.gcp.instance_type
  # zone         = var.cloud_details.gcp.zone

  disk {
    boot         = true
    source_image = data.google_compute_image.ubuntu[0].self_link
    disk_size_gb = var.cloud_details.gcp.disk_size_gb
    disk_type    = "hyperdisk-balanced"
  }

  network_interface {
    network    = var.cloud_infra.gcp.vpc_id
    subnetwork = var.cloud_infra.gcp.subnet_ids[provider::google::region_from_zone(var.cloud_details.gcp.zone)]
    stack_type = "IPV4_IPV6"
    ipv6_access_config {
      network_tier = "PREMIUM" # only PREMIUM is supported for IPv6
    }
  }

  network_performance_config {
    total_egress_bandwidth_tier = var.cloud_details.gcp.tier_1_networking ? "TIER_1" : "DEFAULT"
  }

  metadata = {
    startup-script = <<-EOT
      #!/bin/bash
      mkdir -p /etc/apt/apt.conf.d
      rm -f /etc/apt/apt.conf.d/99ipv4-only
      echo 'Acquire::ForceIPv6 "true";' > /etc/apt/apt.conf.d/99force-ipv6
      mkdir -p /etc/systemd/resolved.conf.d/
      echo -e "[Resolve]\nDNS=2001:4860:4860::8888 2001:4860:4860::8844" > /etc/systemd/resolved.conf.d/ipv6.conf
      hostnamectl set-hostname $(hostname -s)
      systemctl restart systemd-resolved
      ${var.startup_script}
    EOT

    serial-port-enable = "TRUE"
  }

  scheduling {
    preemptible        = var.cloud_details.gcp.preemptible
    automatic_restart  = var.cloud_details.gcp.preemptible ? false : true
    provisioning_model = var.cloud_details.gcp.preemptible ? "SPOT" : "STANDARD"
    # MIG only supports STOP not DELETE
    instance_termination_action = var.cloud_details.gcp.preemptible ? "STOP" : null
  }


  # Fireewall rules match based on tags
  tags = local.firewall_tags
}

resource "google_compute_instance_from_template" "self" {
  count        = local.enable_gcp ? var.replicas : 0
  name         = trim(var.replicas > 1 ? "${var.unique_name}${count.index + var.offset}" : var.unique_name, "-")
  machine_type = var.cloud_details.gcp.instance_type
  zone         = var.cloud_details.gcp.zone

  source_instance_template = google_compute_instance_template.self[0].id

  /*
  boot_disk {
    initialize_params {
      image = data.google_compute_image.ubuntu[0].self_link
      size  = var.cloud_details.gcp.disk_size_gb
    }
  }

  network_interface {
    network    = var.cloud_infra.gcp.vpc_id
    subnetwork = var.cloud_infra.gcp.subnet_ids[provider::google::region_from_zone(var.cloud_details.gcp.zone)]
    stack_type = "IPV6_ONLY"

    ipv6_access_config {
      name         = "External IPv6"
      network_tier = "PREMIUM" # only PREMIUM is supported for IPv6
    }
  }

  network_performance_config {
    total_egress_bandwidth_tier = var.cloud_details.gcp.tier_1_networking ? "TIER_1" : "DEFAULT"
  }

  metadata = {
    startup-script = <<-EOT
      #!/bin/bash
      mkdir -p /etc/apt/apt.conf.d
      rm -f /etc/apt/apt.conf.d/99ipv4-only
      echo 'Acquire::ForceIPv6 "true";' > /etc/apt/apt.conf.d/99force-ipv6
      mkdir -p /etc/systemd/resolved.conf.d/
      echo -e "[Resolve]\nDNS=2001:4860:4860::8888 2001:4860:4860::8844" > /etc/systemd/resolved.conf.d/ipv6.conf
      hostnamectl set-hostname ${var.unique_name}${var.replicas > 1 ? count.index + var.offset : ""}
      systemctl restart systemd-resolved
      ${var.startup_script}
    EOT

    serial-port-enable = "TRUE"
  }

  scheduling {
    preemptible                 = var.cloud_details.gcp.preemptible
    automatic_restart           = var.cloud_details.gcp.preemptible ? false : true
    provisioning_model          = var.cloud_details.gcp.preemptible ? "SPOT" : "STANDARD"
    instance_termination_action = var.cloud_details.gcp.preemptible ? "DELETE" : null
  }


  # Fireewall rules match based on tags
  tags = local.firewall_tags */

  labels = {
    name = var.replicas > 1 ? "${var.unique_name}${count.index + var.offset}" : var.unique_name
    tags = join("-", sort(var.tags))
  }
  lifecycle {
    replace_triggered_by = [
      null_resource.gcp_replace_instance_type_or_script.id
    ]
  }
}

resource "null_resource" "gcp_replace_instance_type_or_script" {
  triggers = {
    instance_type  = local.enable_gcp ? var.cloud_details.gcp.instance_type : null
    startup_script = local.enable_gcp ? var.startup_script : null
  }
}

resource "google_compute_firewall" "ingress" {
  for_each = local.enable_gcp ? toset(var.firewall_inbound_rules) : toset([])

  // Replace the "/" with "-" to form a valid name.
  name      = "${var.unique_name}-ingress-${replace(each.value, "/", "-")}"
  network   = var.cloud_infra.gcp.vpc_id
  direction = "INGRESS"

  allow {
    protocol = split("/", each.value)[0]
    ports    = [split("/", each.value)[1]]
  }

  source_ranges = ["::/0"]
  target_tags   = local.firewall_tags
}

/* TODO
resource "google_compute_firewall" "icmp" {
  count = local.enable_gcp ? 1 : 0

  name      = "${var.unique_name}-icmp"
  network   = var.cloud_infra.gcp.vpc_id
  direction = "INGRESS"

  allow {
    protocol = "icmpv6"
  }

  source_ranges = ["::/0"]
  target_tags   = local.firewall_tags
}
*/

resource "google_compute_firewall" "egress" {
  count = local.enable_gcp ? 1 : 0

  name      = "${var.unique_name}-egress"
  network   = var.cloud_infra.gcp.vpc_id
  direction = "EGRESS"

  allow {
    protocol = "all"
  }

  destination_ranges = ["::/0"]
  target_tags        = local.firewall_tags
}
