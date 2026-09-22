resource "aws_ecs_cluster" "main" {
  name = "expertlisting"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}
