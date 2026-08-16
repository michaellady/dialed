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

  # Repo identifiers trusted in the OIDC `sub` claim. Always includes the
  # classic "owner/name" form; orgs emitting IMMUTABLE subjects (numeric ids,
  # e.g. "org@123/repo@456") must add that form via var.oidc_extra_sub_repos,
  # since the classic pattern never matches an immutable sub. Default is just
  # [github_repo] — a single-element list, behaviorally identical to the prior
  # scalar condition.
  oidc_sub_repos = concat([var.github_repo], var.oidc_extra_sub_repos)
}

# ─── Per-env deploy roles ───────────────────────────────────────────────────
#
# Name format: dialed-{project_name}-deploy-{env}. This is the naming contract
# the runtime dialed-setup composite action relies on — don't rename without
# also updating the action. Project-namespaced so multiple DIALED services can
# share one AWS account without colliding on the deploy role (the un-namespaced
# "dialed-deploy-{env}" is per-account, so a second service in the same account
# would clobber the first's role). The composite action derives the same name
# from project_name.
#
# Trust policy: allows GitHub Actions workflows in `var.github_repo` to assume
# the role via OIDC, narrowed to the EXACT OIDC subjects DIALED's own workflow
# jobs emit — NOT a blanket "repo:<r>:*" wildcard.
#   - non-prod (dev, staging): PR jobs (subject "repo:<r>:pull_request") and
#     env-declared jobs (subject "repo:<r>:environment:<env>", e.g. deploy-dev
#     and the now-env-gated unit-and-integration / system-test-dev).
#   - prod: ONLY env-declared jobs (subject "repo:<r>:environment:prod").
# Dropping the wildcard AND the bare "ref:refs/heads/main" subject is the point:
# any OTHER main-branch / comment-triggered workflow that carries
# id-token:write — notably an @claude bot answering a PR comment — would
# otherwise present one of those subjects and assume the deploy role. Because
# the prod branch no longer trusts a ref, the "prod only from main" gate now
# lives in the prod GitHub environment's deployment-branch policy (dialed:setup
# locks it to main), which is load-bearing since main-deploy is also
# workflow_dispatch-able from any branch. See the StringLike below.

resource "aws_iam_role" "deploy" {
  for_each = local.envs

  name = "dialed-${var.project_name}-deploy-${each.key}"
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
          # prod: reachable ONLY via jobs that declare `environment: prod`
          # (deploy-prod, shared-prod, smoke-test-prod — all env-gated), whose
          # subject is "repo:<r>:environment:prod". The bare
          # "repo:<r>:ref:refs/heads/main" subject was REMOVED so a main-branch
          # bot (e.g. comment-triggered @claude, which carries id-token:write)
          # can no longer assume the prod role. main-only is enforced by the
          # prod GitHub environment's deployment-branch policy (dialed:setup
          # locks it to main), which matters because main-deploy is also
          # workflow_dispatch-able from any branch.
          # non-prod: reachable via PR jobs ("repo:<r>:pull_request") and
          # env-declared jobs ("repo:<r>:environment:<env>"). The old
          # "repo:<r>:*" wildcard was dropped for the same reason — it admitted
          # the bare "ref:refs/heads/main" subject a main-branch bot presents.
          StringLike = each.key == "prod" ? {
            "token.actions.githubusercontent.com:sub" = [for r in local.oidc_sub_repos : "repo:${r}:environment:prod"]
            } : {
            "token.actions.githubusercontent.com:sub" = concat(
              [for r in local.oidc_sub_repos : "repo:${r}:pull_request"],
              [for r in local.oidc_sub_repos : "repo:${r}:environment:${each.key}"],
            )
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
      # The single ManageProjectRoles statement is split into three so the
      # role-mutation actions can be GATED on iam:PermissionsBoundary. Every
      # ${project_name}-* role this deploy role mints or modifies MUST carry
      # dialed-${project_name}-boundary (see boundary.tf). That makes the
      # classic privilege-escalation chain — CreateRole/PutRolePolicy with an
      # {Action:* Resource:*} policy → PassRole → λ/EC2 invoke → Administrator —
      # ineffective: the boundary's Deny iam:*/organizations:*/account:* caps
      # the effective reach of any ${project_name}-* role regardless of what
      # policy the deploy role attaches to it. Shipping the flat, un-bounded
      # statement is the exact Administrator-escalation hole this closes.

      # 1) Boundary-enforced role mutations. AWS evaluates iam:PermissionsBoundary
      # against either the REQUEST (CreateRole / PutRolePermissionsBoundary) or
      # the EXISTING role's boundary (the rest). Without this condition the deploy
      # role could create or modify a ${project_name}-* role WITHOUT a boundary;
      # with it, every minted / mutated role is bounded.
      {
        Sid    = "ManageProjectRolesWithBoundary"
        Effect = "Allow"
        Action = [
          "iam:CreateRole",
          "iam:PutRolePolicy",
          "iam:DeleteRolePolicy",
          "iam:AttachRolePolicy",
          "iam:DetachRolePolicy",
          # iam:PutRolePermissionsBoundary is kept — it can only SET the boundary, and the
          # StringEquals condition below pins the value to dialed-${project_name}-boundary, so
          # it can never point a role at a weaker boundary. It's safe.
          #
          # iam:DeleteRolePermissionsBoundary is deliberately OMITTED. AWS evaluates the
          # iam:PermissionsBoundary condition for a Delete against the role's CURRENT boundary,
          # so this statement WOULD authorize stripping the boundary off any bounded
          # ${project_name}-* role. That reopens the escalation chain the boundary exists to
          # close: create a bounded role -> attach AdministratorAccess ->
          # DeleteRolePermissionsBoundary -> PassRole -> full admin. Teardown never needs it
          # (bounded roles are removed with iam:DeleteRole in ManageProjectRolesOther, which
          # deletes the whole role rather than un-bounding it), so dropping it is non-breaking.
          "iam:PutRolePermissionsBoundary",
        ]
        Resource = [
          "arn:aws:iam::${var.current_account_id}:role/${var.project_name}-*",
          "arn:aws:iam::${var.current_account_id}:role/dialed/${var.project_name}-*",
        ]
        Condition = {
          StringEquals = {
            "iam:PermissionsBoundary" = "arn:aws:iam::${var.current_account_id}:policy/dialed-${var.project_name}-boundary"
          }
        }
      },

      # 2) PassRole, gated on the destination service. iam:PassRole supports
      # iam:PassedToService; pinning it to a CLOSED set of in-model services
      # stops a ${project_name}-* role being passed to an arbitrary service.
      # The two services the generic DIALED model passes an execution role to:
      #   - lambda.amazonaws.com — Lambda execution roles (the default app tier).
      #   - ec2.amazonaws.com    — the network module's fck-nat NAT instance,
      #     whose ASG launch template carries the ${project_name}-<env>-nat
      #     instance profile; UpdateAutoScalingGroup validates PassRole to EC2
      #     when the fck-nat AMI rolls, so omitting ec2 breaks shared-tier apply.
      # A service that passes roles to OTHER destinations (e.g. ecs-tasks,
      # scheduler, states) must EXTEND this list in its own copy of the template.
      # Still resource-scoped to ${project_name}-* / dialed/${project_name}-*, so
      # this is not a broadening to arbitrary roles.
      {
        Sid    = "PassProjectRole"
        Effect = "Allow"
        Action = "iam:PassRole"
        Resource = [
          "arn:aws:iam::${var.current_account_id}:role/${var.project_name}-*",
          "arn:aws:iam::${var.current_account_id}:role/dialed/${var.project_name}-*",
        ]
        Condition = {
          StringEquals = {
            "iam:PassedToService" = [
              "lambda.amazonaws.com",
              "ec2.amazonaws.com",
            ]
          }
        }
      },

      # 3) Read + non-boundary-enforced role-mgmt actions. These either don't
      # support the iam:PermissionsBoundary condition (reads, UpdateAssumeRolePolicy,
      # role metadata) or are safely scoped by resource alone (DeleteRole — removing
      # a role is not a privilege increase). ListInstanceProfilesForRole is required
      # for the role-delete path the AWS provider walks during destroy.
      {
        Sid    = "ManageProjectRolesOther"
        Effect = "Allow"
        Action = [
          "iam:DeleteRole",
          "iam:GetRole",
          "iam:UpdateRole",
          "iam:UpdateAssumeRolePolicy",
          "iam:GetRolePolicy",
          "iam:ListRolePolicies",
          "iam:ListAttachedRolePolicies",
          "iam:ListInstanceProfilesForRole",
          "iam:TagRole",
          "iam:UntagRole",
          "iam:ListRoleTags",
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
