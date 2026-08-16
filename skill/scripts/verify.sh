#!/usr/bin/env bash
# verify.sh — Check a DIALED-ified project against expected AWS + filesystem state.
#
# Reports drift; does NOT fix anything. Exit 0 if all checks pass, non-zero
# otherwise. Run from the project's root directory.

set -uo pipefail

if [ -z "${DIALED_HOME:-}" ]; then
  script="${BASH_SOURCE[0]}"
  while [ -L "$script" ]; do
    dir="$(cd -P "$(dirname "$script")" && pwd)"
    script="$(readlink "$script")"
    [[ "$script" != /* ]] && script="$dir/$script"
  done
  DIALED_HOME="$(cd -P "$(dirname "$script")/../.." && pwd)"
fi
export DIALED_HOME

if [ ! -f .dialed.yml ]; then
  echo "✗ .dialed.yml not found. This project isn't DIALED-ified."
  exit 1
fi

PROJECT=$(yq -r '.project_name' .dialed.yml)
REGION=$(yq -r '.aws_region' .dialed.yml)
GITHUB_REPO=$(yq -r '.github_repo' .dialed.yml)
ENV_MODEL=$(yq -r '.env_model' .dialed.yml)
NEEDS_VPC=$(yq -r '.needs_vpc' .dialed.yml)
STALE_WARN=$(yq -r '.enable_stale_pr_warning' .dialed.yml)

if [ "$ENV_MODEL" = "3-env" ]; then
  ENVS=(dev staging prod)
else
  ENVS=(dev prod)
fi

declare -A env_to_account
for env in "${ENVS[@]}"; do
  env_to_account[$env]=$(yq -r ".account_ids.${env}" .dialed.yml)
done

pass=0
fail=0

ok() {
  echo "  ✓ $1"
  pass=$((pass + 1))
}
bad() {
  echo "  ✗ $1"
  fail=$((fail + 1))
}

# ─── Filesystem checks ──────────────────────────────────────────────────────

echo "== Filesystem =="

for f in pr-deploy.yml pr-cleanup.yml test.yml main-deploy.yml; do
  [ -f ".github/workflows/$f" ] && ok "workflow $f" || bad "missing .github/workflows/$f"
done

if [ "$STALE_WARN" = "true" ]; then
  [ -f .github/workflows/pr-stale-warn.yml ] && ok "workflow pr-stale-warn.yml" || bad "enable_stale_pr_warning=true but pr-stale-warn.yml missing"
fi

if [ "$NEEDS_VPC" = "true" ]; then
  [ -f .github/workflows/shared-deploy.yml ] && ok "workflow shared-deploy.yml" || bad "needs_vpc=true but shared-deploy.yml missing"
  [ -d terraform/shared ] && ok "terraform/shared/" || bad "terraform/shared/ missing"
  [ -d terraform/modules/network ] && ok "terraform/modules/network/" || bad "terraform/modules/network/ missing"
fi

[ -f .github/actions/dialed-setup/action.yml ] && ok "dialed-setup composite action" || bad ".github/actions/dialed-setup/action.yml missing"
[ -d terraform/bootstrap ] && ok "terraform/bootstrap/" || bad "terraform/bootstrap/ missing"
[ -d terraform/stack ] && ok "terraform/stack/" || bad "terraform/stack/ missing"
[ -f Makefile ] && grep -q 'wait-ready:' Makefile && ok "Makefile has wait-ready target" || bad "Makefile missing or lacks wait-ready target"

# Database module (optional — present only when add-module database ran)
has_db_module=false
if [ -d terraform/modules/database ] || grep -Fq "dialed:add-module:database" terraform/shared/main.tf 2>/dev/null; then
  has_db_module=true
  echo ""
  echo "-- database module detected --"
  [ -d terraform/modules/database ] && ok "modules/database/ present" || bad "modules/database/ missing but referenced in shared/main.tf"
  [ -d terraform/modules/per_pr_database ] && ok "modules/per_pr_database/ present" || bad "modules/per_pr_database/ missing (required when database is installed)"
  grep -Fq 'dialed:add-module:per_pr_db' terraform/stack/main.tf 2>/dev/null \
    && ok "stack/main.tf has per_pr_db module block" \
    || bad "stack/main.tf missing the per_pr_db module block"
  grep -Fq 'database_endpoint' terraform/shared/outputs.tf 2>/dev/null \
    && ok "shared/outputs.tf re-exports database_*" \
    || bad "shared/outputs.tf doesn't re-export database_* (consuming stacks can't reach the RDS endpoint)"
fi

# ─── AWS checks per account ─────────────────────────────────────────────────

echo ""
echo "== AWS =="

declare -A checked_accounts
for env in "${ENVS[@]}"; do
  aid="${env_to_account[$env]}"
  if [ -n "${checked_accounts[$aid]:-}" ]; then
    continue
  fi
  checked_accounts[$aid]=1

  echo ""
  echo "— Account $aid —"

  current=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "")
  if [ "$current" != "$aid" ]; then
    echo "  ⊘ credentials not for $aid (got $current) — skipping AWS checks for this account"
    continue
  fi

  state_bucket="dialed-${PROJECT}-${aid}-tfstate"
  shared_bucket="dialed-${PROJECT}-${aid}-tfstate-shared"
  lock_table="dialed-${PROJECT}-${aid}-tflocks"

  if aws s3api head-bucket --bucket "$state_bucket" 2>/dev/null; then
    ok "S3 bucket $state_bucket"
    versioning=$(aws s3api get-bucket-versioning --bucket "$state_bucket" --query 'Status' --output text 2>/dev/null || echo "")
    [ "$versioning" = "Enabled" ] && ok "  versioning enabled" || bad "  versioning NOT enabled on $state_bucket"
  else
    bad "S3 bucket $state_bucket missing"
  fi

  if [ "$NEEDS_VPC" = "true" ]; then
    aws s3api head-bucket --bucket "$shared_bucket" 2>/dev/null \
      && ok "S3 bucket $shared_bucket" \
      || bad "needs_vpc=true but $shared_bucket missing"
  fi

  aws dynamodb describe-table --table-name "$lock_table" --region "$REGION" >/dev/null 2>&1 \
    && ok "DDB table $lock_table" \
    || bad "DDB table $lock_table missing"

  aws iam get-open-id-connect-provider \
    --open-id-connect-provider-arn "arn:aws:iam::${aid}:oidc-provider/token.actions.githubusercontent.com" \
    >/dev/null 2>&1 \
    && ok "GitHub OIDC provider" \
    || bad "GitHub OIDC provider missing in account $aid"
done

# Per-env role + (optional) RDS checks
echo ""
for env in "${ENVS[@]}"; do
  aid="${env_to_account[$env]}"
  current=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "")
  if [ "$current" != "$aid" ]; then
    echo "⊘ role/DB checks for env=$env account=$aid skipped (creds not switched)"
    continue
  fi

  # Database reachability (only when module is installed)
  if [ "$has_db_module" = "true" ]; then
    project=$(yq -r '.project_name' .dialed.yml)
    db_identifier="${project}-${env}-rds"
    if aws rds describe-db-instances --db-instance-identifier "$db_identifier" --region "$REGION" >/dev/null 2>&1; then
      ok "RDS instance $db_identifier (env=$env)"
      # Verify Secrets Manager secret exists
      secret_count=$(aws secretsmanager list-secrets --region "$REGION" \
        --filters "Key=name,Values=${project}-${env}-db-master-" \
        --query 'length(SecretList)' --output text 2>/dev/null || echo 0)
      [ "$secret_count" -gt 0 ] && ok "  master-credentials secret present" || bad "  master-credentials secret missing"
    else
      bad "RDS instance $db_identifier missing in env=$env — did shared-deploy.yml run?"
    fi
  fi

  # Deploy role. New setups use the project-namespaced name
  # (dialed-${PROJECT}-deploy-${env}); services bootstrapped before the
  # namespacing change (e.g. Lore) still use the legacy per-account name
  # (dialed-deploy-${env}). Probe the namespaced name first, fall back to
  # legacy on a 404 so verify passes for BOTH.
  role_name="dialed-${PROJECT}-deploy-${env}"
  if ! aws iam get-role --role-name "$role_name" >/dev/null 2>&1; then
    if aws iam get-role --role-name "dialed-deploy-${env}" >/dev/null 2>&1; then
      role_name="dialed-deploy-${env}"
    fi
  fi
  if aws iam get-role --role-name "$role_name" >/dev/null 2>&1; then
    ok "IAM role $role_name (env=$env)"
    trust=$(aws iam get-role --role-name "$role_name" --query 'Role.AssumeRolePolicyDocument' --output json 2>/dev/null | python3 -c 'import sys,json,urllib.parse; d=json.loads(sys.stdin.read()); print(json.dumps(d) if isinstance(d,dict) else urllib.parse.unquote(sys.stdin.read()))' 2>/dev/null || echo "")
    # Anchored on "repo:<repo>:" — the sub claim always follows the repo with a
    # colon, so this rejects a look-alike suffix (e.g. repo:owner/name-attacker:*)
    # that an unanchored substring match would wrongly accept. The classic
    # owner/name form is always present in the trust policy even for orgs that
    # also emit immutable subjects, so matching it is sufficient.
    if echo "$trust" | grep -qF "repo:${GITHUB_REPO}:"; then
      ok "  trust policy references $GITHUB_REPO"
    else
      bad "  trust policy does not reference $GITHUB_REPO (anchored repo:${GITHUB_REPO}:)"
    fi
  else
    bad "IAM role dialed-${PROJECT}-deploy-${env} (or legacy dialed-deploy-${env}) missing in account $aid"
  fi

  # Permissions boundary — the default hardening capping every ${PROJECT}-*
  # role so the deploy role can't mint an Administrator-escalatable role.
  # Advisory (does NOT increment fail): services bootstrapped before boundaries
  # became the default still work, so their absence isn't a hard failure — but a
  # missing boundary means re-running dialed:setup will harden the deploy role.
  if aws iam get-policy --policy-arn "arn:aws:iam::${aid}:policy/dialed-${PROJECT}-boundary" >/dev/null 2>&1; then
    ok "permissions boundary dialed-${PROJECT}-boundary (account $aid)"
  else
    echo "  ⚠ permissions boundary dialed-${PROJECT}-boundary missing (account $aid) — re-run dialed:setup to harden the deploy role (pre-boundary setups still deploy, but lack the escalation cap)"
  fi
done

# ─── Summary ────────────────────────────────────────────────────────────────

echo ""
echo "== Summary =="
echo "  $pass passed, $fail failed"
if [ "$fail" -gt 0 ]; then
  echo ""
  echo "Remediation: re-run dialed:setup (idempotent) or fix individual items manually."
  exit 1
fi
exit 0
