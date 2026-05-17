resource "aws_ecs_task_definition" "db_init" {
  family                   = "${local.name}-db-init"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"

  cpu    = 256
  memory = 512

  execution_role_arn = module.db_proxy_ecs_execution_role.arn
  task_role_arn      = module.db_proxy_ecs_task_role.arn

  container_definitions = jsonencode([
    {
      name      = "db-init"
      image     = "postgres:15"
      essential = true

      command = [
        "sh",
        "-c",
        <<-EOT
psql \
  -h ${module.rds.db_instance_address} \
  -U dbadmin \
  -d demo <<'SQL'

CREATE USER proxy_user WITH LOGIN;
GRANT rds_iam TO proxy_user;
GRANT CONNECT ON DATABASE demo TO proxy_user;

SQL
EOT
      ]

      environment = [
        {
          name  = "PGPASSWORD"
          value = var.db_password
        }
      ]

      logConfiguration = {
        logDriver = "awslogs"

        options = {
          awslogs-group         = "/ecs/${local.name}-db-init"
          awslogs-region        = "us-east-1"
          awslogs-stream-prefix = "ecs"
        }
      }
    }
  ])
}

resource "null_resource" "ecs_run_task" {
  count = var.run_init_task ? 1 : 0

  triggers = {
    always_run = timestamp()
  }

  provisioner "local-exec" {
    command = <<EOT
aws ecs run-task \
  --cluster demo-lattice-db-proxy-cluster \
  --launch-type FARGATE \
  --task-definition demo-lattice-db-init \
  --network-configuration "awsvpcConfiguration={subnets=[subnet-04bd8d4ea996684ac],securityGroups=[sg-08252f2166ef27ad8],assignPublicIp=DISABLED}"
EOT
  }
}

resource "aws_cloudwatch_log_group" "init" {
  name              = "/ecs/demo-lattice-db-init"
  retention_in_days = 7
}