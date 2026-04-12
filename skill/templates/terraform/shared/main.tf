# shared/main.tf — foundational shared infrastructure, per env.
#
# This tier holds things the app stack and every PR stack SHOULD NOT create
# on their own: VPC, NAT, and (optionally, via `dialed:add-module`) RDS,
# OpenSearch, cache clusters, etc.
#
# PR stacks read its outputs via `data "terraform_remote_state" "shared"`
# configured in terraform/stack/main.tf.

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      ManagedBy = "dialed"
      Project   = var.project_name
      Env       = var.environment
      Tier      = "shared"
    }
  }
}

locals {
  name_prefix = "${var.project_name}-${var.environment}"
  common_tags = {
    ManagedBy = "dialed"
    Project   = var.project_name
    Env       = var.environment
    Tier      = "shared"
  }
}

# ─── Foundational: network ──────────────────────────────────────────────────
#
# Wired in by `dialed:setup` when needs_vpc=y, or by `dialed:add-shared`
# when added later. When disabled, this module block should be removed
# (or left commented out) and the shared tier reduces to just the cleanup
# Lambda (no-op when there are no resources to clean up).

module "network" {
  source = "../modules/network"

  name_prefix       = local.name_prefix
  vpc_cidr          = var.vpc_cidr
  nat_mode          = var.nat_mode
  az_count          = 2
  nat_instance_type = "t4g.nano"

  tags = local.common_tags
}

# ─── Product modules added later by `dialed:add-module` land here ───────────
#
# Example after `dialed:add-module database`:
#
#   module "database" {
#     source = "../modules/database"
#     name_prefix          = local.name_prefix
#     vpc_id               = module.network.vpc_id
#     private_subnet_ids   = module.network.private_subnet_ids
#     vpc_cidr_block       = module.network.vpc_cidr_block
#     tags                 = local.common_tags
#   }
