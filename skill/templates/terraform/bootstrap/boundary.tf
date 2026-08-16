# boundary.tf — the permissions boundary capping what every ${var.project_name}-*
# role can do.
#
# The deploy role's `iam_scoped` policy in main.tf grants iam:CreateRole +
# iam:PutRolePolicy + iam:AttachRolePolicy + iam:PassRole on ${var.project_name}-*
# roles. IAM does NOT restrict policy *content* via conditions, so without a
# boundary a compromised deploy role could chain
# (PutRolePolicy ${var.project_name}-evil = {Action:* Resource:*}) →
# (PassRole → Lambda/EC2 invoke) → full Administrator — the exact
# privilege-escalation hole the un-hardened flat policy shipped by default.
#
# A permissions boundary is the standard AWS mitigation. Attaching this boundary
# to a ${var.project_name}-* role caps that role's *effective* permissions to
# (role's policies) ∩ (boundary). An explicit Deny in the boundary wins
# regardless of what the role's own policies grant — so even if a compromised
# deploy role minted a ${var.project_name}-* role with iam:* in its policy, the
# boundary's Deny would make those grants ineffective. main.tf's
# ManageProjectRolesWithBoundary statement enforces that every minted / mutated
# role MUST carry this boundary.
#
# Naming: `dialed-${var.project_name}-boundary` — the `dialed-` prefix is
# deliberate. The deploy role's role-mutation grants are scoped to
# `role/${var.project_name}-*`, and any future policy-management grant a module
# adds is scoped to `policy/${var.project_name}-*`. Because this boundary's name
# starts with `dialed-` (NOT `${var.project_name}-`), it falls OUTSIDE those
# scopes, so a ${var.project_name}-* role bounded by this policy can never
# delete or modify the boundary itself. Without that naming choice the escalation
# chain would survive: a compromised role could delete its own boundary, then
# re-escalate.
#
# Rollout note (the safe two-step, only relevant when RETROFITTING an existing
# DIALED service that already has ${var.project_name}-* roles):
#   PR-A: create the boundary + attach it to the existing roles. No conditions
#         enforced yet — nothing changes; existing deploys keep working.
#   PR-B: add the iam:PermissionsBoundary condition to the deploy role's
#         role-mutation statement so any NEW / mutated role MUST carry it.
# Splitting avoids the chicken-and-egg where conditions are enforced before
# existing roles have the boundary attached and the next apply on those roles is
# blocked. For a FRESH `dialed:setup` there are no pre-existing roles, so the
# boundary + condition ship together in the first bootstrap apply.

resource "aws_iam_policy" "boundary" {
  name        = "dialed-${var.project_name}-boundary"
  description = "Permissions boundary for every ${var.project_name}-* role — caps the ceiling so the deploy-role privesc chain stays ineffective."
  policy      = data.aws_iam_policy_document.boundary.json

  tags = {
    ManagedBy = "dialed"
    Project   = var.project_name
  }
}

data "aws_iam_policy_document" "boundary" {
  # Block the escalation classes outright. A boundary's Deny is unconditional —
  # it overrides any Allow on the role itself. The ${var.project_name}-* app /
  # execution roles don't legitimately need iam:* / organizations:* / account:*
  # (those belong to the deploy role, which is NOT bounded by this policy —
  # boundaries only affect the role they're attached to).
  statement {
    sid    = "DenyEscalationActions"
    effect = "Deny"
    actions = [
      "iam:*",
      "organizations:*",
      "account:*",
    ]
    resources = ["*"]
  }

  # A boundary with only Deny rules grants nothing; the role's effective
  # permissions become empty regardless of its own policies. Allow-everything-else
  # lets each role's OWN scoped policies determine what's actually granted, while
  # the Deny above prevents anyone from ever escalating beyond it.
  statement {
    sid       = "AllowEverythingElse"
    actions   = ["*"]
    resources = ["*"]
  }
}
