output "hostname" {
  value = local.fqdn
  depends_on = [
    aws_route53_record.ipv4gateway_aaaa,
    aws_route53_record.ipv4gateway_a,
  ]
}

output "password" {
  value = random_string.wireguard_password.result
}