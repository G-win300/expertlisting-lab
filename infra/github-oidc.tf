# GitHub Actions authenticates to AWS with short-lived OIDC tokens. No access keys anywhere.
# If your account already has this provider (from another project), import it instead:
#   terraform import aws_iam_openid_connect_provider.github \
#     arn:aws:iam::<account-id>:oidc-provider/token.actions.githubusercontent.com
resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1", "1c58a3a8518e8759bf075b76b750d4f2df264fcd"]
}

locals {
  account_id = data.aws_caller_identity.current.account_id
}

# ---------------------------------------------------------------- deploy role (app pipeline)
data "aws_iam_policy_document" "gha_deploy_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Only: the build job on main, and jobs running in the staging/production environments.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:${var.github_repo}:ref:refs/heads/main",
        "repo:${var.github_repo}:environment:staging",
        "repo:${var.github_repo}:environment:production",
      ]
    }
  }
}

data "aws_iam_policy_document" "gha_deploy" {
  statement {
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:CompleteLayerUpload",
      "ecr:DescribeImages",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
    ]
    resources = [for r in aws_ecr_repository.app : r.arn]
  }

  statement {
    actions = [
      "ecs:DescribeServices",
      "ecs:DescribeTaskDefinition",
      "ecs:DescribeTasks",
      "ecs:RegisterTaskDefinition",
      "elasticloadbalancing:DescribeLoadBalancers",
    ]
    resources = ["*"]
  }

  statement {
    actions   = ["ecs:UpdateService"]
    resources = ["arn:aws:ecs:${var.aws_region}:${local.account_id}:service/${aws_ecs_cluster.main.name}/*"]
  }

  statement {
    actions   = ["ecs:RunTask"]
    resources = ["arn:aws:ecs:${var.aws_region}:${local.account_id}:task-definition/expertlisting-*"]
  }

  # Registering a task definition / running a task means handing its roles to ECS.
  statement {
    actions   = ["iam:PassRole"]
    resources = ["arn:aws:iam::${local.account_id}:role/expertlisting-*"]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "gha_deploy" {
  name               = "gha-expertlisting-deploy"
  assume_role_policy = data.aws_iam_policy_document.gha_deploy_trust.json
}

resource "aws_iam_role_policy" "gha_deploy" {
  name   = "deploy"
  role   = aws_iam_role.gha_deploy.id
  policy = data.aws_iam_policy_document.gha_deploy.json
}

# ---------------------------------------------------------------- terraform role (infra pipeline)
data "aws_iam_policy_document" "gha_terraform_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Plans run on pull requests; applies run in the approval-gated production environment.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:${var.github_repo}:pull_request",
        "repo:${var.github_repo}:environment:production",
      ]
    }
  }
}

resource "aws_iam_role" "gha_terraform" {
  name               = "gha-expertlisting-terraform"
  assume_role_policy = data.aws_iam_policy_document.gha_terraform_trust.json
}

# LAB SHORTCUT: admin for simplicity. In production, split plan (read-only) and apply roles
# and scope apply to the services this stack actually manages.
resource "aws_iam_role_policy_attachment" "gha_terraform" {
  role       = aws_iam_role.gha_terraform.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}
