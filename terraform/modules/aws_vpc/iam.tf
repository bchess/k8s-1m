resource "aws_iam_role" "ipv6_role" {
  name  = "k8s1m-ipv6-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "ipv6_policy" {
  name  = "k8s1m-ipv6-policy"
  role  = aws_iam_role.ipv6_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ec2:AssignIpv6Addresses"
        ]
        Resource = "*"
      }
    ]
  })
}

# Create instance profile
resource "aws_iam_instance_profile" "ipv6_profile" {
  name  = "k8s1m-ipv6-profile"
  role  = aws_iam_role.ipv6_role.name
}