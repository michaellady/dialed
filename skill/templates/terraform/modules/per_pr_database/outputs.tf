output "database_name" {
  value       = postgresql_database.pr_db.name
  description = "Name of the PR's logical database (pr_<N>)."
}

output "username" {
  value       = postgresql_role.pr_user.name
  description = "Scoped role the app should connect as."
}

output "password" {
  value       = random_password.pr_user.result
  sensitive   = true
  description = "Password for the scoped role. Pass to the app via a secret/env var."
}

output "connection_string" {
  value       = "postgres://${postgresql_role.pr_user.name}:${random_password.pr_user.result}@${var.endpoint}:${var.port}/${postgresql_database.pr_db.name}?sslmode=require"
  sensitive   = true
  description = "Complete connection URI. Typical consumer: pass into an aws_lambda_function's environment.variables under a name like DATABASE_URL."
}
