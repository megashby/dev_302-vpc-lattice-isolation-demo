locals {
  isolation_router_image_tag = substr(sha256(join("", [
    filesha256("../src/lambda/isolation-router/index.py"),
    filesha256("../src/lambda/isolation-router/Dockerfile")
  ])), 0, 16)

  apply_auth_image_tag = substr(sha256(join("", [
    filesha256("../src/lambda/apply-auth/index.py"),
    filesha256("../src/lambda/apply-auth/Dockerfile")
  ])), 0, 16)

  isolate_admin_image_tag = substr(sha256(join("", [
    filesha256("../src/lambda/isolate-admin/index.py"),
    filesha256("../src/lambda/isolate-admin/Dockerfile")
  ])), 0, 16)
}

resource "aws_ecr_repository" "isolate_admin_lambda" {
  name = "${local.name}-isolate-admin"
}

resource "null_resource" "build_and_push_isolate_admin" {
  triggers = {
    image_tag = local.isolate_admin_image_tag
  }

  provisioner "local-exec" {
    command = <<EOT
      aws ecr get-login-password --region us-east-1 \
      | docker login --username AWS --password-stdin ${aws_ecr_repository.isolate_admin_lambda.repository_url}

      docker build --platform linux/amd64 --provenance=false \
        -t ${aws_ecr_repository.isolate_admin_lambda.repository_url}:${local.isolate_admin_image_tag} \
        ../src/lambda/isolate-admin

      docker push ${aws_ecr_repository.isolate_admin_lambda.repository_url}:${local.isolate_admin_image_tag}
    EOT
  }
}

module "isolate_admin" {
  source  = "terraform-aws-modules/lambda/aws"
  version = "~> 7.0"

  function_name  = "${local.name}-isolate-admin"
  create_package = false
  package_type   = "Image"

  architectures = ["x86_64"]
  image_uri     = "${aws_ecr_repository.isolate_admin_lambda.repository_url}:${local.isolate_admin_image_tag}"

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
      effect = "Allow"
      actions = [
        "ecs:ListTasks",
        "ecs:DescribeTasks",
        "ec2:DescribeNetworkInterfaces",
        "ec2:DescribeVpcs",
        "ec2:DescribeSubnets",
        "vpc-lattice:UpdateRule",
        "vpc-lattice:GetRule"
      ]
      resources = ["*"]
    }

    lattice_targets = {
      effect = "Allow"
      actions = [
        "vpc-lattice:RegisterTargets",
        "vpc-lattice:ListTargets",
        "vpc-lattice:DeregisterTargets",
        "vpc-lattice:GetTargetGroup"
      ]
      resources = ["*"]
    }
  }

  create_current_version_allowed_triggers = false

  depends_on = [
    null_resource.build_and_push_isolate_admin
  ]
}

resource "aws_ecr_repository" "isolation_router_lambda" {
  name = "${local.name}-isolation-router"
}

resource "null_resource" "build_and_push_isolation_router" {
  triggers = {
    image_tag = local.isolation_router_image_tag
  }

  provisioner "local-exec" {
    command = <<EOT
      aws ecr get-login-password --region us-east-1 \
      | docker login --username AWS --password-stdin ${aws_ecr_repository.isolation_router_lambda.repository_url}

      docker build --platform linux/amd64 --provenance=false \
        -t ${aws_ecr_repository.isolation_router_lambda.repository_url}:${local.isolation_router_image_tag} \
        ../src/lambda/isolation-router

      docker push ${aws_ecr_repository.isolation_router_lambda.repository_url}:${local.isolation_router_image_tag}
    EOT
  }
}

module "isolation_router" {
  source  = "terraform-aws-modules/lambda/aws"
  version = "~> 7.0"

  function_name  = "${local.name}-isolation-router"
  create_package = false
  package_type   = "Image"

  architectures = ["x86_64"]
  image_uri     = "${aws_ecr_repository.isolation_router_lambda.repository_url}:${local.isolation_router_image_tag}"

  timeout = 60

  attach_policy_statements = false

  create_current_version_allowed_triggers = false

  depends_on = [
    null_resource.build_and_push_isolation_router
  ]
}

resource "aws_ecr_repository" "apply_auth_lambda" {
  name = "${local.name}-apply-auth"
}

resource "null_resource" "build_and_push_apply_auth" {
  triggers = {
    image_tag = local.apply_auth_image_tag
  }

  provisioner "local-exec" {
    command = <<EOT
      aws ecr get-login-password --region us-east-1 \
      | docker login --username AWS --password-stdin ${aws_ecr_repository.apply_auth_lambda.repository_url}

      docker build --platform linux/amd64 --provenance=false \
        -t ${aws_ecr_repository.apply_auth_lambda.repository_url}:${local.apply_auth_image_tag} \
        ../src/lambda/apply-auth

      docker push ${aws_ecr_repository.apply_auth_lambda.repository_url}:${local.apply_auth_image_tag}
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
  image_uri     = "${aws_ecr_repository.apply_auth_lambda.repository_url}:${local.apply_auth_image_tag}"

  timeout = 60

  environment_variables = {
    SERVICE_ARN = aws_vpclattice_service.orders_api.arn
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

  depends_on = [
    null_resource.build_and_push_apply_auth
  ]
}