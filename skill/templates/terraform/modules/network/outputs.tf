output "vpc_id" {
  value       = aws_vpc.main.id
  description = "The VPC ID. Consumed by PR stacks via terraform_remote_state."
}

output "vpc_cidr_block" {
  value       = aws_vpc.main.cidr_block
  description = "VPC CIDR block, useful for security-group ingress rules in consumer stacks."
}

output "public_subnet_ids" {
  value       = aws_subnet.public[*].id
  description = "IDs of public subnets (in AZ order)."
}

output "private_subnet_ids" {
  value       = aws_subnet.private[*].id
  description = "IDs of private subnets (in AZ order). This is where Lambda / ECS / RDS typically land."
}

output "availability_zones" {
  value       = local.azs
  description = "AZ names used, in index order."
}

output "nat_mode" {
  value       = var.nat_mode
  description = "Which NAT implementation is in use (fck-nat or managed)."
}

output "nat_security_group_id" {
  value       = var.nat_mode == "fck-nat" ? module.fck_nat[0].security_group_id : null
  description = "Security group ID of the fck-nat instance. Consumer stacks allowing egress through fck-nat can reference this. null when nat_mode=managed."
}

output "internet_gateway_id" {
  value       = aws_internet_gateway.main.id
  description = "IGW ID, occasionally needed by consumer stacks."
}
