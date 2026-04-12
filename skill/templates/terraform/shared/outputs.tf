# Outputs from the shared tier form the contract PR stacks rely on.
# Keep these stable — renaming or removing breaks every consuming stack.
#
# M2 adds outputs for the database module (rds_endpoint, etc.); they live
# here, gated by try() so this file continues to plan before add-module
# runs.

output "vpc_id" {
  value       = try(module.network.vpc_id, null)
  description = "VPC ID. null when shared tier has no network module."
}

output "vpc_cidr_block" {
  value       = try(module.network.vpc_cidr_block, null)
  description = "VPC CIDR for SG rules. null when shared tier has no network module."
}

output "public_subnet_ids" {
  value       = try(module.network.public_subnet_ids, [])
  description = "Public subnet IDs in AZ order."
}

output "private_subnet_ids" {
  value       = try(module.network.private_subnet_ids, [])
  description = "Private subnet IDs in AZ order. Where Lambda / ECS / RDS typically land."
}

output "availability_zones" {
  value       = try(module.network.availability_zones, [])
  description = "AZ names used by the shared tier."
}

output "nat_security_group_id" {
  value       = try(module.network.nat_security_group_id, null)
  description = "Security group ID of fck-nat (null when nat_mode=managed or no network module)."
}

output "cleanup_lambda_name" {
  value       = aws_lambda_function.cleanup.function_name
  description = "Name of the orphan-cleanup Lambda. pr-cleanup.yml invokes this when terraform destroy fails."
}

# ─── Database outputs (present when dialed:add-module database is installed) ─

output "database_endpoint" {
  value       = try(module.database.endpoint, null)
  description = "RDS hostname. null until the database module is added."
}

output "database_port" {
  value       = try(module.database.port, null)
  description = "Postgres port. null until the database module is added."
}

output "database_name" {
  value       = try(module.database.database_name, null)
  description = "Admin/root database name. null until the database module is added."
}

output "database_master_secret_arn" {
  value       = try(module.database.master_secret_arn, null)
  description = "ARN of the Secrets Manager secret with master creds. Consumed by per_pr_database in the stack."
}

output "database_security_group_id" {
  value       = try(module.database.security_group_id, null)
  description = "SG of the RDS instance. Add egress rules from your app's SG to this on port 5432."
}
