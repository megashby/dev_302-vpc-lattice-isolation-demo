resource "aws_vpclattice_service_network" "this" {
  name = "${local.name}-network"
}

resource "aws_vpclattice_access_log_subscription" "this" {
  resource_identifier = aws_vpclattice_service_network.this.id
  destination_arn     = aws_cloudwatch_log_group.lattice_access_logs.arn
}

resource "aws_vpclattice_service_network_vpc_association" "ecs_vpc" {
  vpc_identifier             = module.ecs_vpc.vpc_id
  service_network_identifier = aws_vpclattice_service_network.this.id
}

resource "aws_vpclattice_service_network_vpc_association" "service_vpc" {
  vpc_identifier             = module.service_vpc.vpc_id
  service_network_identifier = aws_vpclattice_service_network.this.id
}


resource "aws_cloudwatch_log_group" "lattice_access_logs" {
  name              = "/aws/vpclattice/${local.name}-access-logs"
  retention_in_days = 7
}

resource "aws_cloudwatch_log_resource_policy" "vpclattice" {
  # policy_name = "vpclattice-access-logs"
  resource_arn = aws_cloudwatch_log_group.lattice_access_logs.arn

  policy_document = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowVpcLatticeLogs"
        Effect = "Allow"

        Principal = {
          Service = "delivery.logs.amazonaws.com"
        }

        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]

        Resource = "${aws_cloudwatch_log_group.lattice_access_logs.arn}:*"
      }
    ]
  })
}

module "db_proxy_ecs_infra_role" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role"
  version = "~> 6.0"

  name = "${local.name}-db-proxy-ecs-infra-role"

  create = true

  trust_policy_permissions = {
    ecs = {
      actions = ["sts:AssumeRole"]
      principals = [{
        type        = "Service"
        identifiers = ["ecs.amazonaws.com"]
      }]
    }
  }

  policies = {
    infra = "arn:aws:iam::aws:policy/AmazonECSInfrastructureRolePolicyForVpcLattice"
  }
}