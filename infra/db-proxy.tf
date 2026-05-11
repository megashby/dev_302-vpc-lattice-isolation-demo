resource "aws_security_group" "ecs_proxy" {
  name   = "${local.name}-ecs-proxy"
  vpc_id = module.service_vpc.vpc_id

  ingress {
    from_port = 3000
    to_port   = 3000
    protocol  = "tcp"

    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port = 5432
    to_port   = 5432
    protocol  = "tcp"

    cidr_blocks = [module.service_vpc.vpc_cidr_block]
  }
}

resource "aws_ecs_cluster" "proxy" {
  name = "${local.name}-db-proxy-cluster"
}

resource "aws_ecs_task_definition" "proxy" {
  family                   = "${local.name}-db-proxy"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"

  cpu    = 256
  memory = 512

  execution_role_arn = module.db_proxy_ecs_execution_role.arn
  task_role_arn      = module.db_proxy_ecs_task_role.arn

  container_definitions = jsonencode([
    {
      name  = "db-proxy"
      image = "${aws_ecr_repository.proxy.repository_url}:latest"

      portMappings = [{
        containerPort = 3000
      }]

      environment = [
        {
          name  = "DB_HOST"
          value = module.rds.db_instance_address
        },
        {
          name  = "DB_NAME"
          value = "demo"
        },
        {
          name  = "DB_USER"
          value = "app_user"
        },
        {
          name  = "AWS_REGION"
          value = "us-east-1"
        }
      ]
    }
  ])
}

resource "aws_ecs_service" "proxy" {
  name            = "${local.name}-db-proxy"
  cluster         = aws_ecs_cluster.proxy.id
  task_definition = aws_ecs_task_definition.proxy.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets         = module.service_vpc.private_subnets
    security_groups = [aws_security_group.ecs_proxy.id]
  }
}

module "db_proxy_ecs_execution_role" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role"
  version = "~> 6.0"

  name = "${local.name}-db-proxy-ecs-exec-role"

  create = true

  trust_policy_permissions = {
    ecs = {
      actions = ["sts:AssumeRole"]
      principals = [{
        type        = "Service"
        identifiers = ["ecs-tasks.amazonaws.com"]
      }]
    }
  }

  policies = {
    execution = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
  }
}

module "db_proxy_ecs_task_role" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role"
  version = "~> 6.0"

  name = "${local.name}-db-proxy-ecs-task-role"

  create = true

  trust_policy_permissions = {
    ecs = {
      actions = ["sts:AssumeRole"]
      principals = [{
        type        = "Service"
        identifiers = ["ecs-tasks.amazonaws.com"]
      }]
    }
  }

  inline_policy_permissions = {
    lattice = {
      effect    = "Allow"
      actions   = ["vpc-lattice-svcs:Invoke"]
      resources = ["*"]
    }

    # REQUIRED for IAM DB auth (important if you're using it)
    rds_iam = {
      effect    = "Allow"
      actions   = ["rds-db:connect"]
      resources = ["*"]
    }
  }
}