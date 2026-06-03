resource "aws_ecs_task_definition" "orders_api" {
  family                   = "orders-api"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = 256
  memory                   = 512

  execution_role_arn = module.ecs_execution_role.arn
  task_role_arn      = module.ecs_task_role_orders_api.arn

  container_definitions = jsonencode([
    {
      name      = "orders-api"
      image     = "${aws_ecr_repository.orders_api.repository_url}:latest"
      essential = true

      portMappings = [
        {
          containerPort = 80
          protocol      = "tcp"
          name          = "orders-api"
        }
      ]

      command = ["nginx", "-g", "daemon off;"]

      environment = [
        {
          name  = "SERVICE_NAME"
          value = "orders-api"
        }
      ]

      logConfiguration = {
        logDriver = "awslogs"

        options = {
          awslogs-group         = aws_cloudwatch_log_group.orders_api.name
          awslogs-region        = "us-east-1"
          awslogs-stream-prefix = "ecs"
        }
      }
    }
  ])
}

resource "aws_security_group" "orders_api_ecs" {
  name   = "${local.name}-orders-api-ecs"
  vpc_id = module.ecs_vpc.vpc_id

  ingress {
    from_port = 80
    to_port   = 80
    protocol  = "tcp"

    cidr_blocks = [
      # module.ecs_vpc.vpc_cidr_block,
      # module.service_vpc.vpc_cidr_block

      "0.0.0.0/0"
    ]
  }

  egress {
    from_port = 0
    to_port   = 0
    protocol  = "-1"

    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_ecs_service" "orders_api" {
  name                   = "orders-api"
  cluster                = module.ecs_cluster.cluster_id
  task_definition        = aws_ecs_task_definition.orders_api.arn
  desired_count          = 1
  launch_type            = "FARGATE"
  enable_execute_command = true

  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 200

  platform_version = "LATEST"

  network_configuration {
    subnets          = module.ecs_vpc.private_subnets
    security_groups  = [aws_security_group.orders_api_ecs.id]
    assign_public_ip = false
  }

  vpc_lattice_configurations {
    role_arn = module.db_proxy_ecs_infra_role.arn

    target_group_arn = aws_vpclattice_target_group.orders_api.arn

    port_name = "orders-api"
  }

  # vpc_lattice_configurations {
  #   role_arn         = module.db_proxy_ecs_infra_role.arn
  #   target_group_arn = aws_vpclattice_target_group.maintenance.arn
  #   # port_name        = "maintenance"
  #   port_name = "orders-api"
  # }

  depends_on = [
    aws_vpclattice_target_group.orders_api
  ]
}

module "ecs_task_role_orders_api" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role"
  version = "~> 6.0"

  name            = "${local.name}-ecs-task-role-orders-api"
  use_name_prefix = false

  create = true

  trust_policy_permissions = {
    TrustRoleAndServiceToAssume = {
      actions = [
        "sts:AssumeRole",
      ]
      principals = [{
        type = "Service"
        identifiers = [
          "ecs-tasks.amazonaws.com",
        ]
      }]
    }
  }

  policies = {
    "TaskExecution"      = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
    "ecs_exec"           = aws_iam_policy.ecs_exec.arn
    "vpc_lattice_invoke" = aws_iam_policy.vpc_lattice_invoke.arn
  }
}

resource "aws_cloudwatch_log_group" "orders_api" {
  name = "/ecs/demo-lattice-orders-api"
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

      #health_check_interval_seconds = 30
      health_check_timeout_seconds = 3

      #healthy_threshold_count   = 3
      #unhealthy_threshold_count = 3

      health_check_interval_seconds = 6
      healthy_threshold_count       = 2
      unhealthy_threshold_count     = 2
    }
  }
}

resource "aws_vpclattice_service" "orders_api" {
  name      = "orders-api"
  auth_type = "AWS_IAM"
  #auth_type = "NONE"
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

resource "aws_vpclattice_listener_rule" "admin_route" {
  name = "admin"

  listener_identifier = aws_vpclattice_listener.orders_api.arn
  service_identifier  = aws_vpclattice_service.orders_api.id

  priority = 10

  match {
    http_match {
      path_match {
        match {
          prefix = "/admin"
        }
      }
    }
  }

  action {
    forward {
      target_groups {
        target_group_identifier = aws_vpclattice_target_group.orders_api.id
        #target_group_identifier = aws_vpclattice_target_group.maintenance.id
        weight = 100
      }
    }
  }
}

resource "aws_vpclattice_listener_rule" "public_route" {
  name = "public"

  listener_identifier = aws_vpclattice_listener.orders_api.arn
  service_identifier  = aws_vpclattice_service.orders_api.id

  priority = 20

  match {
    http_match {
      path_match {
        match {
          prefix = "/public/"
        }
      }
    }
  }

  action {
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
        Sid    = "AllowAllForDebug"
        Effect = "Allow"

        Principal = "*"

        Action   = "vpc-lattice-svcs:Invoke"
        Resource = "*"
      }
    ]
  })
}


resource "aws_ecr_repository" "orders_api" {
  name = "${local.name}-orders-api"
}

resource "null_resource" "build_and_push_orders_api" {

  triggers = {
    index      = filemd5("../src/ecs/orders-api/index.html")
    dockerfile = filemd5("../src/ecs/orders-api/Dockerfile")
    admin      = filemd5("../src/ecs/orders-api/admin/index.html")
    public     = filemd5("../src/ecs/orders-api/public/index.html")
  }

  provisioner "local-exec" {
    command = <<EOT
      aws ecr get-login-password --region us-east-1 \
      | docker login --username AWS --password-stdin ${aws_ecr_repository.orders_api.repository_url}

      docker build --platform linux/amd64 -t orders-api ../src/ecs/orders-api
      docker tag orders-api:latest ${aws_ecr_repository.orders_api.repository_url}:latest
      docker push ${aws_ecr_repository.orders_api.repository_url}:latest
    EOT
  }
}

