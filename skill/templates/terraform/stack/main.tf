# stack/main.tf — your app's per-env Terraform.
#
# DIALED scaffolded this file. Fill in your resources below the YOUR
# RESOURCES HERE marker. Typical building blocks you'll reference:
#
#   local.name_prefix        → "{project}-{env}" or "{project}-dev-pr-42"
#   local.is_pr_stack        → true when this is a per-PR deploy
#   local.vpc_id             → shared VPC (if needs_vpc=true)
#   local.private_subnet_ids → for Lambda VPC config / ECS / RDS
#   local.public_subnet_ids  → for public ALBs
#
# Output contract: `stack_url` is consumed by the workflow's system-test
# step as STACK_URL. Define it in outputs.tf pointing at whatever
# endpoint your tests should hit (API Gateway URL, ALB DNS, custom domain).

locals {
  is_pr_stack = var.pr_number != ""
  pr_suffix   = local.is_pr_stack ? "-pr-${var.pr_number}" : ""
  name_prefix = "${var.project_name}-${var.environment}${local.pr_suffix}"

  # Permissions boundary that caps every ${var.project_name}-* role (created by
  # the bootstrap tier, terraform/bootstrap/boundary.tf). Referenced by a
  # PREDICTABLE ARN — account_id + fixed name — so there's no cross-tier
  # remote_state dependency on bootstrap. EVERY IAM role this stack creates MUST
  # set `permissions_boundary = local.boundary_arn`: the deploy role's
  # ManageProjectRolesWithBoundary statement will AccessDeny any CreateRole that
  # omits it, so an un-bounded (escalatable) ${var.project_name}-* role can never
  # be minted. See the commented example under "YOUR RESOURCES HERE".
  boundary_arn = "arn:aws:iam::${var.account_ids[var.environment]}:policy/dialed-${var.project_name}-boundary"
}

# ─── Shared-tier wiring ─────────────────────────────────────────────────────
#
# When needs_vpc=true, read the shared tier's outputs so resources below can
# live in the long-lived VPC instead of spinning up their own.
#
# If your project set needs_vpc=false at setup and you later run
# `dialed:add-shared`, this block gets flipped to count=1 automatically.

data "terraform_remote_state" "shared" {
  count = var.needs_vpc ? 1 : 0

  backend = "s3"
  config = {
    bucket         = "dialed-${var.project_name}-${var.account_ids[var.environment]}-tfstate-shared"
    key            = "shared/terraform.tfstate"
    region         = var.aws_region
    dynamodb_table = "dialed-${var.project_name}-${var.account_ids[var.environment]}-tflocks"
    encrypt        = true
  }
}

locals {
  vpc_id             = try(data.terraform_remote_state.shared[0].outputs.vpc_id, null)
  vpc_cidr_block     = try(data.terraform_remote_state.shared[0].outputs.vpc_cidr_block, null)
  public_subnet_ids  = try(data.terraform_remote_state.shared[0].outputs.public_subnet_ids, [])
  private_subnet_ids = try(data.terraform_remote_state.shared[0].outputs.private_subnet_ids, [])
  nat_sg_id          = try(data.terraform_remote_state.shared[0].outputs.nat_security_group_id, null)
}

# ─── YOUR RESOURCES HERE ────────────────────────────────────────────────────
#
# Any IAM role you create MUST carry the permissions boundary, or the deploy
# role's CreateRole will be denied (see local.boundary_arn above):
#
#   resource "aws_iam_role" "api" {
#     name                 = "${local.name_prefix}-api-exec"
#     assume_role_policy   = data.aws_iam_policy_document.lambda_assume.json
#     permissions_boundary = local.boundary_arn   # ← required on every role
#   }
#
# Example (Lambda inside shared VPC):
#
#   resource "aws_lambda_function" "api" {
#     function_name = "${local.name_prefix}-api"
#     role          = aws_iam_role.api.arn
#     runtime       = "provided.al2023"
#     handler       = "bootstrap"
#     filename      = "../../dist/bootstrap.zip"
#     source_code_hash = filebase64sha256("../../dist/bootstrap.zip")
#
#     vpc_config {
#       subnet_ids         = local.private_subnet_ids
#       security_group_ids = [aws_security_group.lambda.id]
#     }
#   }
