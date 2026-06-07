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

resource "aws_vpclattice_service" "proxy" {
  name = "${local.name}-db-proxy-service"
}

resource "aws_vpclattice_target_group" "proxy" {
  name = "${local.name}-db-proxy-tg"
  type = "IP"

  config {
    protocol = "HTTP"
    port     = 3000

    vpc_identifier = module.service_vpc.vpc_id

    health_check {
      enabled  = true
      protocol = "HTTP"
      path     = "/health"
      port     = 3000

      health_check_interval_seconds = 10

      healthy_threshold_count   = 2
      unhealthy_threshold_count = 2
    }
  }
}

resource "aws_vpclattice_listener" "proxy" {
  name               = "http"
  protocol           = "HTTP"
  port               = 80
  service_identifier = aws_vpclattice_service.proxy.id

  default_action {
    forward {
      target_groups {
        target_group_identifier = aws_vpclattice_target_group.proxy.id
      }
    }
  }
}

resource "aws_vpclattice_service_network_service_association" "proxy" {
  service_identifier         = aws_vpclattice_service.proxy.id
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
