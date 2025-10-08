locals {
  enable_aws = var.cloud_details.aws != null ? true : false
}

data "aws_ami" "ubuntu" {
  count = local.enable_aws ? 1 : 0

  owners = ["099720109477"] # Canonical
  # 20250325 has kernel 6.8.0-1025-aws which has ip6tables --set-xmark bug https://github.com/k3s-io/k3s/issues/11175
  # 20250225 has kernel 6.8.0-1021-aws which works
  name_regex  = "^ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-.*-server-20250225"
  most_recent = true

  filter {
    name = "architecture"
    values = local.enable_aws ? [
      substr(split(".", var.cloud_details.aws.instance_type)[0], -1, 1) == "g" ? "arm64" : "x86_64"
    ] : []
  }
}

resource "aws_instance" "self" {
  count = local.enable_aws ? var.replicas : 0

  ami                  = data.aws_ami.ubuntu[0].id
  instance_type        = var.cloud_details.aws.instance_type
  iam_instance_profile = var.cloud_infra.aws.ipv6_profile

  network_interface {
    network_interface_id = aws_network_interface.self[count.index].id
    device_index         = 0
  }

  metadata_options {
    http_protocol_ipv6 = "enabled"
  }

  availability_zone = var.cloud_details.aws.availability_zone
  user_data         = <<EOT
#!/bin/bash
hostnamectl set-hostname ${var.unique_name}${var.replicas > 1 ? count.index + var.offset : ""}
TOKEN=`curl -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600"`
MAC=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/network/interfaces/macs/)
if ! pod_cidr=$(curl -fsS -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/network/interfaces/macs/$MAC/ipv6-prefix); then
  REGION=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/placement/region)
  INTERFACE_ID=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/network/interfaces/macs/$MAC/interface-id)
  if ! command -v aws &> /dev/null; then
      snap install aws-cli --classic
  fi
  aws --region=$REGION ec2 assign-ipv6-addresses \
      --network-interface-id $INTERFACE_ID \
      --endpoint-url https://ec2.$REGION.api.aws \
      --ipv6-prefix-count 1
  max_attempts=30
  attempt=1
  while ! pod_cidr=$(curl -fsS -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/network/interfaces/macs/$MAC/ipv6-prefix); do
      if [ $attempt -ge $max_attempts ]; then
          echo "Failed to get IPv6 prefix after $max_attempts attempts"
          exit 1
      fi
      echo "Attempt $attempt: Failed to get IPv6 prefix, retrying in 2 seconds..."
      sleep 2
      ((attempt++))
  done
fi
${var.startup_script}
EOT

  dynamic "instance_market_options" {
    for_each = local.enable_aws ? var.cloud_details.aws.spot_price != null ? [var.cloud_details.aws.spot_price] : [] : []

    content {
      market_type = "spot"
      spot_options {
        max_price = var.cloud_details.aws.spot_price
      }
    }
  }

  root_block_device {
    volume_size = lookup(var.cloud_details.aws, "disk_size_gb", null)
  }

  user_data_replace_on_change = true

  tags = {
    Name = var.replicas > 1 ? "${var.unique_name}${count.index + var.offset}" : var.unique_name
  }

  lifecycle {
    replace_triggered_by = [
      null_resource.replace_instance_type_or_spot.id
    ]
    ignore_changes = [
      instance_market_options[0].spot_options[0].max_price,
      # ami
    ]
  }
}

resource "null_resource" "replace_instance_type_or_spot" {
  triggers = {
    instance_type = local.enable_aws ? var.cloud_details.aws.instance_type : null
    spot_price    = local.enable_aws ? var.cloud_details.aws.spot_price : null
  }
}

resource "aws_network_interface" "self" {
  count = local.enable_aws ? var.replicas : 0

  subnet_id          = var.cloud_infra.aws.subnet_ids[var.cloud_details.aws.availability_zone]
  ipv6_address_count = 1
  # ipv6_prefix_count = 1
  security_groups = [aws_security_group.self[0].id]

  enable_primary_ipv6 = true
}

data "aws_region" "current" {
  count = local.enable_aws ? 1 : 0
}

resource "aws_security_group" "self" {
  count = local.enable_aws ? 1 : 0

  name = var.unique_name

  vpc_id = var.cloud_infra.aws.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "self" {
  for_each = toset(local.enable_aws ? var.firewall_inbound_rules : [])

  security_group_id = aws_security_group.self[0].id
  ip_protocol       = split("/", each.value)[0]
  from_port         = split("/", each.value)[1]
  to_port           = split("/", each.value)[1]
  cidr_ipv6         = "::/0"
}

resource "aws_vpc_security_group_ingress_rule" "icmp" {
  count = local.enable_aws ? 1 : 0

  security_group_id = aws_security_group.self[0].id
  ip_protocol       = "icmp"
  cidr_ipv6         = "::/0"
  from_port         = 128 # echo request
  to_port           = 129 # echo reply
}

resource "aws_vpc_security_group_egress_rule" "self" {
  count = local.enable_aws ? 1 : 0

  security_group_id = aws_security_group.self[0].id
  ip_protocol       = "all"
  cidr_ipv6         = "::/0"
}
