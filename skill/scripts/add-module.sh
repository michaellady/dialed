#!/usr/bin/env bash
# add-module.sh — Wire a module into an existing DIALED shared tier.
#
# Usage:
#   add-module.sh --name NAME [--source PATH] [--alias ALIAS]
#
# --name     one of the DIALED-shipped modules (network, database) OR the
#            basename of a custom module (also pass --source).
# --source   path to a custom module directory. Omit for shipped modules.
# --alias    TF module block label. Defaults to --name.

set -euo pipefail

if [ -z "${DIALED_HOME:-}" ]; then
  script="${BASH_SOURCE[0]}"
  while [ -L "$script" ]; do
    dir="$(cd -P "$(dirname "$script")" && pwd)"
    script="$(readlink "$script")"
    [[ "$script" != /* ]] && script="$dir/$script"
  done
  DIALED_HOME="$(cd -P "$(dirname "$script")/../.." && pwd)"
fi

NAME=""
SOURCE_PATH=""
ALIAS=""

while [ $# -gt 0 ]; do
  case "$1" in
    --name) NAME="$2"; shift 2 ;;
    --source) SOURCE_PATH="$2"; shift 2 ;;
    --alias) ALIAS="$2"; shift 2 ;;
    *) echo "unknown flag: $1" >&2; exit 1 ;;
  esac
done

if [ -z "$NAME" ]; then
  echo "usage: $0 --name NAME [--source PATH] [--alias ALIAS]" >&2
  exit 1
fi

ALIAS="${ALIAS:-$NAME}"

[ -f .dialed.yml ] || { echo "ERROR: .dialed.yml missing" >&2; exit 1; }
[ -d terraform/shared ] || { echo "ERROR: terraform/shared/ missing — run dialed:add-shared first." >&2; exit 1; }

# Resolve source dir
if [ -n "$SOURCE_PATH" ]; then
  [ -d "$SOURCE_PATH" ] || { echo "ERROR: --source path $SOURCE_PATH not found" >&2; exit 1; }
  src="$SOURCE_PATH"
else
  src="$DIALED_HOME/skill/templates/terraform/modules/$NAME"
  [ -d "$src" ] || { echo "ERROR: no DIALED-shipped module named '$NAME' (looked in $src). Pass --source for custom modules." >&2; exit 1; }
fi

dst="terraform/modules/$NAME"

# Copy module
if [ -d "$dst" ]; then
  echo "↻ module already present at $dst; refreshing from source"
  rm -rf "$dst"
fi
mkdir -p terraform/modules
cp -r "$src" "$dst"
echo "✓ copied $src → $dst"

# Inject module block into shared/main.tf if not already present
marker="# dialed:add-module:${ALIAS}"
if grep -Fq "$marker" terraform/shared/main.tf; then
  echo "✓ module block for '$ALIAS' already present in shared/main.tf — skipping inject"
else
  case "$NAME" in
    database)
      # Fully-wired block — database is a DIALED-shipped module with known inputs.
      cat >> terraform/shared/main.tf <<TF

${marker}
module "${ALIAS}" {
  source = "../modules/${NAME}"

  name_prefix        = local.name_prefix
  environment        = var.environment
  vpc_id             = module.network.vpc_id
  private_subnet_ids = module.network.private_subnet_ids
  vpc_cidr_block     = module.network.vpc_cidr_block
  tags               = local.common_tags

  # Defaults: db.t4g.micro (~\$12/mo), 20GB gp3, single-AZ, 7-day backups.
  # Override for prod: uncomment and tune.
  # instance_class         = "db.t4g.small"
  # multi_az               = true
  # backup_retention_days  = 30
}
TF
      ;;
    *)
      cat >> terraform/shared/main.tf <<TF

${marker}
module "${ALIAS}" {
  source = "../modules/${NAME}"

  # TODO: Pass the inputs this module needs. For network-dependent
  # modules, you'll typically want:
  #   vpc_id             = module.network.vpc_id
  #   private_subnet_ids = module.network.private_subnet_ids
  #   vpc_cidr_block     = module.network.vpc_cidr_block
  #   tags               = local.common_tags
}
TF
      ;;
  esac
  echo "✓ appended module block to terraform/shared/main.tf"
  if [ "$NAME" != "database" ]; then
    echo "  → Edit the TODO block to pass this module its required inputs before the next apply."
  fi
fi

# Hook for database: append shared outputs so PR stacks can consume
if [ "$NAME" = "database" ]; then
  outputs_marker="# dialed:add-module:database:outputs"
  if ! grep -Fq "$outputs_marker" terraform/shared/outputs.tf 2>/dev/null; then
    cat >> terraform/shared/outputs.tf <<TF

${outputs_marker}
output "database_endpoint" {
  value       = module.${ALIAS}.endpoint
  description = "RDS hostname (from dialed:add-module database)."
}

output "database_port" {
  value       = module.${ALIAS}.port
  description = "Postgres port."
}

output "database_name" {
  value       = module.${ALIAS}.database_name
  description = "Admin/root database name."
}

output "database_master_secret_arn" {
  value       = module.${ALIAS}.master_secret_arn
  description = "ARN of the Secrets Manager secret with master credentials. Consumed by per_pr_database in the stack."
}

output "database_security_group_id" {
  value       = module.${ALIAS}.security_group_id
  description = "SG of the RDS instance. Your app's SG needs egress to 5432 against this."
}
TF
    echo "✓ appended database_* outputs to terraform/shared/outputs.tf"
  fi
fi

# Hook for database: also install per_pr_database into the stack
if [ "$NAME" = "database" ]; then
  per_pr="$DIALED_HOME/skill/templates/terraform/modules/per_pr_database"
  if [ -d "$per_pr" ]; then
    mkdir -p terraform/modules
    [ ! -d terraform/modules/per_pr_database ] && cp -r "$per_pr" terraform/modules/
    echo "✓ installed modules/per_pr_database/"
    stack_marker="# dialed:add-module:per_pr_db"
    if ! grep -Fq "$stack_marker" terraform/stack/main.tf 2>/dev/null; then
      cat >> terraform/stack/main.tf <<'TF'

# dialed:add-module:per_pr_db
# Per-PR Postgres logical DB, created on apply and dropped on destroy.
# Active only on PR stacks (var.pr_number != ""). Your app resources
# should pull the connection string from module.per_pr_db[0].connection_string
# (or build their own from .username/.password/.database_name).
module "per_pr_db" {
  count  = var.pr_number != "" ? 1 : 0
  source = "../modules/per_pr_database"

  pr_number         = var.pr_number
  endpoint          = data.terraform_remote_state.shared[0].outputs.database_endpoint
  port              = data.terraform_remote_state.shared[0].outputs.database_port
  master_secret_arn = data.terraform_remote_state.shared[0].outputs.database_master_secret_arn
}
TF
      echo "✓ appended per_pr_db module to terraform/stack/main.tf"
    fi
  else
    echo "::warning::modules/per_pr_database not shipped with this DIALED version. pr_<N> DBs won't be created automatically."
  fi
fi

echo ""
echo "Next steps:"
echo "  1. Review terraform/shared/main.tf and supply any inputs the new module needs."
echo "  2. Commit the changes: git add terraform/ && git commit -m 'Add ${NAME} module'"
echo "  3. Push. shared-deploy.yml will apply the shared tier automatically on main."
echo "     Or run locally (after switching AWS creds per env): terraform -chdir=terraform/shared apply"
