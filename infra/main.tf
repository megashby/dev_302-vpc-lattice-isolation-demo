terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "6.42.0"
    }
  }

  backend "s3" {
    bucket = "terraform-state-jt56iy"
    key    = "nyc-summit-vpc-lattice/terraform.tfstate"
    region = "us-east-1"
  }
}
