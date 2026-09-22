# LAB SHORTCUT: reuse the default VPC, which is where the "existing" server and
# database already live. Production would use a dedicated VPC with private subnets.
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }

  filter {
    name   = "default-for-az"
    values = ["true"]
  }
}

data "aws_caller_identity" "current" {}
