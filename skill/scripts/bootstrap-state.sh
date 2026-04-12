#!/usr/bin/env bash
# bootstrap-state.sh — Idempotently create the S3 state bucket + DynamoDB
# lock table that DIALED's bootstrap Terraform (and all downstream Terraform)
# stores state in.
#
# Uses AWS CLI only — runs BEFORE any Terraform, since `terraform/bootstrap/`
# needs a backend to exist before it can init.
#
# Naming convention (reserved by DIALED, do not collide):
#   State bucket: dialed-{project}-{account}-tfstate
#   Shared-tier state bucket (when --shared): dialed-{project}-{account}-tfstate-shared
#   Lock table: dialed-{project}-{account}-tflocks (shared across app + shared)
#
# Usage:
#   bootstrap-state.sh --project NAME --account-id ID --region REGION [--shared]
#
# Exit codes:
#   0 — all resources exist (created this run or already present)
#   1 — credential mismatch, network failure, or unrecoverable AWS error

set -euo pipefail

PROJECT=""
ACCOUNT_ID=""
REGION=""
CREATE_SHARED=0

while [ $# -gt 0 ]; do
  case "$1" in
    --project) PROJECT="$2"; shift 2 ;;
    --account-id) ACCOUNT_ID="$2"; shift 2 ;;
    --region) REGION="$2"; shift 2 ;;
    --shared) CREATE_SHARED=1; shift ;;
    -h|--help)
      sed -n '2,20p' "$0"
      exit 0
      ;;
    *) echo "unknown flag: $1" >&2; exit 1 ;;
  esac
done

if [ -z "$PROJECT" ] || [ -z "$ACCOUNT_ID" ] || [ -z "$REGION" ]; then
  echo "usage: $0 --project NAME --account-id ID --region REGION [--shared]" >&2
  exit 1
fi

# Verify the credentials actually belong to the account the caller claimed.
caller_account=$(aws sts get-caller-identity --query Account --output text)
if [ "$caller_account" != "$ACCOUNT_ID" ]; then
  echo "ERROR: AWS credentials are for account $caller_account, not $ACCOUNT_ID." >&2
  echo "Set the right AWS_PROFILE / assume-role before re-running." >&2
  exit 1
fi

state_bucket="dialed-${PROJECT}-${ACCOUNT_ID}-tfstate"
shared_bucket="dialed-${PROJECT}-${ACCOUNT_ID}-tfstate-shared"
lock_table="dialed-${PROJECT}-${ACCOUNT_ID}-tflocks"

create_bucket() {
  local bucket="$1"
  if aws s3api head-bucket --bucket "$bucket" 2>/dev/null; then
    echo "✓ bucket exists: $bucket"
    return 0
  fi
  echo "→ creating bucket: $bucket"
  # us-east-1 rejects LocationConstraint; other regions require it.
  if [ "$REGION" = "us-east-1" ]; then
    aws s3api create-bucket --bucket "$bucket" --region "$REGION" >/dev/null
  else
    aws s3api create-bucket --bucket "$bucket" --region "$REGION" \
      --create-bucket-configuration "LocationConstraint=$REGION" >/dev/null
  fi
  aws s3api put-bucket-versioning --bucket "$bucket" \
    --versioning-configuration Status=Enabled >/dev/null
  aws s3api put-bucket-encryption --bucket "$bucket" \
    --server-side-encryption-configuration \
      '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}' >/dev/null
  aws s3api put-public-access-block --bucket "$bucket" \
    --public-access-block-configuration \
      'BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true' >/dev/null
  echo "✓ bucket ready: $bucket"
}

create_lock_table() {
  local table="$1"
  if aws dynamodb describe-table --table-name "$table" --region "$REGION" >/dev/null 2>&1; then
    echo "✓ lock table exists: $table"
    return 0
  fi
  echo "→ creating lock table: $table"
  aws dynamodb create-table \
    --table-name "$table" \
    --region "$REGION" \
    --attribute-definitions AttributeName=LockID,AttributeType=S \
    --key-schema AttributeName=LockID,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST >/dev/null
  aws dynamodb wait table-exists --table-name "$table" --region "$REGION"
  echo "✓ lock table ready: $table"
}

create_bucket "$state_bucket"
if [ "$CREATE_SHARED" -eq 1 ]; then
  create_bucket "$shared_bucket"
fi
create_lock_table "$lock_table"

echo ""
echo "Bootstrap state ready in account $ACCOUNT_ID ($REGION):"
echo "  state_bucket:  $state_bucket"
if [ "$CREATE_SHARED" -eq 1 ]; then
  echo "  shared_bucket: $shared_bucket"
fi
echo "  lock_table:    $lock_table"
