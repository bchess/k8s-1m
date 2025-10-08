
data "aws_route53_zone" "main" {
  name = var.domain
}

locals {
  main_zone_id = data.aws_route53_zone.main.zone_id
}

# locals {
#   parent_domain = join(".", slice(split(".", var.domain), 1, length(split(".", var.domain))))
# }
# 
# data "aws_route53_zone" "parent" {
#   name = local.parent_domain
# }
#
#resource "aws_route53_zone" "main" {
#  name = var.domain
#}
#
#resource "aws_route53_record" "ns" {
#  zone_id = data.aws_route53_zone.parent.zone_id
#  name    = split(".", var.domain)[0]
#  type    = "NS"
#  ttl     = "60"
#  records = aws_route53_zone.main.name_servers
#}
