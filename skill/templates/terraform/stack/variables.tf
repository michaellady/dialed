variable "project_name" {
  type        = string
  description = "From .dialed.yml. Used as resource name prefix."
}

variable "aws_region" {
  type        = string
  description = "From .dialed.yml. Where this stack's resources live."
}

variable "environment" {
  type        = string
  description = "dev, staging, or prod. Passed by the workflow."

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, staging, prod."
  }
}

variable "pr_number" {
  type        = string
  description = "PR number when this is a per-PR stack (workspace = {env}-pr-{N}). Empty string for shared env stacks on main."
  default     = ""
}

variable "account_ids" {
  type        = map(string)
  description = "From .dialed.yml. Map of env → account ID. Needed for cross-env data sources if your stack uses them."
  default     = {}
}

variable "domain" {
  type        = string
  description = "From .dialed.yml. Root domain for PR / env URLs (empty if none configured)."
  default     = ""
}

variable "needs_vpc" {
  type        = bool
  description = "From .dialed.yml. When true, the stack reads shared-tier outputs via terraform_remote_state."
  default     = true
}
