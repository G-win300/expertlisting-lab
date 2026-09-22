locals {
  name = "expertlisting-${var.env}"
}

# ---------------------------------------------------------------- logs
resource "aws_cloudwatch_log_group" "api" {
  name              = "/ecs/${local.name}-api"
  retention_in_days = var.log_retention_days
}

resource "aws_cloudwatch_log_group" "web" {
  name              = "/ecs/${local.name}-web"
  retention_in_days = var.log_retention_days
}

# ---------------------------------------------------------------- IAM
data "aws_iam_policy_document" "ecs_tasks_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

# Execution role: used by the ECS agent to pull images, write logs and fetch secrets.
resource "aws_iam_role" "execution" {
  name               = "${local.name}-exec"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

resource "aws_iam_role_policy_attachment" "execution" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy" "execution_secrets" {
  name = "read-db-secret"
  role = aws_iam_role.execution.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = var.db_secret_arn
    }]
  })
}

# Task role: what the application code itself may call. Empty for now;
# this is where S3 access for listing photos would go.
resource "aws_iam_role" "task" {
  name               = "${local.name}-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

# ---------------------------------------------------------------- networking
resource "aws_security_group" "tasks" {
  name        = "${local.name}-tasks"
  description = "ECS tasks for ${var.env}; only the ALB may connect in"
  vpc_id      = var.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "api_from_alb" {
  security_group_id            = aws_security_group.tasks.id
  referenced_security_group_id = var.alb_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = 3000
  to_port                      = 3000
  description                  = "api from ALB"
}

resource "aws_vpc_security_group_ingress_rule" "web_from_alb" {
  security_group_id            = aws_security_group.tasks.id
  referenced_security_group_id = var.alb_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = 80
  to_port                      = 80
  description                  = "web from ALB"
}

resource "aws_vpc_security_group_egress_rule" "tasks_all" {
  security_group_id = aws_security_group.tasks.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "ECR, Secrets Manager, CloudWatch, RDS"
}

# ---------------------------------------------------------------- load balancing
resource "aws_lb_target_group" "api" {
  name                 = "${local.name}-api"
  port                 = 3000
  protocol             = "HTTP"
  target_type          = "ip"
  vpc_id               = var.vpc_id
  deregistration_delay = 30

  health_check {
    path                = "/api/health"
    matcher             = "200"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

resource "aws_lb_target_group" "web" {
  name                 = "${local.name}-web"
  port                 = 80
  protocol             = "HTTP"
  target_type          = "ip"
  vpc_id               = var.vpc_id
  deregistration_delay = 30

  health_check {
    path                = "/"
    matcher             = "200"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

# host = this env AND path = /api/*  ->  api
resource "aws_lb_listener_rule" "api" {
  listener_arn = var.alb_listener_arn
  priority     = var.listener_priority

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.api.arn
  }

  condition {
    host_header {
      values = [var.hostname]
    }
  }

  condition {
    path_pattern {
      values = ["/api/*"]
    }
  }
}

# host = this env (everything else)  ->  web
resource "aws_lb_listener_rule" "web" {
  listener_arn = var.alb_listener_arn
  priority     = var.listener_priority + 1

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.web.arn
  }

  condition {
    host_header {
      values = [var.hostname]
    }
  }
}

# ---------------------------------------------------------------- task definitions
# Terraform owns the shape; CI swaps the image on every deploy (see scripts/ecs-deploy.sh).
resource "aws_ecs_task_definition" "api" {
  family                   = "${local.name}-api"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([{
    name        = "api"
    image       = "${var.api_repository_url}:${var.initial_image_tag}"
    essential   = true
    stopTimeout = 30
    portMappings = [{
      containerPort = 3000
      protocol      = "tcp"
    }]
    environment = [
      { name = "PORT", value = "3000" },
      { name = "DB_HOST", value = var.db_host },
      { name = "DB_PORT", value = "5432" },
      { name = "DB_NAME", value = var.db_name },
      { name = "SERVED_BY", value = "ecs-${var.env}" },
      { name = "ENABLE_BURN", value = tostring(var.enable_burn) },
    ]
    # Injected at task start from the RDS-managed secret; never stored in the image or repo.
    secrets = [
      { name = "DB_USER", valueFrom = "${var.db_secret_arn}:username::" },
      { name = "DB_PASSWORD", valueFrom = "${var.db_secret_arn}:password::" },
    ]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.api.name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "api"
      }
    }
  }])
}

resource "aws_ecs_task_definition" "web" {
  family                   = "${local.name}-web"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([{
    name      = "web"
    image     = "${var.web_repository_url}:${var.initial_image_tag}"
    essential = true
    portMappings = [{
      containerPort = 80
      protocol      = "tcp"
    }]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.web.name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "web"
      }
    }
  }])
}

# ---------------------------------------------------------------- services
resource "aws_ecs_service" "api" {
  name                               = "${local.name}-api"
  cluster                            = var.cluster_id
  task_definition                    = aws_ecs_task_definition.api.arn
  desired_count                      = var.api_min_count
  launch_type                        = "FARGATE"
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200
  health_check_grace_period_seconds  = 30

  # Roll back automatically if new tasks keep failing health checks.
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  network_configuration {
    subnets          = var.subnet_ids
    security_groups  = [aws_security_group.tasks.id]
    assign_public_ip = true # LAB SHORTCUT: public subnets instead of private + NAT
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.api.arn
    container_name   = "api"
    container_port   = 3000
  }

  lifecycle {
    # CI owns the running revision; autoscaling owns the count.
    ignore_changes = [task_definition, desired_count]
  }

  depends_on = [aws_lb_listener_rule.api]
}

resource "aws_ecs_service" "web" {
  name                               = "${local.name}-web"
  cluster                            = var.cluster_id
  task_definition                    = aws_ecs_task_definition.web.arn
  desired_count                      = var.web_count
  launch_type                        = "FARGATE"
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200
  health_check_grace_period_seconds  = 30

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  network_configuration {
    subnets          = var.subnet_ids
    security_groups  = [aws_security_group.tasks.id]
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.web.arn
    container_name   = "web"
    container_port   = 80
  }

  lifecycle {
    ignore_changes = [task_definition]
  }

  depends_on = [aws_lb_listener_rule.web]
}

# ---------------------------------------------------------------- autoscaling (api)
resource "aws_appautoscaling_target" "api" {
  service_namespace  = "ecs"
  resource_id        = "service/${var.cluster_name}/${aws_ecs_service.api.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  min_capacity       = var.api_min_count
  max_capacity       = var.api_max_count
}

resource "aws_appautoscaling_policy" "api_cpu" {
  name               = "${local.name}-api-cpu"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.api.service_namespace
  resource_id        = aws_appautoscaling_target.api.resource_id
  scalable_dimension = aws_appautoscaling_target.api.scalable_dimension

  target_tracking_scaling_policy_configuration {
    target_value       = 60
    scale_out_cooldown = 60
    scale_in_cooldown  = 120

    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
  }
}
