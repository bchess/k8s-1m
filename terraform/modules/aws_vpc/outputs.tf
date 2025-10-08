output "infra" {
  value = {
    "vpc_id"     = aws_vpc.self.id
    "subnet_ids" = { for k, v in aws_subnet.self : k => v.id }
    "ipv6_profile" = aws_iam_instance_profile.ipv6_profile.name
  }
  depends_on = [aws_route_table_association.self, aws_internet_gateway.self]
}
