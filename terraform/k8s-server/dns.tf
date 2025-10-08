data "aws_route53_zone" "main" {
  zone_id = var.zone_id
}

resource "aws_route53_record" "apiserver_each_first" {
  zone_id = var.zone_id
  name    = "apiserver-0"
  type    = "AAAA"
  ttl     = 30
  records = [module.k3s_server_first.ipv6_addresses[0]]
}

resource "aws_route53_record" "apiserver_each" {
  count   = var.replicas - 1
  zone_id = var.zone_id
  name    = "apiserver-${count.index + 1}"
  type    = "AAAA"
  ttl     = 30
  records = flatten([module.k3s_servers[0].ipv6_addresses[count.index]])
}

resource "aws_route53_record" "apiservers" {
  zone_id = var.zone_id
  name    = "apiserver"
  type    = "AAAA"
  ttl     = 30
  records = flatten(concat([module.k3s_server_first.ipv6_addresses[0]], module.k3s_servers[*].ipv6_addresses[*]))
}

resource "aws_route53_record" "etcd" {
  count   = var.separate_etcd ? 1 : 0
  zone_id = var.zone_id
  name    = "etcd"
  type    = "AAAA"
  ttl     = 30
  records = [local.etcd_v6_addr]
}

resource "aws_route53_record" "apiserver_srv" {
  zone_id = var.zone_id
  name    = "_apiserver._tcp"
  type    = "SRV"
  ttl     = 30
  records = [for i in range(var.replicas) : "0 1 6443 apiserver-${i}.${data.aws_route53_zone.main.name}."]
}

resource "aws_route53_record" "kube_scheduler" {
  count   = var.kube_scheduler_cloud_details != null ? 1 : 0
  zone_id = var.zone_id
  name    = "kube-scheduler"
  type    = "AAAA"
  ttl     = 30
  records = [module.kube_scheduler_vm[0].ipv6_addresses[0]]
}
