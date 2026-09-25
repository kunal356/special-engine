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

# Scoped to exactly what terraform plan/apply calls for the resource types
# actually declared in this project, traced from what the AWS provider's
# create/read/update/delete cycle needs for each one, not a blanket
# AdministratorAccess grant or per-service wildcard. A few AWS APIs
# genuinely don't support resource-level scoping (list-all calls, and a
# handful of "Create" actions before the resource exists) - those are
# isolated into their own statement with Resource "*" and a comment
# explaining why, so the exception is visible rather than hidden inside
# a broader wildcard.
resource "aws_iam_role_policy" "github_actions_deploy" {
  count = var.github_repository != "" ? 1 : 0
  name  = "github-actions-terraform-deploy"
  role  = aws_iam_role.github_actions_deploy[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # S3 is the one deliberate exception to "list exact actions": the
        # aws_s3_bucket resource family probes a large, version-shifting
        # set of sub-resource APIs on every refresh (logging, CORS,
        # replication, object-lock, acceleration, etc.) even when none of
        # those are configured. Enumerating them exactly means the policy
        # silently breaks on the next provider upgrade. Scoping is done on
        # the Resource side instead: full S3 access, but only to buckets
        # this project actually owns (including its own state bucket).
        Sid    = "S3ProjectAndStateBuckets"
        Effect = "Allow"
        Action = ["s3:*"]
        Resource = [
          "arn:aws:s3:::${var.project_name}-*",
          "arn:aws:s3:::${var.project_name}-*/*",
        ]
      },
      {
        Sid      = "TerraformStateLock"
        Effect   = "Allow"
        Action   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:DeleteItem", "dynamodb:DescribeTable"]
        Resource = "arn:aws:dynamodb:*:*:table/${var.project_name}-tf-locks"
      },

      # ---- Glue: job, crawler, and catalog database CRUD ----
      {
        Sid    = "GlueResourceScoped"
        Effect = "Allow"
        Action = [
          "glue:CreateJob", "glue:GetJob", "glue:UpdateJob", "glue:DeleteJob",
          "glue:CreateCrawler", "glue:GetCrawler", "glue:UpdateCrawler", "glue:DeleteCrawler",
          "glue:CreateDatabase", "glue:GetDatabase", "glue:UpdateDatabase", "glue:DeleteDatabase",
          "glue:TagResource", "glue:UntagResource", "glue:GetTags",
        ]
        Resource = [
          "arn:aws:glue:*:*:job/${var.project_name}-*",
          "arn:aws:glue:*:*:crawler/${var.project_name}-*",
          "arn:aws:glue:*:*:database/ecommerce_raw_db",
          "arn:aws:glue:*:*:catalog", # Glue database actions also require the shared catalog resource
        ]
      },
      {
        # GetJobs / GetCrawlers / GetDatabases are list-all calls used
        # during `terraform plan` refresh - AWS does not support scoping
        # these to a resource ARN, they require "*" by design.
        Sid      = "GlueListCallsRequireWildcard"
        Effect   = "Allow"
        Action   = ["glue:GetJobs", "glue:GetCrawlers", "glue:GetDatabases"]
        Resource = "*"
      },

      # ---- Athena: workgroup CRUD + named queries ----
      {
        Sid    = "AthenaWorkgroupScoped"
        Effect = "Allow"
        Action = [
          "athena:CreateWorkGroup", "athena:GetWorkGroup", "athena:UpdateWorkGroup", "athena:DeleteWorkGroup",
          "athena:TagResource", "athena:UntagResource", "athena:ListTagsForResource",
        ]
        Resource = "arn:aws:athena:*:*:workgroup/${var.project_name}-*"
      },
      {
        # Athena named-query actions (Create/Get/Delete/List/BatchGet) do
        # not support resource-level IAM permissions at all - AWS requires
        # "*" for every one of them regardless of workgroup.
        Sid      = "AthenaNamedQueriesRequireWildcard"
        Effect   = "Allow"
        Action   = ["athena:CreateNamedQuery", "athena:GetNamedQuery", "athena:DeleteNamedQuery", "athena:ListNamedQueries"]
        Resource = "*"
      },

      # ---- Step Functions ----
      {
        Sid      = "StepFunctionsResourceScoped"
        Effect   = "Allow"
        Action   = ["states:DescribeStateMachine", "states:UpdateStateMachine", "states:DeleteStateMachine", "states:TagResource", "states:UntagResource", "states:ListTagsForResource"]
        Resource = "arn:aws:states:*:*:stateMachine:${var.project_name}-*"
      },
      {
        # CreateStateMachine is a "before the resource exists" action -
        # like several AWS create APIs, it does not support resource-level
        # scoping and must be granted against "*".
        Sid      = "StepFunctionsCreateRequiresWildcard"
        Effect   = "Allow"
        Action   = ["states:CreateStateMachine"]
        Resource = "*"
      },

      # ---- EventBridge ----
      {
        Sid    = "EventBridgeResourceScoped"
        Effect = "Allow"
        Action = [
          "events:PutRule", "events:DescribeRule", "events:DeleteRule",
          "events:PutTargets", "events:RemoveTargets", "events:ListTargetsByRule",
          "events:TagResource", "events:UntagResource", "events:ListTagsForResource",
        ]
        Resource = "arn:aws:events:*:*:rule/${var.project_name}-*"
      },

      # ---- SNS ----
      {
        Sid    = "SnsTopicScoped"
        Effect = "Allow"
        Action = [
          "sns:CreateTopic", "sns:GetTopicAttributes", "sns:SetTopicAttributes", "sns:DeleteTopic",
          "sns:Subscribe", "sns:Unsubscribe", "sns:ListSubscriptionsByTopic",
          "sns:TagResource", "sns:UntagResource", "sns:ListTagsForResource",
        ]
        Resource = "arn:aws:sns:*:*:${var.project_name}-*"
      },
      {
        # Subscription-attribute calls address the SUBSCRIPTION arn, not
        # the topic arn - and that arn has a random UUID suffix Terraform
        # can't predict ahead of time, so it can only be wildcarded, not
        # pinned to a specific known value the way the topic itself can.
        Sid      = "SnsSubscriptionAttributesWildcardSuffix"
        Effect   = "Allow"
        Action   = ["sns:GetSubscriptionAttributes", "sns:SetSubscriptionAttributes"]
        Resource = "arn:aws:sns:*:*:${var.project_name}-*:*"
      },

      # ---- CloudWatch Alarms ----
      {
        Sid      = "CloudWatchAlarmScoped"
        Effect   = "Allow"
        Action   = ["cloudwatch:PutMetricAlarm", "cloudwatch:TagResource", "cloudwatch:UntagResource", "cloudwatch:ListTagsForResource"]
        Resource = "arn:aws:cloudwatch:*:*:alarm:${var.project_name}-*"
      },
      {
        # DescribeAlarms and DeleteAlarms are list/batch operations that
        # AWS does not support scoping to a specific alarm ARN.
        Sid      = "CloudWatchAlarmListRequiresWildcard"
        Effect   = "Allow"
        Action   = ["cloudwatch:DescribeAlarms", "cloudwatch:DeleteAlarms"]
        Resource = "*"
      },

      # ---- IAM: only the roles/policies/OIDC provider this project owns ----
      {
        Sid    = "IamForProjectRoles"
        Effect = "Allow"
        Action = [
          "iam:GetRole", "iam:CreateRole", "iam:DeleteRole", "iam:UpdateRole",
          "iam:GetRolePolicy", "iam:PutRolePolicy", "iam:DeleteRolePolicy",
          "iam:AttachRolePolicy", "iam:DetachRolePolicy", "iam:ListRolePolicies",
          "iam:ListAttachedRolePolicies", "iam:TagRole", "iam:UntagRole", "iam:ListRoleTags",
          "iam:ListInstanceProfilesForRole", "iam:PassRole",
          "iam:GetOpenIDConnectProvider", "iam:CreateOpenIDConnectProvider", "iam:DeleteOpenIDConnectProvider",
          "iam:UpdateOpenIDConnectProviderThumbprint", "iam:TagOpenIDConnectProvider", "iam:UntagOpenIDConnectProvider",
          "iam:ListOpenIDConnectProviderTags",
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
