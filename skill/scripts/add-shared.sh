#!/usr/bin/env bash
# add-shared.sh — Retrofit path. Adds a shared tier to a DIALED project that
# originally set needs_vpc=false.
#
# Assumes the SKILL.md has already flipped needs_vpc=true in .dialed.yml
# and confirmed with the user.

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

[ -f .dialed.yml ] || { echo "ERROR: .dialed.yml missing" >&2; exit 1; }

NEEDS_VPC=$(yq -r '.needs_vpc' .dialed.yml)
if [ "$NEEDS_VPC" != "true" ]; then
  echo "ERROR: needs_vpc is not true in .dialed.yml. The skill should have flipped it before calling this script." >&2
  exit 1
fi

PROJECT=$(yq -r '.project_name' .dialed.yml)
REGION=$(yq -r '.aws_region' .dialed.yml)
ENV_MODEL=$(yq -r '.env_model' .dialed.yml)
VPC_CIDR=$(yq -r '.vpc_cidr // "10.0.0.0/16"' .dialed.yml)

if [ "$ENV_MODEL" = "3-env" ]; then
  ENVS=(dev staging prod)
else
  ENVS=(dev prod)
fi

declare -A env_to_account
for env in "${ENVS[@]}"; do
  env_to_account[$env]=$(yq -r ".account_ids.${env}" .dialed.yml)
done

echo "==> Copying shared-tier templates"
[ ! -d terraform/shared ] && cp -r "$DIALED_HOME/skill/templates/terraform/shared" terraform/
[ ! -d terraform/modules/network ] && { mkdir -p terraform/modules; cp -r "$DIALED_HOME/skill/templates/terraform/modules/network" terraform/modules/; }
[ ! -f .github/workflows/shared-deploy.yml ] && cp "$DIALED_HOME/skill/templates/workflows/shared-deploy.yml" .github/workflows/

echo ""
echo "==> Bootstrapping shared state + deploying per env"

for env in "${ENVS[@]}"; do
  aid="${env_to_account[$env]}"
  echo ""
  echo "─── env=$env account=$aid ───"

  current=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "")
  if [ "$current" != "$aid" ]; then
    echo "Switch AWS credentials to account $aid and press Enter (or Ctrl+C to skip this env)."
    read -r
    current=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "")
    if [ "$current" != "$aid" ]; then
      echo "Creds still not for $aid — skipping $env."
      continue
    fi
  fi

  "$DIALED_HOME/skill/scripts/bootstrap-state.sh" \
    --project "$PROJECT" \
    --account-id "$aid" \
    --region "$REGION" \
    --shared

  pushd terraform/shared >/dev/null

  terraform init -reconfigure -input=false \
    -backend-config="bucket=dialed-${PROJECT}-${aid}-tfstate-shared" \
    -backend-config="key=shared/terraform.tfstate" \
    -backend-config="region=${REGION}" \
    -backend-config="dynamodb_table=dialed-${PROJECT}-${aid}-tflocks" \
    -backend-config="encrypt=true"

  terraform workspace select -or-create "$env"

  terraform apply -auto-approve -input=false \
    -var="project_name=${PROJECT}" \
    -var="aws_region=${REGION}" \
    -var="environment=${env}" \
    -var="vpc_cidr=${VPC_CIDR}"

  popd >/dev/null
done

echo ""
echo "✓ Shared tier added. Commit terraform/shared/, terraform/modules/network/, and .github/workflows/shared-deploy.yml and push."
echo "  Your next terraform apply on terraform/stack/ will pick up the shared VPC automatically."
