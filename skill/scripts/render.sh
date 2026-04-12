#!/usr/bin/env bash
# render.sh — tiny template renderer. Substitutes {{PLACEHOLDERS}} in a
# source file with values from a .dialed.yml config.
#
# Usage:
#   render.sh --in TEMPLATE --out OUTFILE --config .dialed.yml
#
# Supported placeholders (match the config schema):
#   {{PROJECT_NAME}}        {{AWS_REGION}}        {{GITHUB_REPO}}
#   {{ENV_MODEL}}           {{ACCOUNT_MODEL}}     {{DOMAIN}}
#   {{DEV_ACCOUNT_ID}}      {{STAGING_ACCOUNT_ID}} {{PROD_ACCOUNT_ID}}
#   {{NEEDS_VPC}}           {{VPC_CIDR}}
#   {{ENABLE_STALE_PR_WARNING}}  {{STALE_PR_IDLE_DAYS}}
#   {{BUILD_CMD}}           {{TEST_UNIT_CMD}}
#   {{TEST_INTEGRATION_CMD}} {{TEST_SYSTEM_CMD}} {{TEST_SMOKE_CMD}}
#
# Placeholders for optional fields resolve to empty string when unset.

set -euo pipefail

IN=""
OUT=""
CONFIG=""

while [ $# -gt 0 ]; do
  case "$1" in
    --in) IN="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --config) CONFIG="$2"; shift 2 ;;
    *) echo "unknown flag: $1" >&2; exit 1 ;;
  esac
done

if [ -z "$IN" ] || [ -z "$OUT" ] || [ -z "$CONFIG" ]; then
  echo "usage: $0 --in TEMPLATE --out OUTFILE --config .dialed.yml" >&2
  exit 1
fi

get() { yq -r "$1 // \"\"" "$CONFIG"; }

PROJECT_NAME=$(get '.project_name')
AWS_REGION=$(get '.aws_region')
GITHUB_REPO=$(get '.github_repo')
ENV_MODEL=$(get '.env_model')
ACCOUNT_MODEL=$(get '.account_model')
DOMAIN=$(get '.domain')
DEV_ACCOUNT_ID=$(get '.account_ids.dev')
STAGING_ACCOUNT_ID=$(get '.account_ids.staging')
PROD_ACCOUNT_ID=$(get '.account_ids.prod')
NEEDS_VPC=$(get '.needs_vpc')
VPC_CIDR=$(get '.vpc_cidr')
ENABLE_STALE_PR_WARNING=$(get '.enable_stale_pr_warning')
STALE_PR_IDLE_DAYS=$(get '.stale_pr_idle_days')
BUILD_CMD=$(get '.commands.build')
TEST_UNIT_CMD=$(get '.commands.test_unit')
TEST_INTEGRATION_CMD=$(get '.commands.test_integration')
TEST_SYSTEM_CMD=$(get '.commands.test_system')
TEST_SMOKE_CMD=$(get '.commands.test_smoke')

# Use python3 for substitution — sed/awk choke on values that contain
# shell metacharacters, and envsubst can't do {{BRACES}} natively.
python3 - "$IN" "$OUT" <<EOF
import os, sys, re
src, dst = sys.argv[1], sys.argv[2]
with open(src) as f:
    body = f.read()
replacements = {
    "{{PROJECT_NAME}}": "${PROJECT_NAME}",
    "{{AWS_REGION}}": "${AWS_REGION}",
    "{{GITHUB_REPO}}": "${GITHUB_REPO}",
    "{{ENV_MODEL}}": "${ENV_MODEL}",
    "{{ACCOUNT_MODEL}}": "${ACCOUNT_MODEL}",
    "{{DOMAIN}}": "${DOMAIN}",
    "{{DEV_ACCOUNT_ID}}": "${DEV_ACCOUNT_ID}",
    "{{STAGING_ACCOUNT_ID}}": "${STAGING_ACCOUNT_ID}",
    "{{PROD_ACCOUNT_ID}}": "${PROD_ACCOUNT_ID}",
    "{{NEEDS_VPC}}": "${NEEDS_VPC}",
    "{{VPC_CIDR}}": "${VPC_CIDR}",
    "{{ENABLE_STALE_PR_WARNING}}": "${ENABLE_STALE_PR_WARNING}",
    "{{STALE_PR_IDLE_DAYS}}": "${STALE_PR_IDLE_DAYS}",
    "{{BUILD_CMD}}": r"""${BUILD_CMD}""",
    "{{TEST_UNIT_CMD}}": r"""${TEST_UNIT_CMD}""",
    "{{TEST_INTEGRATION_CMD}}": r"""${TEST_INTEGRATION_CMD}""",
    "{{TEST_SYSTEM_CMD}}": r"""${TEST_SYSTEM_CMD}""",
    "{{TEST_SMOKE_CMD}}": r"""${TEST_SMOKE_CMD}""",
}
for k, v in replacements.items():
    body = body.replace(k, v)
# Warn on any remaining {{PLACEHOLDER}} — usually a typo in the template.
missed = sorted(set(re.findall(r"\{\{[A-Z_]+\}\}", body)))
if missed:
    print("render.sh: WARNING unreplaced placeholders: " + ", ".join(missed), file=sys.stderr)
os.makedirs(os.path.dirname(dst) or ".", exist_ok=True)
with open(dst, "w") as f:
    f.write(body)
EOF

echo "rendered: $IN → $OUT"
