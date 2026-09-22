# ---------------------------------------------------------------- existing prod database
# Created by hand in Phase 2, adopted by Terraform in Phase 5 (see imports.tf).
# This block must describe the real instance exactly, so the first plan changes nothing.
resource "aws_db_instance" "prod" {
  identifier                  = "expertlisting-prod-db"
  engine                      = "postgres"
  engine_version              = var.db_engine_version
  instance_class              = "db.t4g.micro"
  allocated_storage           = 20
  storage_type                = "gp3"
  storage_encrypted           = true
  db_name                     = "expertlisting"
  username                    = "app"
  manage_master_user_password = true
  db_subnet_group_name        = "legacy-db-subnets"
  vpc_security_group_ids      = [var.legacy_db_sg_id]
  publicly_accessible         = false
  backup_retention_period     = 7
  deletion_protection         = true
  skip_final_snapshot         = false
  final_snapshot_identifier   = "expertlisting-prod-db-final"

  lifecycle {
    prevent_destroy = true # a typo in Terraform must never delete production data
  }
}

# Let the new ECS prod tasks reach the existing database, alongside the legacy server.
resource "aws_vpc_security_group_ingress_rule" "prod_db_from_tasks" {
  security_group_id            = var.legacy_db_sg_id
  referenced_security_group_id = module.prod.tasks_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  description                  = "Postgres from ECS prod tasks"
}

# ---------------------------------------------------------------- new prod stack
module "prod" {
  source = "./modules/env"

  env                   = "prod"
  hostname              = "app.${var.lab_domain}"
  aws_region            = var.aws_region
  vpc_id                = data.aws_vpc.default.id
  subnet_ids            = data.aws_subnets.default.ids
  cluster_id            = aws_ecs_cluster.main.id
  cluster_name          = aws_ecs_cluster.main.name
  alb_listener_arn      = aws_lb_listener.https.arn
  alb_security_group_id = aws_security_group.alb.id
  listener_priority     = 200
  api_repository_url    = aws_ecr_repository.app["api"].repository_url
  web_repository_url    = aws_ecr_repository.app["web"].repository_url
  initial_image_tag     = var.initial_image_tag
  db_host               = aws_db_instance.prod.address
  db_name               = aws_db_instance.prod.db_name
  db_secret_arn         = aws_db_instance.prod.master_user_secret[0].secret_arn
  api_min_count         = 2
  api_max_count         = 6
  web_count             = 2
  enable_burn           = false
}

# ---------------------------------------------------------------- DNS cutover dial
# Two weighted records for the same name. Traffic share = weight / sum of weights.
resource "aws_route53_record" "prod_legacy" {
  zone_id        = var.zone_id
  name           = "app.${var.lab_domain}"
  type           = "A"
  ttl            = 60
  records        = [var.legacy_ip]
  set_identifier = "legacy"

  weighted_routing_policy {
    weight = var.legacy_weight
  }
}

resource "aws_route53_record" "prod_ecs" {
  zone_id        = var.zone_id
  name           = "app.${var.lab_domain}"
  type           = "A"
  set_identifier = "ecs"

  alias {
    name                   = aws_lb.main.dns_name
    zone_id                = aws_lb.main.zone_id
    evaluate_target_health = true # if the ALB has no healthy targets, Route 53 skips it
  }

  weighted_routing_policy {
    weight = var.ecs_weight
  }
}
