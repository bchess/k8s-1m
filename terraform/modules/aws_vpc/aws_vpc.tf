data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_vpc" "self" {
  cidr_block = "10.0.0.0/16"

  assign_generated_ipv6_cidr_block = true
}

resource "aws_internet_gateway" "self" {
  vpc_id = aws_vpc.self.id
}

resource "aws_route_table" "self" {
  vpc_id = aws_vpc.self.id

  route {
    ipv6_cidr_block = "::/0"
    gateway_id      = aws_internet_gateway.self.id
  }
}

locals {
  az_to_index = zipmap(data.aws_availability_zones.available.names, range(length(data.aws_availability_zones.available.names)))
}

resource "aws_subnet" "self" {
  for_each = local.az_to_index

  availability_zone = each.key

  vpc_id          = aws_vpc.self.id
  ipv6_native     = true
  ipv6_cidr_block = cidrsubnet(aws_vpc.self.ipv6_cidr_block, 8, each.value)

  assign_ipv6_address_on_creation = true

  enable_resource_name_dns_aaaa_record_on_launch = true

  tags = {
    Name = each.key
  }
}

resource "aws_route_table_association" "self" {
  for_each = local.az_to_index

  subnet_id      = aws_subnet.self[each.key].id
  route_table_id = aws_route_table.self.id
}
