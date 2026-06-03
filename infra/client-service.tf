module "ecs_cluster" {
  source  = "terraform-aws-modules/ecs/aws"
  version = "~> 6.0"

  cluster_name = "${local.name}-cluster"
}

module "ecs_execution_role" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role"
  version = "~> 6.0"

  name            = "${local.name}-ecs-exec-role"
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

  policies = { "TaskExecution" = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy" }

}

module "ecs_task_role_client_a" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role"
  version = "~> 6.0"

  name            = "${local.name}-ecs-task-role-client-a"
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
        },
        {
          type        = "AWS"
          identifiers = [module.ecs_task_role_dashboard.arn]
        }
      ]
    }
  }

  policies = {
    "TaskExecution" = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
    "ecs_exec"      = aws_iam_policy.ecs_exec.arn
  "vpc_lattice_invoke" = aws_iam_policy.vpc_lattice_invoke.arn }
}

module "ecs_task_role_client_b" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role"
  version = "~> 6.0"

  name            = "${local.name}-ecs-task-role-client-b"
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
        },
        {
          type        = "AWS"
          identifiers = [module.ecs_task_role_dashboard.arn]
        }
      ]
    }
  }

  policies = {
    "TaskExecution" = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
    "ecs_exec"      = aws_iam_policy.ecs_exec.arn
  "vpc_lattice_invoke" = aws_iam_policy.vpc_lattice_invoke.arn }

}

resource "aws_security_group" "clients_ecs" {
  name   = "${local.name}-clients-ecs"
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

resource "aws_ecs_task_definition" "client_a" {
  family                   = "client-a"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"

  cpu    = 256
  memory = 512

  execution_role_arn = module.ecs_execution_role.arn
  task_role_arn      = module.ecs_task_role_client_a.arn

  container_definitions = jsonencode([
    {
      name  = "client"
      image = "${aws_ecr_repository.client.repository_url}:latest"

      essential = true

      environment = [
        {
          name  = "LATTICE_ENDPOINT"
          value = aws_vpclattice_service.orders_api.dns_entry[0].domain_name
        },
        {
          name  = "CLIENT_NAME"
          value = "client-a"
        }
      ]

      logConfiguration = {
        logDriver = "awslogs"

        options = {
          awslogs-group         = aws_cloudwatch_log_group.client_a.name
          awslogs-region        = "us-east-1"
          awslogs-stream-prefix = "ecs"
        }
      }
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
  task_role_arn      = module.ecs_task_role_client_b.arn

  container_definitions = jsonencode([
    {
      name  = "client"
      image = "${aws_ecr_repository.client.repository_url}:latest"

      essential = true

      environment = [
        {
          name  = "LATTICE_ENDPOINT"
          value = aws_vpclattice_service.orders_api.dns_entry[0].domain_name
        },
        {
          name  = "CLIENT_NAME"
          value = "client-b"
        }
      ]

      # command = ["node", "-e", file("../src/ecs/client/client.js")]

      logConfiguration = {
        logDriver = "awslogs"

        options = {
          awslogs-group         = aws_cloudwatch_log_group.client_b.name
          awslogs-region        = "us-east-1"
          awslogs-stream-prefix = "ecs"
        }
      }
    }
  ])
}

resource "aws_ecs_service" "client_a" {
  name            = "client-a"
  cluster         = module.ecs_cluster.cluster_id
  task_definition = aws_ecs_task_definition.client_a.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  enable_execute_command = true

  network_configuration {
    subnets          = module.ecs_vpc.private_subnets
    security_groups  = [aws_security_group.clients_ecs.id]
    assign_public_ip = false
  }
}

resource "aws_ecs_service" "client_b" {
  name            = "client-b"
  cluster         = module.ecs_cluster.cluster_id
  task_definition = aws_ecs_task_definition.client_b.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  enable_execute_command = true

  network_configuration {
    subnets          = module.ecs_vpc.private_subnets
    security_groups  = [aws_security_group.clients_ecs.id]
    assign_public_ip = false
  }
}


resource "aws_iam_role_policy_attachment" "ecs_exec" {
  role       = module.ecs_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_policy" "ecs_exec" {
  name        = "ecs-exec"
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

resource "aws_iam_policy" "vpc_lattice_invoke" {
  name        = "vpc_lattice_invoke"
  description = "Allow Invoking VPC Lattice Services"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ECSExecSSMMessages"
        Effect = "Allow"
        Action = [
          "vpc-lattice-svcs:Invoke"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_cloudwatch_log_group" "client_a" {
  name = "/ecs/demo-lattice-client-a"
}

resource "aws_cloudwatch_log_group" "client_b" {
  name = "/ecs/demo-lattice-client-b"
}

resource "aws_ecr_repository" "client" {
  name = "${local.name}-client"
}

resource "null_resource" "build_and_push_client" {

  triggers = {
    client     = filemd5("../src/ecs/client/client.js")
    dockerfile = filemd5("../src/ecs/client/Dockerfile")
    package    = filemd5("../src/ecs/client/package.json")
  }

  provisioner "local-exec" {
    command = <<EOT
      aws ecr get-login-password --region us-east-1 \
      | docker login --username AWS --password-stdin ${aws_ecr_repository.client.repository_url}

      docker build --platform linux/amd64 -t client ../src/ecs/client
      docker tag client:latest ${aws_ecr_repository.client.repository_url}:latest
      docker push ${aws_ecr_repository.client.repository_url}:latest
    EOT
  }
}