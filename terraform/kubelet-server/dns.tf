resource "aws_route53_record" "kubelet" {
  # limit to just 10 records otherwise this takes so long to apply
  count = max(0, min(var.offset + var.replicas, 10) - var.offset)

  zone_id = var.zone_id
  name    = "kubelet-${count.index + var.offset}"
  type    = "AAAA"
  ttl     = 60
  records = [module.k3s_kubelet[0].ipv6_addresses[count.index]]
}
