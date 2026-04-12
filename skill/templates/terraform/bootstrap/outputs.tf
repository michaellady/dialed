output "oidc_provider_arn" {
  value       = local.oidc_provider_arn
  description = "ARN of the GitHub OIDC provider, either newly-created or reused."
}

output "deploy_role_arns" {
  value       = { for env, role in aws_iam_role.deploy : env => role.arn }
  description = "Map of env → deploy role ARN. Primarily informational — the runtime dialed-setup action derives these from account IDs, it doesn't read them from here."
}

output "account_id" {
  value       = data.aws_caller_identity.current.account_id
  description = "Echo-back of the account these resources live in, for sanity checks."
}
