output "ipv6_addresses" {
  value = (local.enable_vultr ?
    (
      local.vultr_bare_metal ? vultr_bare_metal_server.self[*].v6_main_ip
      : vultr_instance.self[*].v6_main_ip
    )
    : (
      local.enable_gcp ?
      google_compute_instance_from_template.self[*].network_interface[0].ipv6_access_config[0].external_ipv6
      : flatten(aws_instance.self[*].ipv6_addresses[*])
    )
  )
}

output "id" {
  # Mostly for declaring dependencies
  value = (local.enable_vultr ?
    (
      local.vultr_bare_metal ? vultr_bare_metal_server.self[*].id
      : vultr_instance.self[*].id
    )
    : (
      local.enable_gcp ?
      google_compute_instance_from_template.self[*].id
      : aws_instance.self[*].id
    )
  )
}
