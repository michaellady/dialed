# Tagging contract. Every resource this stack creates gets these tags via
# default_tags on the provider, so scoped IAM conditions (single-account
# mode) and the orphan-cleanup Lambda can find them.
#
# The `Env` tag matches the condition in bootstrap's IAM role policies —
# PR stacks land in the dev account with Env=dev, not Env=dev-pr-<N>.
# The Workspace tag preserves PR-level granularity for cleanup.

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      ManagedBy = "dialed"
      Project   = var.project_name
      Env       = var.environment
      Workspace = terraform.workspace
      PR        = var.pr_number
      Tier      = "app"
    }
  }
}
