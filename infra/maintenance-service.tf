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
      image     = "${aws_ecr_repository.maintenance.repository_url}:latest"
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

resource "aws_cloudwatch_log_group" "maintenance" {
  name = "/ecs/demo-lattice-maintenance"
}

resource "aws_vpclattice_service" "maintenance" {
  name = "maintenance"
  #auth_type = "AWS_IAM"
  auth_type = "NONE"
}

resource "aws_ecr_repository" "maintenance" {
  name = "${local.name}-maintenance"
}

resource "null_resource" "build_and_push_maintenance" {

  triggers = {
    index      = filemd5("../src/ecs/maintenance/index.html")
    dockerfile = filemd5("../src/ecs/maintenance/Dockerfile")
  }

  provisioner "local-exec" {
    command = <<EOT
      aws ecr get-login-password --region us-east-1 \
      | docker login --username AWS --password-stdin ${aws_ecr_repository.maintenance.repository_url}

      docker build --platform linux/amd64 -t maintenance ../src/ecs/maintenance
      docker tag maintenance:latest ${aws_ecr_repository.maintenance.repository_url}:latest
      docker push ${aws_ecr_repository.maintenance.repository_url}:latest
    EOT
  }
}