resource "aws_ecr_repository" "dashboard" {
  name = "${local.name}-dashboard"
}

resource "null_resource" "build_and_push_dashboard" {
  triggers = {
    server_js  = filemd5("../src/ecs/dashboard/server.js")
    dockerfile = filemd5("../src/ecs/dashboard/Dockerfile")
    package    = filemd5("../src/ecs/dashboard/package.json")
  }

  provisioner "local-exec" {
    command = <<EOT
      aws ecr get-login-password --region us-east-1 \
      | docker login --username AWS --password-stdin ${aws_ecr_repository.dashboard.repository_url}

      docker build --platform linux/amd64 --provenance=false -t dashboard ../src/ecs/dashboard
      docker tag dashboard:latest ${aws_ecr_repository.dashboard.repository_url}:latest
      docker push ${aws_ecr_repository.dashboard.repository_url}:latest
    EOT
  }
}

module "ecs_task_role_dashboard" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role"
  version = "~> 6.0"

  name            = "${local.name}-ecs-task-role-dashboard"
  use_name_prefix = false
  create          = true

  trust_policy_permissions = {
    TrustEcsTasks = {
      actions = ["sts:AssumeRole"]

      principals = [{
        type        = "Service"
        identifiers = ["ecs-tasks.amazonaws.com"]
      }]
    }
  }

  policies = {
    TaskExecution = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
    ecs_exec      = aws_iam_policy.ecs_exec.arn
  }
}

resource "aws_iam_policy" "dashboard_assume_clients" {
  name = "${local.name}-dashboard-assume-clients"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = "sts:AssumeRole"
      Resource = [
        module.ecs_task_role_client_a.arn,
        module.ecs_task_role_client_b.arn
      ]
    }]
  })
}

resource "aws_iam_role_policy_attachment" "dashboard_assume_clients" {
  role       = module.ecs_task_role_dashboard.name
  policy_arn = aws_iam_policy.dashboard_assume_clients.arn
}

resource "aws_security_group" "dashboard_alb" {
  name   = "${local.name}-dashboard-alb"
  vpc_id = module.ecs_vpc.vpc_id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = [var.dashboard_allowed_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "dashboard_ecs" {
  name   = "${local.name}-dashboard-ecs"
  vpc_id = module.ecs_vpc.vpc_id

  ingress {
    from_port       = 3000
    to_port         = 3000
    protocol        = "tcp"
    security_groups = [aws_security_group.dashboard_alb.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_lb" "dashboard" {
  name               = "${local.name}-dashboard"
  load_balancer_type = "application"
  internal           = false

  subnets         = module.ecs_vpc.public_subnets
  security_groups = [aws_security_group.dashboard_alb.id]
}

resource "aws_lb_target_group" "dashboard" {
  name        = "${local.name}-dashboard"
  port        = 3000
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = module.ecs_vpc.vpc_id

  health_check {
    enabled             = true
    path                = "/"
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

resource "aws_lb_listener" "dashboard" {
  load_balancer_arn = aws_lb.dashboard.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.dashboard.arn
  }
}

resource "aws_cloudwatch_log_group" "dashboard" {
  name = "/ecs/${local.name}-dashboard"
}

resource "aws_ecs_task_definition" "dashboard" {
  family                   = "${local.name}-dashboard"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"

  cpu    = 256
  memory = 512

  execution_role_arn = module.ecs_execution_role.arn
  task_role_arn      = module.ecs_task_role_dashboard.arn

  container_definitions = jsonencode([
    {
      name      = "dashboard"
      image     = "${aws_ecr_repository.dashboard.repository_url}:latest"
      essential = true

      portMappings = [
        {
          containerPort = 3000
          hostPort      = 3000
          protocol      = "tcp"
        }
      ]

      environment = [
        {
          name  = "AWS_REGION"
          value = "us-east-1"
        },
        {
          name  = "LATTICE_ENDPOINT"
          value = aws_vpclattice_service.orders_api.dns_entry[0].domain_name
        },
        {
          name  = "CLIENT_A_ROLE_ARN"
          value = module.ecs_task_role_client_a.arn
        },
        {
          name  = "CLIENT_B_ROLE_ARN"
          value = module.ecs_task_role_client_b.arn
        }
      ]

      logConfiguration = {
        logDriver = "awslogs"

        options = {
          awslogs-group         = aws_cloudwatch_log_group.dashboard.name
          awslogs-region        = "us-east-1"
          awslogs-stream-prefix = "ecs"
        }
      }
    }
  ])

  depends_on = [
    null_resource.build_and_push_dashboard
  ]
}

resource "aws_ecs_service" "dashboard" {
  name            = "dashboard"
  cluster         = module.ecs_cluster.cluster_id
  task_definition = aws_ecs_task_definition.dashboard.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  enable_execute_command = true

  network_configuration {
    subnets          = module.ecs_vpc.private_subnets
    security_groups  = [aws_security_group.dashboard_ecs.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.dashboard.arn
    container_name   = "dashboard"
    container_port   = 3000
  }

  depends_on = [
    aws_lb_listener.dashboard
  ]
}

output "dashboard_url" {
  value = "http://${aws_lb.dashboard.dns_name}"
}