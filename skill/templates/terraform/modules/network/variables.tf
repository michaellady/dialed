variable "name_prefix" {
  type        = string
  description = "Prefix for resource names, e.g. 'myapp-dev'. Used in tags and Name tags."
}

variable "vpc_cidr" {
  type        = string
  description = "CIDR block for the VPC."
  default     = "10.0.0.0/16"

  validation {
    condition     = can(cidrnetmask(var.vpc_cidr))
    error_message = "vpc_cidr must be a valid CIDR (e.g. 10.0.0.0/16)."
  }
}

variable "az_count" {
  type        = number
  description = "Number of availability zones to spread public/private subnets across."
  default     = 2

  validation {
    condition     = var.az_count >= 1 && var.az_count <= 4
    error_message = "az_count must be between 1 and 4."
  }
}

variable "nat_mode" {
  type        = string
  description = "NAT egress mode. 'fck-nat' (default, ~$3-5/mo, single instance) or 'managed' (AWS NAT Gateway, ~$32/mo per AZ + data, HA)."
  default     = "fck-nat"

  validation {
    condition     = contains(["fck-nat", "managed"], var.nat_mode)
    error_message = "nat_mode must be one of: fck-nat, managed."
  }
}

variable "nat_instance_type" {
  type        = string
  description = "EC2 instance type for fck-nat. Only used when nat_mode=fck-nat."
  default     = "t4g.nano"
}

variable "tags" {
  type        = map(string)
  description = "Tags applied to every resource this module creates."
  default     = {}
}

variable "permissions_boundary_arn" {
  type        = string
  description = "Permissions boundary attached to the fck-nat instance role. The bootstrap tier gates the deploy role's iam:CreateRole on iam:PermissionsBoundary, so every project-prefixed role the shared-tier apply mints MUST carry the project's boundary; the name_prefix-nat role fck-nat creates is one of them. Pass the boundary ARN here so it gets bounded too, otherwise the shared-tier apply AccessDenies on CreateRole. Empty default keeps the module usable without the boundary (e.g. a project that hasn't shipped it)."
  default     = ""
}
