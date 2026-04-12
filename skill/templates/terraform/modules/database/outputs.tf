output "endpoint" {
  value       = aws_db_instance.main.address
  description = "Hostname of the RDS instance. Consumed by per_pr_database and app stack for connection strings."
}

output "port" {
  value       = aws_db_instance.main.port
  description = "Postgres port (always 5432 for this module)."
}

output "database_name" {
  value       = aws_db_instance.main.db_name
  description = "Name of the admin/root database. Per-PR DBs are siblings inside the same instance."
}

output "master_username" {
  value       = aws_db_instance.main.username
  description = "Master DB username."
}

output "master_secret_arn" {
  value       = aws_secretsmanager_secret.master.arn
  description = "ARN of the Secrets Manager secret with master credentials. per_pr_database reads this; the app stack reads it for admin-level ops (rare)."
}

output "security_group_id" {
  value       = aws_security_group.rds.id
  description = "Security group ID of the RDS instance. Your Lambda/ECS security group needs egress to this on port 5432."
}

output "instance_id" {
  value       = aws_db_instance.main.id
  description = "RDS instance identifier."
}
