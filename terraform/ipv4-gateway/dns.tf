data "aws_route53_zone" "main" {
  zone_id = var.zone_id
}

resource "aws_route53_record" "ipv4gateway_a" {
  zone_id = var.zone_id
  name    = "ipv4gateway"
  type    = "A"
  ttl     = 60
  records = [vultr_instance.gateway.main_ip]
}

resource "aws_route53_record" "ipv4gateway_aaaa" {
  zone_id = var.zone_id
  name    = "ipv4gateway"
  type    = "AAAA"
  ttl     = 60
  records = [vultr_instance.gateway.v6_main_ip]
}
