# module "client_a" {
#   source  = "terraform-aws-modules/lambda/aws"
#   version = "~> 7.0"

#   function_name = "${local.name}-client-a"
#   handler       = "index.handler"
#   runtime       = "nodejs20.x"

#   source_path = "../src/lambda/client"

#   # role_arn = module.lambda_role.iam_role_arn

#   environment_variables = {
#     LATTICE_URL = aws_vpclattice_service.proxy.dns_entry[0].domain_name
#   }
# }

# module "client_b" {
#   source  = "terraform-aws-modules/lambda/aws"
#   version = "~> 7.0"

#   function_name = "${local.name}-client-b"
#   handler       = "index.handler"
#   runtime       = "nodejs20.x"

#   source_path = "../src/lambda/client"

#   #role_arn = module.lambda_role.iam_role_arn

#   environment_variables = {
#     LATTICE_URL = aws_vpclattice_service.proxy.dns_entry[0].domain_name
#   }
# }

module "isolate_admin" {
  source  = "terraform-aws-modules/lambda/aws"
  version = "~> 7.0"

  function_name = "${local.name}-isolate-admin"
  create_package = false
  package_type = "Image"

  architectures = ["x86_64"]

  image_uri = "${aws_ecr_repository.isolate_admin_lambda.repository_url}:latest"

  environment_variables = {
    LISTENER_ID       = aws_vpclattice_listener.orders_api.listener_id
    SERVICE_ID        = aws_vpclattice_service.orders_api.id
    RULE_ID           = aws_vpclattice_listener_rule.admin_route.rule_id
    MAINTENANCE_TG_ARN = aws_vpclattice_target_group.maintenance.arn
  }

  policy_statements = {
    "AllowUpdateListenerRule" = {
      Effect   = "Allow"
      Action   = ["vpc-lattice-svcs:UpdateListenerRule", "vpc-lattice:UpdateRule"]
      Resource = "*"
    }
  }
}

resource "aws_ecr_repository" "isolate_admin_lambda" {
  name = "${local.name}-isolate-admin"
}

resource "null_resource" "build_and_push_isolate_admin" {

  triggers = {
    index = filemd5("../src/lambda/isolate-admin/index.py")
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