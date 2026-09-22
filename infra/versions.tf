terraform {
  required_version = ">= 1.10.0" # needed for S3-native state locking (use_lockfile)

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.80"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = "expertlisting-lab"
      ManagedBy = "terraform"
    }
  }
}
