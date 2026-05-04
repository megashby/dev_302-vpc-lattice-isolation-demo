resource "aws_security_group" "rds" {
  name   = "${local.name}-rds"
  vpc_id = module.service_vpc.vpc_id

  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.ecs_proxy.id]
  }
}

module "rds" {
  source  = "terraform-aws-modules/rds/aws"
  version = "~> 6.0"

  identifier = "${local.name}-db"

  engine            = "postgres"
  engine_version    = "15"
  instance_class    = "db.t3.micro"
  family            = "postgres15"
  allocated_storage = 20

  db_name  = "demo"
  username = "dbadmin" # still required for initial setup
  port     = 5432

  vpc_security_group_ids = [aws_security_group.rds.id]

  create_db_subnet_group = true
  subnet_ids             = module.service_vpc.private_subnets

  publicly_accessible = false
  skip_final_snapshot = true
  deletion_protection = false

  apply_immediately = true

  enabled_cloudwatch_logs_exports = ["postgresql"]
  create_cloudwatch_log_group     = true

  backup_retention_period = 0

  iam_database_authentication_enabled = true
}