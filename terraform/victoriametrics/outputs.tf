output "password" {
  value = random_string.password.result
}

output "monitoring_hostname" {
  value = "${local.monitoring_segment}.${data.aws_route53_zone.main.name}"
}

output "auth" {
  value = {
    username = local.auth_username
    password = random_password.caddy_password.result
  }
}
