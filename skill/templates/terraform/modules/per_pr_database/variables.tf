variable "pr_number" {
  type        = string
  description = "PR number. Used to derive the logical DB + role names as pr_<N>."

  validation {
    condition     = can(regex("^[0-9]+$", var.pr_number))
    error_message = "pr_number must be a non-empty numeric string. (Don't include this module with count=0 when pr_number is empty.)"
  }
}

variable "master_secret_arn" {
  type        = string
  description = "ARN of the Secrets Manager secret containing master DB credentials. Provided by the database module's output."
}

variable "endpoint" {
  type        = string
  description = "RDS hostname. Provided by the database module's output."
}

variable "port" {
  type        = number
  description = "Postgres port."
  default     = 5432
}

variable "admin_database" {
  type        = string
  description = "Name of the admin database the Postgres provider connects to when creating/dropping the pr_<N> database."
  default     = "dialed"
}
