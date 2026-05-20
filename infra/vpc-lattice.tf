resource "aws_vpclattice_service_network" "this" {
  name = "${local.name}-network"
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

resource "aws_vpclattice_target_group" "orders_api" {
  name = "orders-api"
  type = "IP"

  config {
    port     = 80
    protocol = "HTTP"

    vpc_identifier = module.ecs_vpc.vpc_id

    health_check {
      enabled          = true
      protocol         = "HTTP"
      protocol_version = "HTTP1"
      path             = "/"
      port             = 80

      health_check_interval_seconds = 30
      health_check_timeout_seconds  = 10

      healthy_threshold_count   = 3
      unhealthy_threshold_count = 3
    }
  }
}

resource "aws_vpclattice_service" "orders_api" {
  name = "orders-api"
  #auth_type = "AWS_IAM"
  auth_type = "NONE"
}

resource "aws_vpclattice_listener" "orders_api" {
  service_identifier = aws_vpclattice_service.orders_api.id
  name               = "http"
  protocol           = "HTTP"
  port               = 80

  default_action {
    forward {
      target_groups {
        target_group_identifier = aws_vpclattice_target_group.orders_api.id
        weight                  = 100
      }
    }
  }
}

resource "aws_vpclattice_service_network_service_association" "orders_api" {
  service_identifier         = aws_vpclattice_service.orders_api.id
  service_network_identifier = aws_vpclattice_service_network.this.id
}

resource "aws_vpclattice_auth_policy" "orders_api_normal" {
  resource_identifier = aws_vpclattice_service.orders_api.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowInvoke"
        Effect    = "Allow"
        Principal = "*"
        Action    = "vpc-lattice-svcs:Invoke"
        Resource  = "*"
      }
    ]
  })
}

