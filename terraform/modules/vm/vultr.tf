locals {
  enable_vultr     = var.cloud_details.vultr != null ? true : false
  vultr_bare_metal = startswith(lookup(coalesce(var.cloud_details.vultr, {}), "plan", ""), "vbm")
}

data "vultr_os" "ubuntu" {
  count = local.enable_vultr ? 1 : 0
  filter {
    name   = "name"
    values = ["Ubuntu 24.04 LTS x64"]
  }
}

resource "vultr_instance" "self" {
  count = local.enable_vultr && !local.vultr_bare_metal ? var.replicas : 0

  os_id       = data.vultr_os.ubuntu[0].id
  plan        = var.cloud_details.vultr.plan
  region      = var.cloud_details.vultr.region
  ssh_key_ids = []
  hostname    = var.replicas > 1 ? "${var.unique_name}${count.index + var.offset}" : var.unique_name
  label       = var.replicas > 1 ? "${var.unique_name}${count.index + var.offset}" : var.unique_name
  script_id   = vultr_startup_script.self[0].id
  tags        = var.tags

  enable_ipv6         = true
  firewall_group_id   = vultr_firewall_group.self[0].id
  disable_public_ipv4 = true


  lifecycle {
    replace_triggered_by = [
      vultr_startup_script.self[0].script,
      null_resource.vultr_plan_change.id
    ]
  }
}
resource "null_resource" "vultr_plan_change" {
  triggers = {
    plan = var.cloud_details.vultr != null ? var.cloud_details.vultr.plan : null
  }
}

resource "vultr_bare_metal_server" "self" {
  count = local.vultr_bare_metal ? var.replicas : 0

  os_id       = data.vultr_os.ubuntu[0].id
  plan        = var.cloud_details.vultr.plan
  region      = var.cloud_details.vultr.region
  ssh_key_ids = []
  hostname    = var.replicas > 1 ? "${var.unique_name}${count.index + var.offset}" : var.unique_name
  label       = var.replicas > 1 ? "${var.unique_name}${count.index + var.offset}" : var.unique_name
  script_id   = vultr_startup_script.self[0].id
  tags        = var.tags

  enable_ipv6 = true
  # firewall_group_id = vultr_firewall_group.k3s.id
  # disable_public_ipv4 = true

  activation_email = false

  lifecycle {
    replace_triggered_by = [
      vultr_startup_script.self[0].script
    ]
  }
}

resource "vultr_firewall_group" "self" {
  count = local.enable_vultr && !local.vultr_bare_metal ? var.replicas : 0

  description = var.unique_name
}

resource "vultr_firewall_rule" "inbound" {
  for_each = toset(local.enable_vultr && !local.vultr_bare_metal ? var.firewall_inbound_rules : [])

  firewall_group_id = vultr_firewall_group.self[0].id
  protocol          = split("/", each.value)[0]
  port              = split("/", each.value)[1]
  subnet            = "::"
  ip_type           = "v6"
  subnet_size       = 0
}

resource "vultr_firewall_rule" "icmp" {
  count = local.enable_vultr && !local.vultr_bare_metal ? 1 : 0

  firewall_group_id = vultr_firewall_group.self[0].id
  protocol          = "icmp"
  subnet            = "::"
  ip_type           = "v6"
  subnet_size       = 0
}

resource "vultr_startup_script" "self" {
  count = local.enable_vultr ? 1 : 0

  name   = var.unique_name
  script = base64encode(var.startup_script)
}
