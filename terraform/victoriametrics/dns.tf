data "aws_route53_zone" "main" {
  zone_id = var.zone_id
}

locals {
  dns_names          = toset(["victoriametrics", "logs", "metrics", "parca"])
  monitoring_segment = "obs"
}

resource "aws_route53_record" "dns" {
  for_each = local.dns_names
  zone_id  = var.zone_id
  name     = "${each.value}.${local.monitoring_segment}"
  type     = "AAAA"
  ttl      = 60
  records  = module.victoriametrics_vm.ipv6_addresses
}
