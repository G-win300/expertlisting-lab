resource "aws_ecr_repository" "app" {
  for_each = toset(["api", "web"])

  name                 = "expertlisting/${each.key}"
  image_tag_mutability = "IMMUTABLE" # a SHA tag always means the same image
  force_delete         = true        # LAB: lets terraform destroy remove images

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_lifecycle_policy" "app" {
  for_each   = aws_ecr_repository.app
  repository = each.value.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep the last 30 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 30
      }
      action = { type = "expire" }
    }]
  })
}
