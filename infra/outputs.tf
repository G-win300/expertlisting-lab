output "alb_dns_name" {
  value = aws_lb.main.dns_name
}

output "ecr_repositories" {
  value = { for k, r in aws_ecr_repository.app : k => r.repository_url }
}

output "github_deploy_role_arn" {
  value = aws_iam_role.gha_deploy.arn
}

output "github_terraform_role_arn" {
  value = aws_iam_role.gha_terraform.arn
}
