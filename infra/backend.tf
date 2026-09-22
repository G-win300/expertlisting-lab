# Remote state in S3 with native locking. Backend blocks can't use variables,
# so edit bucket and region here (Phase 5 of the guide).
terraform {
  backend "s3" {
    bucket       = "REPLACE-ME-expertlisting-tfstate"
    key          = "expertlisting-lab/terraform.tfstate"
    region       = "eu-west-1"
    encrypt      = true
    use_lockfile = true
  }
}
