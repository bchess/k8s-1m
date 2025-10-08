locals {
  # lb_count = var.replicas > 1 ? 1 : 0
  lb_count = 0
}

# TODO

# resource "vultr_load_balancer" "k3s" {
#   count               = local.lb_count
#   region              = var.region
#   label               = "k3s"
#   balancing_algorithm = "roundrobin"
# 
#   forwarding_rules {
#     frontend_protocol = "tcp"
#     frontend_port     = 6443
#     backend_protocol  = "tcp"
#     backend_port      = 6443
#   }
# 
#   health_check {
#     protocol = "tcp"
#     port     = 6443
#     path     = ""
#   }
# 
#   firewall_rules {
#     ip_type = "v6"
#     port    = "6443"
#     source  = "::/0"
#   }
# 
#   attached_instances = sort(concat([vultr_instance.k3s_server_first.id], vultr_instance.k3s_servers[*].id))
# }
# 