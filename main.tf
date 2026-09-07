terraform {
  # 1.11+ for native S3 state locking (use_lockfile); DynamoDB args are deprecated.
  required_version = ">= 1.16"

  backend "s3" {
    bucket       = "superflux-terraform-state"
    key          = "hermes.tfstate"
    region       = "ca-west-1"
    encrypt      = true
    use_lockfile = true
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.63"
    }
  }
}

provider "aws" {
  region = "ca-west-1"

  default_tags {
    tags = {
      Project   = "hermes"
      ManagedBy = "terraform"
    }
  }
}

# Default VPC + its public subnets. Default subnets already auto-assign public IPs,
# which is what we want: public subnet, zero ingress. See plan "Why public subnet".
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# Ubuntu Server 24.04 arm64, gp3-backed, published by Canonical.
data "aws_ssm_parameter" "ubuntu_2404_arm64" {
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/arm64/hvm/ebs-gp3/ami-id"
}

data "aws_region" "current" {}
