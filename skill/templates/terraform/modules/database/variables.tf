variable "name_prefix" {
  type        = string
  description = "Prefix for resource names, e.g. 'myapp-dev'. Used in identifiers and tags."
}

variable "environment" {
  type        = string
  description = "Env name — dev, staging, or prod. Affects deletion_protection and final_snapshot behavior."

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, staging, prod."
  }
}

variable "vpc_id" {
  type        = string
  description = "VPC ID the RDS instance lives in (from terraform/shared/modules/network)."
}

variable "private_subnet_ids" {
  type        = list(string)
  description = "Private subnet IDs for the DB subnet group (need >= 2 for multi-AZ)."

  validation {
    condition     = length(var.private_subnet_ids) >= 2
    error_message = "Need at least 2 private subnets (RDS requires >= 2 AZs even when multi_az=false)."
  }
}

variable "vpc_cidr_block" {
  type        = string
  description = "VPC CIDR block. Security group ingress allows Postgres (5432) from this range."
}

variable "engine_version" {
  type        = string
  description = "Postgres major.minor version."
  default     = "15.8"
}

variable "instance_class" {
  type        = string
  description = "RDS instance class. Default t4g.micro is ARM burstable, ~$12/mo."
  default     = "db.t4g.micro"
}

variable "allocated_storage" {
  type        = number
  description = "Initial allocated storage in GB. Can be autoscaled up; set max_allocated_storage for ceiling."
  default     = 20
}

variable "max_allocated_storage" {
  type        = number
  description = "Maximum storage size in GB. 0 disables autoscaling."
  default     = 100
}

variable "multi_az" {
  type        = bool
  description = "Deploy a hot-standby in a second AZ. Doubles cost; enable for prod."
  default     = false
}

variable "backup_retention_days" {
  type        = number
  description = "Daily automated backup retention. AWS minimum is 1; disable with 0 (not recommended)."
  default     = 7
}

variable "db_name" {
  type        = string
  description = "Name of the root/admin database created at instance launch. Per-PR logical DBs are created INTO this instance via the per_pr_database module."
  default     = "dialed"
}

variable "db_username" {
  type        = string
  description = "Master username. Password is auto-generated and stored in Secrets Manager."
  default     = "dialed_admin"
}

variable "tags" {
  type        = map(string)
  description = "Tags merged onto every resource this module creates."
  default     = {}
}
