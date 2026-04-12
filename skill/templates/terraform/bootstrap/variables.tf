variable "project_name" {
  type        = string
  description = "Lowercase project name; used as resource name prefix."

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,30}[a-z0-9]$", var.project_name))
    error_message = "project_name must be lowercase, start with a letter, and contain only letters, digits, and hyphens."
  }
}

variable "aws_region" {
  type        = string
  description = "AWS region all resources for this account are created in."
}

variable "github_repo" {
  type        = string
  description = "GitHub repo the OIDC trust policy is scoped to, in 'owner/name' form."

  validation {
    condition     = can(regex("^[^/]+/[^/]+$", var.github_repo))
    error_message = "github_repo must be in 'owner/name' form."
  }
}

variable "current_account_id" {
  type        = string
  description = "The 12-digit AWS account ID these resources are being created in. Caller identity is verified against this — mismatch aborts."
}

variable "envs_in_this_account" {
  type        = list(string)
  description = "Which envs (dev, staging, prod) live in this account. One deploy role is created per env."

  validation {
    condition     = alltrue([for e in var.envs_in_this_account : contains(["dev", "staging", "prod"], e)])
    error_message = "envs_in_this_account may only contain: dev, staging, prod."
  }
}

variable "assume_oidc_provider_exists" {
  type        = bool
  default     = false
  description = "Set true if the github OIDC provider already exists in this account (e.g. from a prior DIALED bootstrap or another tool). When true, the module reuses the existing provider; when false, it creates one."
}
