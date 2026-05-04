resource "aws_vpclattice_service_network" "this" {
  name = "${local.name}-network"
}

resource "aws_vpclattice_service_network_vpc_association" "ecs_vpc" {
  vpc_identifier             = module.ecs_vpc.vpc_id
  service_network_identifier = aws_vpclattice_service_network.this.id
}

resource "aws_vpclattice_service_network_vpc_association" "service_vpc" {
  vpc_identifier             = module.service_vpc.vpc_id
  service_network_identifier = aws_vpclattice_service_network.this.id
}

resource "aws_vpclattice_service" "backend" {
  name = "${local.name}-backend-service"
}

