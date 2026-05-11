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

resource "aws_security_group" "vpce" {
  name   = "${local.name}-vpce"
  vpc_id = module.service_vpc.vpc_id

  ingress {
    from_port = 443
    to_port   = 443
    protocol  = "tcp"

    cidr_blocks = [module.service_vpc.vpc_cidr_block]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

module "service_vpc_endpoints" {
  source  = "terraform-aws-modules/vpc/aws//modules/vpc-endpoints"
  version = "~> 6.0"

  vpc_id = module.service_vpc.vpc_id

  create_security_group = false

  endpoints = {
    ecr_api = {
      service             = "ecr.api"
      subnet_ids          = module.service_vpc.private_subnets
      security_group_ids  = [aws_security_group.vpce.id]
      private_dns_enabled = true
    }

    ecr_dkr = {
      service             = "ecr.dkr"
      subnet_ids          = module.service_vpc.private_subnets
      security_group_ids  = [aws_security_group.vpce.id]
      private_dns_enabled = true
    }

    logs = {
      service             = "logs"
      subnet_ids          = module.service_vpc.private_subnets
      security_group_ids  = [aws_security_group.vpce.id]
      private_dns_enabled = true
    }

    sts = {
      service             = "sts"
      subnet_ids          = module.service_vpc.private_subnets
      security_group_ids  = [aws_security_group.vpce.id]
      private_dns_enabled = true
    }

    s3 = {
      service         = "s3"
      service_type    = "Gateway"
      route_table_ids = module.service_vpc.private_route_table_ids
    }
  }
}