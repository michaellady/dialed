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
