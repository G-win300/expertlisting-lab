variable "aws_region" {
  type    = string
  default = "eu-west-1"
}

variable "lab_domain" {
  description = "Delegated lab subdomain, e.g. lab.yourdomain.com."
  type        = string
}

variable "zone_id" {
  description = "Route 53 hosted zone ID for lab_domain (created in Phase 0)."
  type        = string
}

variable "github_repo" {
  description = "owner/name of the GitHub repo, exactly as GitHub spells it (case matters)."
  type        = string
}

variable "legacy_ip" {
  description = "Elastic IP of the legacy EC2 server."
  type        = string
}

variable "legacy_db_sg_id" {
  description = "Security group attached to the existing prod database (created by hand in Phase 2)."
  type        = string
}

variable "db_engine_version" {
  description = "Major Postgres version of the existing prod database, e.g. \"17\"."
  type        = string
}

variable "legacy_weight" {
  description = "Route 53 weight for the legacy server (0-255)."
  type        = number
  default     = 100
}

variable "ecs_weight" {
  description = "Route 53 weight for the ECS/ALB stack (0-255)."
  type        = number
  default     = 0
}

variable "initial_image_tag" {
  type    = string
  default = "initial"
}
