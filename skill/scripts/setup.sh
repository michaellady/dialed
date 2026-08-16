#!/usr/bin/env bash
# setup.sh — Mechanical "do the AWS + filesystem work" half of dialed:setup.
#
# Read .dialed.yml from the current directory, copy templates into the
# project, run bootstrap-state.sh per account, and terraform apply on the
# bootstrap module per account. Optionally deploys the shared tier per env.
#
# Idempotent: all steps re-run safely. Interrupting and re-invoking resumes.
#
# Assumes the skill (SKILL.md) has already collected input, written
# .dialed.yml, and gotten user confirmation.

set -euo pipefail

# Resolve DIALED_HOME (symlink-safe)
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

if [ ! -f "$DIALED_HOME/skill/templates/dialed.config.template.yml" ]; then
  echo "ERROR: DIALED_HOME=$DIALED_HOME doesn't look like a dialed checkout." >&2
  exit 1
fi

if [ ! -f .dialed.yml ]; then
  echo "ERROR: .dialed.yml not found at $(pwd)." >&2
  echo "Run dialed:setup interactively first, or author .dialed.yml from the template at" >&2
  echo "  $DIALED_HOME/skill/templates/dialed.config.template.yml" >&2
  exit 1
fi

# ─── Read config ────────────────────────────────────────────────────────────

PROJECT=$(yq -r '.project_name' .dialed.yml)
REGION=$(yq -r '.aws_region' .dialed.yml)
GITHUB_REPO=$(yq -r '.github_repo' .dialed.yml)
ENV_MODEL=$(yq -r '.env_model' .dialed.yml)
NEEDS_VPC=$(yq -r '.needs_vpc' .dialed.yml)
VPC_CIDR=$(yq -r '.vpc_cidr // "10.0.0.0/16"' .dialed.yml)
STALE_WARN=$(yq -r '.enable_stale_pr_warning' .dialed.yml)

# Required status checks for the default-branch protection rule. Contexts are
# workflow JOB names (the `name:` field on a job). Override in .dialed.yml under
# `branch_protection.required_checks: [ ... ]`; otherwise default to the DIALED
# job names. The operator MUST confirm these match the repo's actual check names
# before relying on them — a mistyped context silently never blocks a merge.
mapfile -t REQUIRED_CHECKS < <(yq -r '.branch_protection.required_checks[]?' .dialed.yml 2>/dev/null)
if [ "${#REQUIRED_CHECKS[@]}" -eq 0 ]; then
  REQUIRED_CHECKS=("Unit + integration tests" "Deploy PR stack to dev" "System tests against PR stack")
fi

if [ "$ENV_MODEL" = "3-env" ]; then
  ENVS=(dev staging prod)
else
  ENVS=(dev prod)
fi

# Template filenames drop the hyphen: env_model "2-env"/"3-env" → main-deploy.2env/3env.yml
MODEL_SLUG="${ENV_MODEL//-/}"

declare -A env_to_account
for env in "${ENVS[@]}"; do
  aid=$(yq -r ".account_ids.${env}" .dialed.yml)
  if [ -z "$aid" ] || [ "$aid" = "null" ]; then
    echo "ERROR: account_ids.${env} missing from .dialed.yml" >&2
    exit 1
  fi
  env_to_account[$env]=$aid
done

# Group envs by account (ordered)
declare -A account_envs_ordered
for env in "${ENVS[@]}"; do
  aid="${env_to_account[$env]}"
  account_envs_ordered[$aid]="${account_envs_ordered[$aid]:-} $env"
done

# ─── Copy templates ─────────────────────────────────────────────────────────

echo "==> Copying templates"

mkdir -p .github/workflows .github/actions

cp "$DIALED_HOME/skill/templates/workflows/pr-deploy.yml" .github/workflows/
cp "$DIALED_HOME/skill/templates/workflows/pr-cleanup.yml" .github/workflows/
cp "$DIALED_HOME/skill/templates/workflows/test.yml" .github/workflows/
cp "$DIALED_HOME/skill/templates/workflows/main-deploy.${MODEL_SLUG}.yml" .github/workflows/main-deploy.yml
cp "$DIALED_HOME/skill/templates/workflows/release-summary.yml" .github/workflows/

if [ "$STALE_WARN" = "true" ]; then
  cp "$DIALED_HOME/skill/templates/workflows/pr-stale-warn.yml" .github/workflows/
else
  rm -f .github/workflows/pr-stale-warn.yml
fi

if [ "$NEEDS_VPC" = "true" ]; then
  cp "$DIALED_HOME/skill/templates/workflows/shared-deploy.yml" .github/workflows/
else
  rm -f .github/workflows/shared-deploy.yml
fi

cp -r "$DIALED_HOME/skill/templates/actions/dialed-setup" .github/actions/

mkdir -p terraform
cp -r "$DIALED_HOME/skill/templates/terraform/bootstrap" terraform/
cp -r "$DIALED_HOME/skill/templates/terraform/stack" terraform/

if [ "$NEEDS_VPC" = "true" ]; then
  cp -r "$DIALED_HOME/skill/templates/terraform/shared" terraform/
  mkdir -p terraform/modules
  cp -r "$DIALED_HOME/skill/templates/terraform/modules/network" terraform/modules/
fi

# Project Makefile — generated from the template with project-specific hooks.
"$DIALED_HOME/skill/scripts/render.sh" \
  --in "$DIALED_HOME/skill/templates/Makefile.template" \
  --out Makefile \
  --config .dialed.yml

echo "✓ templates copied"

# ─── Bootstrap per account ──────────────────────────────────────────────────

echo ""
echo "==> Bootstrapping AWS state per account"

for aid in "${!account_envs_ordered[@]}"; do
  envs_in_account="${account_envs_ordered[$aid]# }"  # trim leading space
  echo ""
  echo "─── Account $aid (envs: $envs_in_account) ───"

  # Verify creds match this account
  current_account=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "")
  if [ "$current_account" != "$aid" ]; then
    echo "Current AWS credentials are for account $current_account, not $aid."
    echo "Switch credentials (export AWS_PROFILE=..., or assume a role in $aid) and press Enter."
    read -r
    current_account=$(aws sts get-caller-identity --query Account --output text)
    if [ "$current_account" != "$aid" ]; then
      echo "ERROR: credentials still not for $aid. Aborting." >&2
      exit 1
    fi
  fi

  shared_flag=""
  [ "$NEEDS_VPC" = "true" ] && shared_flag="--shared"

  "$DIALED_HOME/skill/scripts/bootstrap-state.sh" \
    --project "$PROJECT" \
    --account-id "$aid" \
    --region "$REGION" \
    $shared_flag

  # Build JSON list of envs in this account for TF
  envs_json=$(printf '%s\n' $envs_in_account | jq -R . | jq -s -c .)

  pushd terraform/bootstrap >/dev/null

  terraform init -reconfigure -input=false \
    -backend-config="bucket=dialed-${PROJECT}-${aid}-tfstate" \
    -backend-config="key=bootstrap/terraform.tfstate" \
    -backend-config="region=${REGION}" \
    -backend-config="dynamodb_table=dialed-${PROJECT}-${aid}-tflocks" \
    -backend-config="encrypt=true"

  terraform apply -auto-approve -input=false \
    -var="project_name=${PROJECT}" \
    -var="aws_region=${REGION}" \
    -var="github_repo=${GITHUB_REPO}" \
    -var="current_account_id=${aid}" \
    -var="envs_in_this_account=${envs_json}"

  popd >/dev/null
done

# ─── GitHub Environments + default-branch protection ────────────────────────
#
# The deploy roles now trust NARROWED OIDC subjects (see terraform/bootstrap/
# main.tf): prod trusts only `environment:prod`; dev/staging trust
# `pull_request` + `environment:<env>`. That moves the "prod deploys only from
# main" gate OFF the AWS trust policy and ONTO the prod GitHub environment's
# deployment-branch policy — so prod MUST be locked to main here (main-deploy is
# workflow_dispatch-able from ANY branch, so an unlocked prod env would let a
# non-main branch dispatch a prod deploy). dev/staging are created with NO
# branch policy (PR-driven; jobs run from PR branches and main). Finally, protect
# the default branch: require a PR + up-to-date passing status checks to merge.
# All idempotent.

# configure_environments <repo> <env>...
configure_environments() {
  local repo="$1"; shift
  local env
  for env in "$@"; do
    if [ "$env" = "prod" ]; then
      echo ""
      echo "==> Locking prod GitHub environment (${repo}) to 'main'"
      gh api --method PUT "repos/${repo}/environments/prod" \
        -F "deployment_branch_policy[protected_branches]=false" \
        -F "deployment_branch_policy[custom_branch_policies]=true" \
        >/dev/null
      # Add the 'main' policy only if absent — POST is not idempotent (a
      # duplicate name 422s).
      if ! gh api "repos/${repo}/environments/prod/deployment-branch-policies" \
          --jq '.branch_policies[].name' 2>/dev/null | grep -qx main; then
        gh api --method POST "repos/${repo}/environments/prod/deployment-branch-policies" \
          -f name=main >/dev/null
      fi
      echo "✓ prod environment locked to main"
    else
      echo ""
      echo "==> Creating '${env}' GitHub environment (${repo}) — no branch policy"
      # deployment_branch_policy: null → all branches may deploy to this env
      # (PR heads + main). Creating it explicitly (rather than letting the first
      # deploy auto-create it) keeps setup self-contained and idempotent.
      gh api --method PUT "repos/${repo}/environments/${env}" \
        --input - >/dev/null <<'JSON'
{"deployment_branch_policy": null}
JSON
      echo "✓ ${env} environment ready (all branches)"
    fi
  done
}

# configure_branch_protection <repo> <required-check-context>...
configure_branch_protection() {
  local repo="$1"; shift
  local checks=("$@")

  echo ""
  # Branch protection targets an existing branch; on a repo whose 'main' hasn't
  # been pushed yet the API 404s. Skip gracefully rather than aborting setup.
  if ! gh api "repos/${repo}/branches/main" >/dev/null 2>&1; then
    echo "⊘ 'main' not found on ${repo} yet — skipping branch protection."
    echo "  Re-run dialed:setup (idempotent) after your first push, or apply it"
    echo "  by hand (see skill/references/oidc-bootstrap.md)."
    return 0
  fi

  echo "==> Protecting default branch 'main' on ${repo}"
  # Classic branch-protection body. The API requires all four top-level keys
  # (nullable). strict=true → "require branches to be up to date before merging".
  # enforce_admins=false → admins may bypass (flip to true to include them).
  # required_pull_request_reviews with 0 approvals → a PR is required to merge,
  # but no approving review is mandated (suits a solo maintainer; raise the count
  # to require reviews). Idempotent: PUT replaces the whole protection rule.
  local contexts_json
  contexts_json=$(printf '%s\n' "${checks[@]}" | jq -R . | jq -s .)
  jq -n --argjson contexts "$contexts_json" '{
    required_status_checks: { strict: true, contexts: $contexts },
    enforce_admins: false,
    required_pull_request_reviews: { required_approving_review_count: 0 },
    restrictions: null
  }' | gh api --method PUT "repos/${repo}/branches/main/protection" \
        -H "Accept: application/vnd.github+json" --input - >/dev/null

  echo "✓ main protected (PR required; strict status checks: ${checks[*]:-none})"
}

echo ""
echo "==> Configuring GitHub environments + branch protection"
configure_environments "${GITHUB_REPO}" "${ENVS[@]}"
configure_branch_protection "${GITHUB_REPO}" "${REQUIRED_CHECKS[@]}"

# ─── Deploy shared tier per env ─────────────────────────────────────────────

if [ "$NEEDS_VPC" = "true" ]; then
  echo ""
  echo "==> Deploying shared tier (VPC + fck-nat) per env"

  for env in "${ENVS[@]}"; do
    aid="${env_to_account[$env]}"
    echo ""
    echo "─── Shared tier for env=$env account=$aid ───"

    read -r -p "Create VPC + fck-nat for '$env' in $aid? (~\$3-5/mo) [y/N] " confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
      echo "Skipped. You can deploy later by pushing changes to terraform/shared/."
      continue
    fi

    # Verify creds match env's account
    current_account=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "")
    if [ "$current_account" != "$aid" ]; then
      echo "Switch AWS credentials to account $aid and press Enter."
      read -r
    fi

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
fi

echo ""
echo "✓ DIALED setup complete."
echo ""
echo "Next:"
echo "  1. Customize terraform/stack/main.tf (look for '# YOUR RESOURCES HERE')"
echo "  2. Define terraform/stack/outputs.tf's stack_url output"
echo "  3. git add -A && git commit -m 'Add DIALED pipeline' && git push"
echo "  4. Open a test PR against main and confirm pr-deploy runs"
echo "  5. Run dialed:verify anytime to confirm the setup is still sound"
