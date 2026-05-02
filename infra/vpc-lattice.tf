locals {
    name = "demo-lattice"
}

resource "aws_vpclattice_service_network" "this" {
  name = "${local.name}-network"
}

resource "aws_vpclattice_service" "backend" {
  name = "${local.name}-backend-service"
}