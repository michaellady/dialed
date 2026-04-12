# per_pr_database — creates a logical Postgres database (`pr_<N>`) and a
# scoped role inside the shared RDS cluster, deletes both on destroy.
#
# Consumed from terraform/stack/main.tf as:
#
#   module "per_pr_db" {
#     count  = var.pr_number != "" ? 1 : 0
#     source = "../modules/per_pr_database"
#     pr_number         = var.pr_number
#     master_secret_arn = data.terraform_remote_state.shared[0].outputs.database_master_secret_arn
#     endpoint          = data.terraform_remote_state.shared[0].outputs.database_endpoint
#   }
#
# The workflow runner must have network reachability to the RDS instance
# for the Postgres provider to connect. In VPC-enabled DIALED setups the
# runner does NOT by default — fck-nat's ENI is private. Two viable
# strategies:
#
# 1. Deploy via a VPC-attached job runner (self-hosted on an EC2 inside
#    the VPC). Heavy; rarely worth it.
# 2. Temporarily expose RDS: add an `aws_security_group_rule` allowing
#    GitHub-runner CIDRs to the RDS SG. Not recommended.
# 3. (Preferred, v2 default) Use AWS IAM database authentication + an
#    SSM Session Manager port-forward from the runner to the RDS
#    endpoint through an intermediate bastion/fck-nat instance.
#
# For v1 of this module, we assume strategy 2 OR that the RDS instance
# is reachable directly (e.g., placed in a public subnet for dev only).
# Docs in references/anatomy.md cover the trade-off.

data "aws_secretsmanager_secret_version" "master" {
  secret_id = var.master_secret_arn
}

locals {
  master = jsondecode(data.aws_secretsmanager_secret_version.master.secret_string)

  db_name   = "pr_${var.pr_number}"
  role_name = "pr_${var.pr_number}_user"
}

provider "postgresql" {
  host            = var.endpoint
  port            = var.port
  database        = var.admin_database
  username        = local.master.username
  password        = local.master.password
  sslmode         = "require"
  connect_timeout = 15
  superuser       = false
}

# Scoped password for the PR's app role
resource "random_password" "pr_user" {
  length           = 32
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

resource "postgresql_role" "pr_user" {
  name     = local.role_name
  login    = true
  password = random_password.pr_user.result

  # Roles don't automatically have access to anything; grants come below.
}

resource "postgresql_database" "pr_db" {
  name              = local.db_name
  owner             = postgresql_role.pr_user.name
  template          = "template1"
  lc_collate        = "C"
  connection_limit  = -1
  allow_connections = true

  depends_on = [postgresql_role.pr_user]
}

resource "postgresql_grant" "pr_user_all" {
  role        = postgresql_role.pr_user.name
  database    = postgresql_database.pr_db.name
  schema      = "public"
  object_type = "database"
  privileges  = ["CONNECT", "CREATE", "TEMPORARY"]

  depends_on = [postgresql_database.pr_db]
}
