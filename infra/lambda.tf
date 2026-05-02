module "client_a" {
  source  = "terraform-aws-modules/lambda/aws"
  version = "~> 7.0"

  function_name = "${local.name}-client-a"
  handler       = "index.handler"
  runtime       = "nodejs20.x"

  source_path = "../src/lambda/client"

 # role_arn = module.lambda_role.iam_role_arn

  environment_variables = {
    LATTICE_URL = aws_vpclattice_service.backend.dns_entry[0].domain_name
  }
}

module "client_b" {
  source  = "terraform-aws-modules/lambda/aws"
  version = "~> 7.0"

  function_name = "${local.name}-client-b"
  handler       = "index.handler"
  runtime       = "nodejs20.x"

  source_path = "../src/lambda/client"

  #role_arn = module.lambda_role.iam_role_arn

  environment_variables = {
    LATTICE_URL = aws_vpclattice_service.backend.dns_entry[0].domain_name
  }
}