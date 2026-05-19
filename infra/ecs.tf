module "ecs_cluster" {
  source  = "terraform-aws-modules/ecs/aws"
  version = "~> 6.0"

  cluster_name = "${local.name}-cluster"
}

module "ecs_execution_role" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role"
  version = "~> 6.0"

  name = "${local.name}-ecs-exec-role"

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

  policies = { "TaskExecution" = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy" }

}

module "ecs_task_role" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role"
  version = "~> 6.0"

  name = "${local.name}-ecs-task-role"

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

  policies = { "TaskExecution" = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy" }

  inline_policy_permissions = {
    VpcLatticeInvoke = {
      effect = "Allow"

      actions = [
        "vpc-lattice-svcs:Invoke"
      ]

      resources = ["*"]
    }
  }
}

resource "aws_ecs_task_definition" "client_a" {
  family                   = "client-a"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"

  cpu    = 256
  memory = 512

  execution_role_arn = module.ecs_execution_role.arn
  task_role_arn      = module.ecs_task_role.arn

  container_definitions = jsonencode([
    {
      name  = "client"
      image = "public.ecr.aws/docker/library/node:18"

      essential = true

      environment = [
        {
          name  = "LATTICE_ENDPOINT"
          value = aws_vpclattice_service.proxy.dns_entry[0].domain_name
        },
        {
          name  = "CLIENT_NAME"
          value = "client-a"
        }
      ]

      command = ["node", "-e", file("../src/ecs/client/client.js")]
    }
  ])
}

resource "aws_ecs_task_definition" "client_b" {
  family                   = "client-b"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"

  cpu    = 256
  memory = 512

  execution_role_arn = module.ecs_execution_role.arn
  task_role_arn      = module.ecs_task_role.arn

  container_definitions = jsonencode([
    {
      name  = "client"
      image = "public.ecr.aws/docker/library/node:18"

      essential = true

      environment = [
        {
          name  = "LATTICE_ENDPOINT"
          value = aws_vpclattice_service.proxy.dns_entry[0].domain_name
        },
        {
          name  = "CLIENT_NAME"
          value = "client-b"
        }
      ]

      command = ["node", "-e", file("../src/ecs/client/client.js")]
    }
  ])
}

resource "aws_ecs_service" "client_a" {
  name            = "client-a"
  cluster         = module.ecs_cluster.cluster_id
  task_definition = aws_ecs_task_definition.client_a.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = module.ecs_vpc.private_subnets
    assign_public_ip = false
  }
}

resource "aws_ecs_service" "client_b" {
  name            = "client-b"
  cluster         = module.ecs_cluster.cluster_id
  task_definition = aws_ecs_task_definition.client_b.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = module.ecs_vpc.private_subnets
    assign_public_ip = false
  }
}

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
      image     = "public.ecr.aws/docker/library/nginx:latest"
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

  depends_on = [
    aws_vpclattice_target_group.orders_api
  ]
}

module "ecs_task_role_orders_api" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role"
  version = "~> 6.0"

  name = "${local.name}-ecs-task-role-orders-api"

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
    "TaskExecution" = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
    "ecs_exec"      = aws_iam_policy.ecs_exec.arn
  }

  inline_policy_permissions = {
    VpcLatticeInvoke = {
      effect = "Allow"

      actions = [
        "vpc-lattice-svcs:Invoke"
      ]

      resources = ["*"]
    }
  }
}

resource "aws_cloudwatch_log_group" "orders_api" {
  name = "/ecs/demo-lattice-orders-api"
}

resource "aws_iam_role_policy_attachment" "ecs_exec" {
  role       = module.ecs_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_policy" "ecs_exec" {
  name        = "ecs-exec-orders-api"
  description = "Allow ECS Exec via SSM Messages"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ECSExecSSMMessages"
        Effect = "Allow"
        Action = [
          "ssmmessages:CreateControlChannel",
          "ssmmessages:CreateDataChannel",
          "ssmmessages:OpenControlChannel",
          "ssmmessages:OpenDataChannel"
        ]
        Resource = "*"
      },
      {
        Sid    = "ECSExecSSMCore"
        Effect = "Allow"
        Action = [
          "ssm:UpdateInstanceInformation"
        ]
        Resource = "*"
      },
      {
        Sid    = "ECSExecEC2Messages"
        Effect = "Allow"
        Action = [
          "ec2messages:SendCommand",
          "ec2messages:GetEndpoint",
          "ec2messages:CreateControlChannel",
          "ec2messages:CreateDataChannel",
          "ec2messages:OpenControlChannel",
          "ec2messages:OpenDataChannel"
        ]
        Resource = "*"
      }
    ]
  })
}