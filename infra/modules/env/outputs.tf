output "tasks_security_group_id" {
  value = aws_security_group.tasks.id
}

output "api_service_name" {
  value = aws_ecs_service.api.name
}

output "web_service_name" {
  value = aws_ecs_service.web.name
}
