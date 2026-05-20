resource "aws_ecs_task_definition" "maintenance" {
  family                   = "maintenance"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = 256
  memory                   = 512

  execution_role_arn = module.ecs_execution_role.arn
  task_role_arn      = module.ecs_task_role_maintenance.arn

  container_definitions = jsonencode([
    {
      name      = "maintenance"
      image     = "public.ecr.aws/docker/library/nginx:latest"
      essential = true

      portMappings = [
        {
          containerPort = 80
          protocol      = "tcp"
          name          = "maintenance"
        }
      ]

      command = ["nginx", "-g", "daemon off;"]

      environment = [
        {
          name  = "SERVICE_NAME"
          value = "maintenance"
        }
      ]

      logConfiguration = {
        logDriver = "awslogs"

        options = {
          awslogs-group         = aws_cloudwatch_log_group.maintenance.name
          awslogs-region        = "us-east-1"
          awslogs-stream-prefix = "ecs"
        }
      }
    }
  ])
}

resource "aws_security_group" "maintenance_ecs" {
  name   = "${local.name}-maintenance-ecs"
  vpc_id = module.ecs_vpc.vpc_id

  ingress {
    from_port = 80
    to_port   = 80
    protocol  = "tcp"

    cidr_blocks = [
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

resource "aws_ecs_service" "maintenance" {
  name                   = "maintenance"
  cluster                = module.ecs_cluster.cluster_id
  task_definition        = aws_ecs_task_definition.maintenance.arn
  desired_count          = 1
  launch_type            = "FARGATE"
  enable_execute_command = true

  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 200

  platform_version = "LATEST"

  network_configuration {
    subnets          = module.ecs_vpc.private_subnets
    security_groups  = [aws_security_group.maintenance_ecs.id]
    assign_public_ip = false
  }

  vpc_lattice_configurations {
    role_arn = module.db_proxy_ecs_infra_role.arn

    target_group_arn = aws_vpclattice_target_group.maintenance.arn

    port_name = "maintenance"
  }

  depends_on = [
    aws_vpclattice_target_group.maintenance
  ]
}

module "ecs_task_role_maintenance" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role"
  version = "~> 6.0"

  name   = "ecs-task-role-maintenance"
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

resource "aws_cloudwatch_log_group" "maintenance" {
  name = "/ecs/demo-lattice-maintenance"
}

resource "aws_vpclattice_target_group" "maintenance" {
  name = "maintenance"
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

resource "aws_vpclattice_service" "maintenance" {
  name = "maintenance"
  #auth_type = "AWS_IAM"
  auth_type = "NONE"
}

resource "aws_vpclattice_listener" "maintenance" {
  service_identifier = aws_vpclattice_service.maintenance.id
  name               = "http"
  protocol           = "HTTP"
  port               = 80

  default_action {
    forward {
      target_groups {
        target_group_identifier = aws_vpclattice_target_group.maintenance.id
        weight                  = 100
      }
    }
  }
}

resource "aws_vpclattice_service_network_service_association" "maintenance" {
  service_identifier         = aws_vpclattice_service.maintenance.id
  service_network_identifier = aws_vpclattice_service_network.this.id
}

resource "aws_vpclattice_auth_policy" "maintenance_normal" {
  resource_identifier = aws_vpclattice_service.maintenance.arn

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