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
# Each command also has a {{..._CMD_MK}} variant (e.g. {{BUILD_CMD_MK}}) that
# renders the command as a single-quoted, Make-escaped shell literal — use
# these inside Makefile recipes; use the plain form in YAML/plain contexts.
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

# Substitute placeholders with python3. Values are passed via the ENVIRONMENT
# (not interpolated into the script text) and the heredoc is quoted (<<'EOF'),
# so a value containing quotes, $, backslashes, or """ can't corrupt the
# renderer. sed/awk choke on such values and envsubst can't do {{BRACES}}.
DIALED_PROJECT_NAME="$PROJECT_NAME" \
DIALED_AWS_REGION="$AWS_REGION" \
DIALED_GITHUB_REPO="$GITHUB_REPO" \
DIALED_ENV_MODEL="$ENV_MODEL" \
DIALED_ACCOUNT_MODEL="$ACCOUNT_MODEL" \
DIALED_DOMAIN="$DOMAIN" \
DIALED_DEV_ACCOUNT_ID="$DEV_ACCOUNT_ID" \
DIALED_STAGING_ACCOUNT_ID="$STAGING_ACCOUNT_ID" \
DIALED_PROD_ACCOUNT_ID="$PROD_ACCOUNT_ID" \
DIALED_NEEDS_VPC="$NEEDS_VPC" \
DIALED_VPC_CIDR="$VPC_CIDR" \
DIALED_ENABLE_STALE_PR_WARNING="$ENABLE_STALE_PR_WARNING" \
DIALED_STALE_PR_IDLE_DAYS="$STALE_PR_IDLE_DAYS" \
DIALED_BUILD_CMD="$BUILD_CMD" \
DIALED_TEST_UNIT_CMD="$TEST_UNIT_CMD" \
DIALED_TEST_INTEGRATION_CMD="$TEST_INTEGRATION_CMD" \
DIALED_TEST_SYSTEM_CMD="$TEST_SYSTEM_CMD" \
DIALED_TEST_SMOKE_CMD="$TEST_SMOKE_CMD" \
python3 - "$IN" "$OUT" <<'EOF'
import os, sys, re
src, dst = sys.argv[1], sys.argv[2]
with open(src) as f:
    body = f.read()

E = os.environ


def mk(v):
    # Render a shell command as a single-quoted, Make-escaped literal, safe to
    # drop straight after `cmd=` in a Makefile recipe. Two hazards handled:
    #   1. Make eats a single '$' in recipes, so double it — Make then passes a
    #      literal '$' to the shell and runtime vars (e.g. STACK_URL) expand at
    #      `eval` time, not render time.
    #   2. Embedded quotes/spaces would break a bare/double-quoted value, so
    #      wrap in single quotes and '-escape any embedded single quote.
    # Empty command -> '' , which falls through to the recipe's "no command
    # configured" branch.
    return "'" + v.replace("$", "$$").replace("'", "'\\''") + "'"


# Simple 1:1 placeholders.
replacements = {
    "{{PROJECT_NAME}}": E["DIALED_PROJECT_NAME"],
    "{{AWS_REGION}}": E["DIALED_AWS_REGION"],
    "{{GITHUB_REPO}}": E["DIALED_GITHUB_REPO"],
    "{{ENV_MODEL}}": E["DIALED_ENV_MODEL"],
    "{{ACCOUNT_MODEL}}": E["DIALED_ACCOUNT_MODEL"],
    "{{DOMAIN}}": E["DIALED_DOMAIN"],
    "{{DEV_ACCOUNT_ID}}": E["DIALED_DEV_ACCOUNT_ID"],
    "{{STAGING_ACCOUNT_ID}}": E["DIALED_STAGING_ACCOUNT_ID"],
    "{{PROD_ACCOUNT_ID}}": E["DIALED_PROD_ACCOUNT_ID"],
    "{{NEEDS_VPC}}": E["DIALED_NEEDS_VPC"],
    "{{VPC_CIDR}}": E["DIALED_VPC_CIDR"],
    "{{ENABLE_STALE_PR_WARNING}}": E["DIALED_ENABLE_STALE_PR_WARNING"],
    "{{STALE_PR_IDLE_DAYS}}": E["DIALED_STALE_PR_IDLE_DAYS"],
}

# Command placeholders get two forms: the plain value (for YAML/plain contexts
# like dialed.config.template.yml) and a {{..._MK}} Makefile-recipe-safe literal.
commands = {
    "BUILD_CMD": E["DIALED_BUILD_CMD"],
    "TEST_UNIT_CMD": E["DIALED_TEST_UNIT_CMD"],
    "TEST_INTEGRATION_CMD": E["DIALED_TEST_INTEGRATION_CMD"],
    "TEST_SYSTEM_CMD": E["DIALED_TEST_SYSTEM_CMD"],
    "TEST_SMOKE_CMD": E["DIALED_TEST_SMOKE_CMD"],
}
for name, val in commands.items():
    replacements["{{" + name + "}}"] = val
    replacements["{{" + name + "_MK}}"] = mk(val)

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
