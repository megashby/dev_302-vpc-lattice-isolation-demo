module "ecs_vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.0"

  name = "${local.name}-ecs-vpc"
  cidr = "10.50.0.0/16"

  azs = [
    "us-east-1a",
    "us-east-1b",
    "us-east-1c"
  ]

  private_subnets = [
    "10.50.1.0/24",
    "10.50.2.0/24",
    "10.50.3.0/24"
  ]

  public_subnets = [
    "10.50.101.0/24",
    "10.50.102.0/24",
    "10.50.103.0/24"
  ]

  enable_nat_gateway = false
  single_nat_gateway = false

  enable_dns_hostnames = true
  enable_dns_support   = true
}

module "service_vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.0"

  name = "${local.name}-service-vpc"
  cidr = "10.60.0.0/16"

  azs = [
    "us-east-1a",
    "us-east-1b",
    "us-east-1c"
  ]

  private_subnets = [
    "10.60.1.0/24",
    "10.60.2.0/24",
    "10.60.3.0/24"
  ]

  public_subnets = [
    "10.60.101.0/24",
    "10.60.102.0/24",
    "10.60.103.0/24"
  ]

  # Keep identical behavior for consistency
  enable_nat_gateway = false
  single_nat_gateway = false

  enable_dns_hostnames = true
  enable_dns_support   = true
}