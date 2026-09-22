# Staging gets its own small database, created by Terraform from day one.
resource "aws_db_subnet_group" "staging" {
  name       = "expertlisting-staging"
  subnet_ids = data.aws_subnets.default.ids
}

resource "aws_security_group" "staging_db" {
  name        = "expertlisting-staging-db"
  description = "Staging Postgres; only staging tasks may connect"
  vpc_id      = data.aws_vpc.default.id
}

resource "aws_vpc_security_group_ingress_rule" "staging_db_from_tasks" {
  security_group_id            = aws_security_group.staging_db.id
  referenced_security_group_id = module.staging.tasks_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
}

resource "aws_db_instance" "staging" {
  identifier                  = "expertlisting-staging-db"
  engine                      = "postgres"
  engine_version              = var.db_engine_version
  instance_class              = "db.t4g.micro"
  allocated_storage           = 20
  storage_type                = "gp3"
  storage_encrypted           = true
  db_name                     = "expertlisting"
  username                    = "app"
  manage_master_user_password = true
  db_subnet_group_name        = aws_db_subnet_group.staging.name
  vpc_security_group_ids      = [aws_security_group.staging_db.id]
  publicly_accessible         = false
  backup_retention_period     = 1
  skip_final_snapshot         = true
  deletion_protection         = false
}

module "staging" {
  source = "./modules/env"

  env                   = "staging"
  hostname              = "staging.${var.lab_domain}"
  aws_region            = var.aws_region
  vpc_id                = data.aws_vpc.default.id
  subnet_ids            = data.aws_subnets.default.ids
  cluster_id            = aws_ecs_cluster.main.id
  cluster_name          = aws_ecs_cluster.main.name
  alb_listener_arn      = aws_lb_listener.https.arn
  alb_security_group_id = aws_security_group.alb.id
  listener_priority     = 100
  api_repository_url    = aws_ecr_repository.app["api"].repository_url
  web_repository_url    = aws_ecr_repository.app["web"].repository_url
  initial_image_tag     = var.initial_image_tag
  db_host               = aws_db_instance.staging.address
  db_name               = aws_db_instance.staging.db_name
  db_secret_arn         = aws_db_instance.staging.master_user_secret[0].secret_arn
  api_min_count         = 1
  api_max_count         = 3
  web_count             = 1
  enable_burn           = true
}

resource "aws_route53_record" "staging" {
  zone_id = var.zone_id
  name    = "staging.${var.lab_domain}"
  type    = "A"

  alias {
    name                   = aws_lb.main.dns_name
    zone_id                = aws_lb.main.zone_id
    evaluate_target_health = true
  }
}
