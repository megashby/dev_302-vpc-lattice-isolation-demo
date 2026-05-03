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
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = module.ecs_execution_role.arn
  task_role_arn            = module.ecs_task_role.arn

  container_definitions = jsonencode([
    {
      name  = "client"
      image = "public.ecr.aws/docker/library/node:18"

      command = ["node", "-e", <<EOF
const https = require('https');
setInterval(() => {
  https.get('https://${aws_vpclattice_service.backend.dns_entry[0].domain_name}', res => {
    console.log("client-a status:", res.statusCode);
  }).on('error', e => console.error(e.message));
}, 5000);
EOF
      ]

      essential = true
    }
  ])
}

resource "aws_ecs_task_definition" "client_b" {
  family                   = "client-b"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = module.ecs_execution_role.arn
  task_role_arn            = module.ecs_task_role.arn

  container_definitions = jsonencode([
    {
      name  = "client"
      image = "public.ecr.aws/docker/library/node:18"

      command = ["node", "-e", <<EOF
const https = require('https');
setInterval(() => {
  https.get('https://${aws_vpclattice_service.backend.dns_entry[0].domain_name}', res => {
    console.log("client-b status:", res.statusCode);
  }).on('error', e => console.error(e.message));
}, 5000);
EOF
      ]

      essential = true
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
