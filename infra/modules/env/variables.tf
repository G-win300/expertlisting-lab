variable "env" {
  description = "Environment name, e.g. staging or prod."
  type        = string
}

variable "hostname" {
  description = "Public hostname routed to this environment, e.g. app.lab.example.com."
  type        = string
}

variable "aws_region" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "subnet_ids" {
  type = list(string)
}

variable "cluster_id" {
  type = string
}

variable "cluster_name" {
  type = string
}

variable "alb_listener_arn" {
  description = "HTTPS listener to attach host/path rules to."
  type        = string
}

variable "alb_security_group_id" {
  type = string
}

variable "listener_priority" {
  description = "Base priority for this environment's listener rules (uses this and this+1)."
  type        = number
}

variable "api_repository_url" {
  type = string
}

variable "web_repository_url" {
  type = string
}

variable "initial_image_tag" {
  description = "Image tag Terraform puts in task definitions. CI replaces it on every deploy."
  type        = string
  default     = "initial"
}

variable "db_host" {
  type = string
}

variable "db_name" {
  type = string
}

variable "db_secret_arn" {
  description = "ARN of the RDS-managed secret holding username/password."
  type        = string
}

variable "api_min_count" {
  type = number
}

variable "api_max_count" {
  type = number
}

variable "web_count" {
  type = number
}

variable "enable_burn" {
  description = "Expose /api/burn for the autoscaling exercise. Never in prod."
  type        = bool
  default     = false
}

variable "log_retention_days" {
  type    = number
  default = 14
}
