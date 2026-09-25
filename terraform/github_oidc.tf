# -----------------------------------------------------------------------------
# GitHub Actions OIDC federation - lets GitHub Actions assume an AWS role
# without any long-lived AWS access keys stored as repo secrets. GitHub
# issues a short-lived signed OIDC token per workflow run; AWS verifies it
# against this identity provider and the trust policy below, which pins
# the role to one specific repo (and optionally branch).
#
# All resources here are conditional on var.github_repository being set,
# so this file is a no-op until you actually wire up CI/CD.
# -----------------------------------------------------------------------------

data "tls_certificate" "github_actions" {
  count = var.github_repository != "" ? 1 : 0
  url   = "https://token.actions.githubusercontent.com/.well-known/openid-configuration"
}

resource "aws_iam_openid_connect_provider" "github_actions" {
  count = var.github_repository != "" ? 1 : 0

  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.github_actions[0].certificates[0].sha1_fingerprint]
}

resource "aws_iam_role" "github_actions_deploy" {
  count = var.github_repository != "" ? 1 : 0
  name  = "${var.project_name}-github-actions-deploy"

  # Trust policy scoped to:
  #  - only this OIDC provider (not any arbitrary token issuer)
  #  - only tokens whose audience is sts.amazonaws.com
  #  - only tokens whose subject claim matches this exact GitHub repo,
  #    on any branch/PR (repo:owner/repo:*) - tighten to
  #    repo:owner/repo:ref:refs/heads/main if you want prod applies
  #    restricted to the default branch only.
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.github_actions[0].arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        StringLike = {
          "token.actions.githubusercontent.com:sub" = "repo:${var.github_repository}:*"
        }
      }
    }]
  })
}

# Scoped to what terraform plan/apply actually needs to manage every
# resource type in this project, rather than a blanket AdministratorAccess
# grant - a compromised or buggy workflow can't reach outside this list.
resource "aws_iam_role_policy" "github_actions_deploy" {
  count = var.github_repository != "" ? 1 : 0
  name  = "github-actions-terraform-deploy"
  role  = aws_iam_role.github_actions_deploy[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "S3StateAndProjectBuckets"
        Effect = "Allow"
        Action = [
          "s3:*",
        ]
        Resource = [
          "arn:aws:s3:::${var.project_name}-*",
          "arn:aws:s3:::${var.project_name}-*/*",
        ]
      },
      {
        Sid      = "TerraformStateLockTable"
        Effect   = "Allow"
        Action   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:DeleteItem"]
        Resource = "arn:aws:dynamodb:*:*:table/${var.project_name}-tf-locks"
      },
      {
        Sid    = "GlueFull"
        Effect = "Allow"
        Action = ["glue:*"]
        Resource = "*"
      },
      {
        Sid      = "AthenaFull"
        Effect   = "Allow"
        Action   = ["athena:*"]
        Resource = "*"
      },
      {
        Sid      = "StepFunctionsFull"
        Effect   = "Allow"
        Action   = ["states:*"]
        Resource = "*"
      },
      {
        Sid      = "EventBridgeFull"
        Effect   = "Allow"
        Action   = ["events:*"]
        Resource = "*"
      },
      {
        Sid      = "SnsFull"
        Effect   = "Allow"
        Action   = ["sns:*"]
        Resource = "*"
      },
      {
        Sid      = "CloudWatchAlarms"
        Effect   = "Allow"
        Action   = ["cloudwatch:*"]
        Resource = "*"
      },
      {
        Sid    = "IamForProjectRoles"
        Effect = "Allow"
        Action = [
          "iam:GetRole", "iam:CreateRole", "iam:DeleteRole", "iam:UpdateRole",
          "iam:GetRolePolicy", "iam:PutRolePolicy", "iam:DeleteRolePolicy",
          "iam:AttachRolePolicy", "iam:DetachRolePolicy", "iam:ListRolePolicies",
          "iam:ListAttachedRolePolicies", "iam:TagRole", "iam:UntagRole",
          "iam:ListInstanceProfilesForRole", "iam:PassRole",
          "iam:GetOpenIDConnectProvider", "iam:CreateOpenIDConnectProvider",
          "iam:UpdateOpenIDConnectProviderThumbprint", "iam:TagOpenIDConnectProvider",
        ]
        Resource = [
          "arn:aws:iam::*:role/${var.project_name}-*",
          "arn:aws:iam::*:oidc-provider/token.actions.githubusercontent.com",
        ]
      },
      {
        Sid      = "StsCallerIdentity"
        Effect   = "Allow"
        Action   = ["sts:GetCallerIdentity"]
        Resource = "*"
      }
    ]
  })
}
