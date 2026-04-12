variable "project_name" {
  type        = string
  description = "Lowercase project name; used as resource name prefix."
}

variable "aws_region" {
  type        = string
  description = "AWS region this env lives in."
}

variable "environment" {
  type        = string
  description = "Env name — dev, staging, or prod. Set by the workflow."

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, staging, prod."
  }
}

variable "vpc_cidr" {
  type        = string
  description = "CIDR block for this env's shared VPC."
  default     = "10.0.0.0/16"
}

variable "nat_mode" {
  type        = string
  description = "NAT egress mode: fck-nat (default, cheap) or managed (AWS NAT Gateway, HA)."
  default     = "fck-nat"
}
