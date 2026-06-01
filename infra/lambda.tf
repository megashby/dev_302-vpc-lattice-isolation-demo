module "isolate_admin" {
  source  = "terraform-aws-modules/lambda/aws"
  version = "~> 7.0"

  function_name  = "${local.name}-isolate-admin"
  create_package = false
  package_type   = "Image"

  architectures = ["x86_64"]

  image_uri = "${aws_ecr_repository.isolate_admin_lambda.repository_url}:latest"

  timeout = 180

  environment_variables = {
    LISTENER_ID       = aws_vpclattice_listener.orders_api.listener_id
    SERVICE_ID        = aws_vpclattice_service.orders_api.id
    RULE_ID           = aws_vpclattice_listener_rule.admin_route.rule_id
    MAINTENANCE_TG_ID = aws_vpclattice_target_group.maintenance.id
    CLUSTER_NAME      = module.ecs_cluster.cluster_name
    SERVICE_NAME      = aws_ecs_service.orders_api.name
  }

  attach_policy_statements = true

  policy_statements = {
    updatelistener = {
      effect = "Allow",
      actions = [
        "ecs:ListTasks",
        "ecs:DescribeTasks",
        "ec2:DescribeNetworkInterfaces",
        "ec2:DescribeVpcs",
        "ec2:DescribeSubnets",
        "vpc-lattice:UpdateRule",
        "vpc-lattice:GetRule"
      ],
      resources = ["*"]
    }

    lattice_targets = {
      effect = "Allow",
      actions = [
        "vpc-lattice:RegisterTargets",
        "vpc-lattice:ListTargets",
        "vpc-lattice:DeregisterTargets",
        "vpc-lattice:GetTargetGroup"
      ],
      resources = ["*"]
    }
  }

  create_current_version_allowed_triggers = false

  allowed_triggers = {
    eventbridge = {
      source_arn = aws_cloudwatch_event_rule.isolate_admin.arn
      service    = "events"
    }
  }
}

resource "aws_ecr_repository" "isolate_admin_lambda" {
  name = "${local.name}-isolate-admin"
}

resource "null_resource" "build_and_push_isolate_admin" {

  triggers = {
    index      = filemd5("../src/lambda/isolate-admin/index.py")
    dockerfile = filemd5("../src/lambda/isolate-admin/Dockerfile")
  }

  provisioner "local-exec" {
    command = <<EOT
      aws ecr get-login-password --region us-east-1 \
      | docker login --username AWS --password-stdin ${aws_ecr_repository.isolate_admin_lambda.repository_url}

      docker build --platform linux/amd64 --provenance=false -t isolate-admin ../src/lambda/isolate-admin
      docker tag isolate-admin:latest ${aws_ecr_repository.isolate_admin_lambda.repository_url}:latest
      docker push ${aws_ecr_repository.isolate_admin_lambda.repository_url}:latest
    EOT
  }
}

module "apply_auth" {
  source  = "terraform-aws-modules/lambda/aws"
  version = "~> 7.0"

  function_name  = "${local.name}-apply-auth"
  create_package = false
  package_type   = "Image"

  architectures = ["x86_64"]

  image_uri = "${aws_ecr_repository.apply_auth_lambda.repository_url}:latest"

  timeout = 60

  environment_variables = {
    SERVICE_ARN       = aws_vpclattice_service.orders_api.arn
    CLIENT_A_ROLE_ARN = module.ecs_task_role_client_a.arn
    CLIENT_B_ROLE_ARN = module.ecs_task_role_client_b.arn
  }

  attach_policy_statements = true

  policy_statements = {
    lattice_auth_policy = {
      effect = "Allow"
      actions = [
        "vpc-lattice:PutAuthPolicy",
        "vpc-lattice:GetAuthPolicy"
      ]
      resources = ["*"]
    }
  }

    create_current_version_allowed_triggers = false

  allowed_triggers = {
    eventbridge = {
      source_arn = aws_cloudwatch_event_rule.apply_auth.arn
      service    = "events"
    }
  }
}

resource "aws_ecr_repository" "apply_auth_lambda" {
  name = "${local.name}-apply-auth"
}

resource "null_resource" "build_and_push_apply_auth" {
  triggers = {
    index      = filemd5("../src/lambda/apply-auth/index.py")
    dockerfile = filemd5("../src/lambda/apply-auth/Dockerfile")
  }

  provisioner "local-exec" {
    command = <<EOT
      aws ecr get-login-password --region us-east-1 \
      | docker login --username AWS --password-stdin ${aws_ecr_repository.apply_auth_lambda.repository_url}

      docker build --platform linux/amd64 --provenance=false -t apply-auth ../src/lambda/apply-auth
      docker tag apply-auth:latest ${aws_ecr_repository.apply_auth_lambda.repository_url}:latest
      docker push ${aws_ecr_repository.apply_auth_lambda.repository_url}:latest
    EOT
  }
}