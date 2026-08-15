# bootstrap/main.tf — OIDC identity provider + per-env scoped deploy roles.
#
# This module runs ONCE per AWS account that will host one or more envs. Its
# state lives in the S3 bucket created by scripts/bootstrap-state.sh (see the
# partial backend in backend.tf — the bucket name + lock table are passed via
# `terraform init -backend-config=...`).
#
# Inputs are read from .dialed.yml (converted to dialed.auto.tfvars.json by
# the render step during setup). The module figures out which envs map to
# THIS account by consulting account_model + current_account_id + account_ids.

terraform {
  required_version = ">= 1.9"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# ─── Who am I? ──────────────────────────────────────────────────────────────

data "aws_caller_identity" "current" {}

locals {
  # Fail fast if the caller's creds don't match `current_account_id`. Prevents
  # accidentally bootstrapping prod infra into dev or vice-versa.
  account_check = data.aws_caller_identity.current.account_id == var.current_account_id ? "ok" : tobool("Caller identity ${data.aws_caller_identity.current.account_id} does not match current_account_id ${var.current_account_id}")

  # Which envs live in this account? Caller passes them in via
  # var.envs_in_this_account. Typical combos:
  #   account_model=1: ["dev", "prod"] or ["dev", "staging", "prod"]
  #   account_model=2, 2-env: ["dev"] or ["prod"]
  #   account_model=2, 3-env: ["dev", "staging"] or ["prod"]
  #   account_model=3: exactly one of ["dev"], ["staging"], ["prod"]
  envs = toset(var.envs_in_this_account)
}

# ─── GitHub OIDC identity provider ──────────────────────────────────────────
#
# One per account. Thumbprint of token.actions.githubusercontent.com's cert,
# per GitHub's published guidance. We use a data source pattern so re-applying
# when the provider already exists is a no-op.

data "aws_iam_openid_connect_provider" "github_existing" {
  count = var.assume_oidc_provider_exists ? 1 : 0
  url   = "https://token.actions.githubusercontent.com"
}

resource "aws_iam_openid_connect_provider" "github" {
  count = var.assume_oidc_provider_exists ? 0 : 1

  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]

  tags = {
    ManagedBy = "dialed"
    Project   = var.project_name
  }
}

locals {
  oidc_provider_arn = var.assume_oidc_provider_exists ? data.aws_iam_openid_connect_provider.github_existing[0].arn : aws_iam_openid_connect_provider.github[0].arn
}

# ─── Per-env deploy roles ───────────────────────────────────────────────────
#
# Name format: dialed-deploy-{env}. This is the naming contract the runtime
# dialed-setup composite action relies on — don't rename without also
# updating the action.
#
# Trust policy: allows GitHub Actions workflows running in `var.github_repo`
# to assume the role via OIDC. For non-prod envs (dev, staging), any event
# from any branch in the repo can assume (needed for PR workflows). For prod,
# restricted to the main branch.

resource "aws_iam_role" "deploy" {
  for_each = local.envs

  name = "dialed-deploy-${each.key}"
  path = "/dialed/"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Federated = local.oidc_provider_arn }
        Action    = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          }
          StringLike = each.key == "prod" ? {
            "token.actions.githubusercontent.com:sub" = "repo:${var.github_repo}:ref:refs/heads/main"
            } : {
            "token.actions.githubusercontent.com:sub" = "repo:${var.github_repo}:*"
          }
        }
      }
    ]
  })

  tags = {
    ManagedBy = "dialed"
    Project   = var.project_name
    Env       = each.key
  }
}

# Managed policy: PowerUserAccess covers most infra operations (EC2, Lambda,
# API GW, RDS, S3, DynamoDB, Logs, Route 53, ACM, SSM, Secrets Manager, …)
# but intentionally excludes IAM and Organizations actions.

resource "aws_iam_role_policy_attachment" "power_user" {
  for_each   = aws_iam_role.deploy
  role       = each.value.name
  policy_arn = "arn:aws:iam::aws:policy/PowerUserAccess"
}

# Scoped IAM policy: Terraform needs to manage execution roles for things
# like Lambda, but we don't want the deploy role creating IAM users or
# touching roles it doesn't own. Restricted to roles under /dialed/ and
# the project's own prefix.

resource "aws_iam_role_policy" "iam_scoped" {
  for_each = aws_iam_role.deploy

  name = "dialed-iam-scoped"
  role = each.value.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ManageProjectRoles"
        Effect = "Allow"
        Action = [
          "iam:CreateRole",
          "iam:DeleteRole",
          "iam:GetRole",
          "iam:UpdateRole",
          "iam:UpdateAssumeRolePolicy",
          "iam:PutRolePolicy",
          "iam:DeleteRolePolicy",
          "iam:GetRolePolicy",
          "iam:ListRolePolicies",
          "iam:AttachRolePolicy",
          "iam:DetachRolePolicy",
          "iam:ListAttachedRolePolicies",
          "iam:TagRole",
          "iam:UntagRole",
          "iam:ListRoleTags",
          "iam:PassRole",
        ]
        Resource = [
          "arn:aws:iam::${var.current_account_id}:role/${var.project_name}-*",
          "arn:aws:iam::${var.current_account_id}:role/dialed/${var.project_name}-*",
        ]
      },
      {
        Sid      = "CreateServiceLinkedRoles"
        Effect   = "Allow"
        Action   = "iam:CreateServiceLinkedRole"
        Resource = "*"
      },
      {
        Sid    = "ManageInstanceProfiles"
        Effect = "Allow"
        Action = [
          "iam:CreateInstanceProfile",
          "iam:DeleteInstanceProfile",
          "iam:GetInstanceProfile",
          "iam:AddRoleToInstanceProfile",
          "iam:RemoveRoleFromInstanceProfile",
          "iam:TagInstanceProfile",
        ]
        Resource = "arn:aws:iam::${var.current_account_id}:instance-profile/${var.project_name}-*"
      },
      {
        Sid    = "DenyUserAndAccount"
        Effect = "Deny"
        Action = [
          "iam:*User*",
          "iam:*AccountAlias*",
          "iam:*AccountPassword*",
          "iam:*AccountSummary*",
          "iam:CreateAccountAlias",
          "iam:DeleteAccountAlias",
          "organizations:*",
          "account:*",
        ]
        Resource = "*"
      }
    ]
  })
}
