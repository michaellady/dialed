# OIDC bootstrap — manual recovery steps

`dialed:setup` automates OIDC setup. If it fails partway (network, permissions, partial apply), here's how to finish it by hand or nuke it and re-run.

## What bootstrap creates

Per AWS account:

1. GitHub OIDC identity provider (`token.actions.githubusercontent.com`, thumbprint `6938fd4d98bab03faadb97b34396831e3780aea1`, audience `sts.amazonaws.com`).
2. One IAM role per env that lives in this account — named `dialed-{project}-deploy-{env}` under path `/dialed/` (project-namespaced so multiple DIALED services can share one account; services bootstrapped before this change use the legacy `dialed-deploy-{env}` name).
3. Each role has:
   - Trust policy federating GitHub OIDC for the specific repo.
   - Managed policy: `PowerUserAccess`.
   - Inline policy: scoped IAM actions on project-owned roles, with the role-mutation actions gated on `iam:PermissionsBoundary`.
4. One IAM permissions boundary per account — `dialed-{project}-boundary` (Deny `iam:*`/`organizations:*`/`account:*`, Allow `*`). Every `{project}-*` role the deploy role mints must carry it.

## Fully manual bootstrap

If `terraform/bootstrap/` is unusable (state corrupted, something weird), do this in each account via AWS CLI:

```bash
# 1. Create the OIDC provider (skip if it already exists)
aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com \
  --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1

# 2. For each env (dev, staging, prod) that lives in this account,
#    create a role with the trust policy pinned to your repo.
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
GITHUB_REPO="owner/name"
PROJECT="your-project"  # .dialed.yml project_name; namespaces the role
ENV="dev"  # repeat for staging, prod

cat > /tmp/trust.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Federated": "arn:aws:iam::${ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com" },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": { "token.actions.githubusercontent.com:aud": "sts.amazonaws.com" },
      "StringLike": { "token.actions.githubusercontent.com:sub": "repo:${GITHUB_REPO}:*" }
    }
  }]
}
EOF

# For prod, replace the StringLike with BOTH the main ref and the
# environment:prod subject — a job that declares `environment: prod` emits the
# latter, not a ref, so a role trusting only the ref form fails to assume:
#   "StringLike": { "token.actions.githubusercontent.com:sub": [
#     "repo:${GITHUB_REPO}:ref:refs/heads/main",
#     "repo:${GITHUB_REPO}:environment:prod"
#   ] }
# Trusting environment:prod means the main-only gate is no longer in this trust
# policy — you MUST lock the prod GitHub environment to main (see below).

aws iam create-role \
  --role-name dialed-${PROJECT}-deploy-${ENV} \
  --path /dialed/ \
  --assume-role-policy-document file:///tmp/trust.json \
  --tags Key=ManagedBy,Value=dialed Key=Project,Value=${PROJECT} Key=Env,Value=${ENV}

aws iam attach-role-policy \
  --role-name dialed-${PROJECT}-deploy-${ENV} \
  --policy-arn arn:aws:iam::aws:policy/PowerUserAccess

# Inline policy — scoped IAM. Mirror bootstrap/main.tf's iam_scoped block
# (including the three-way split gating role mutations on iam:PermissionsBoundary).
aws iam put-role-policy \
  --role-name dialed-${PROJECT}-deploy-${ENV} \
  --policy-name dialed-iam-scoped \
  --policy-document file:///tmp/iam-scoped.json

# Permissions boundary — create once per account. Mirror bootstrap/boundary.tf.
aws iam create-policy \
  --policy-name dialed-${PROJECT}-boundary \
  --policy-document file:///tmp/boundary.json

rm /tmp/trust.json /tmp/iam-scoped.json /tmp/boundary.json
```

`iam-scoped.json` content matches the inline policy in `terraform/bootstrap/main.tf` and `boundary.json` matches `terraform/bootstrap/boundary.tf` — copy them verbatim with the placeholders filled.

## Lock the prod GitHub environment to main (REQUIRED)

The prod deploy role trusts the `environment:prod` OIDC subject so that the
`deploy-prod` job — which declares `environment: prod` — can assume it. That
subject is emitted by the job regardless of which branch it runs on, and
`main-deploy` is `workflow_dispatch`-able from **any** branch. So the branch
restriction for prod is **not** in the AWS trust policy; it lives in the prod
GitHub environment's deployment-branch policy. `dialed:setup` does this
automatically; to (re)assert it by hand:

```bash
# Enable custom branch policies on the prod environment (creates it if absent)
gh api -X PUT "repos/OWNER/REPO/environments/prod" \
  -F "deployment_branch_policy[protected_branches]=false" \
  -F "deployment_branch_policy[custom_branch_policies]=true"

# Allow only 'main' to deploy to prod
gh api -X POST "repos/OWNER/REPO/environments/prod/deployment-branch-policies" \
  -f name=main
```

Verify:

```bash
gh api "repos/OWNER/REPO/environments/prod/deployment-branch-policies" \
  --jq '.branch_policies[].name'   # must print exactly: main
```

Without this, a non-main branch can `workflow_dispatch` `main-deploy`, hit the
`deploy-prod` job, present the trusted `environment:prod` subject, and deploy
non-main code to prod.

## Nuke and re-bootstrap

If the partial state is unrecoverable:

```bash
# Delete roles (idempotent). PROJECT is your .dialed.yml project_name; drop the
# "${PROJECT}-" segment for services bootstrapped before role-name namespacing.
PROJECT="your-project"
for env in dev staging prod; do
  aws iam detach-role-policy --role-name dialed-${PROJECT}-deploy-$env --policy-arn arn:aws:iam::aws:policy/PowerUserAccess 2>/dev/null || true
  aws iam delete-role-policy --role-name dialed-${PROJECT}-deploy-$env --policy-name dialed-iam-scoped 2>/dev/null || true
  aws iam delete-role --role-name dialed-${PROJECT}-deploy-$env 2>/dev/null || true
done

# Delete the permissions boundary (only after every ${PROJECT}-* role that used
# it is gone, else DeletePolicy fails with "policy in use").
aws iam delete-policy --policy-arn arn:aws:iam::${ACCOUNT_ID}:policy/dialed-${PROJECT}-boundary 2>/dev/null || true

# Delete OIDC provider (only if no other tools depend on it — shared per account)
aws iam delete-open-id-connect-provider \
  --open-id-connect-provider-arn arn:aws:iam::${ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com

# Delete Terraform state + lock entries
aws s3 rm s3://dialed-{project}-{account}-tfstate/bootstrap/terraform.tfstate
aws s3api delete-object --bucket dialed-{project}-{account}-tfstate --key bootstrap/terraform.tfstate

# Re-run dialed:setup
```

## Why the thumbprint matters

GitHub Actions' OIDC token is signed by a certificate. AWS verifies the cert chain against the thumbprint list in the OIDC provider. `6938fd4d98bab03faadb97b34396831e3780aea1` is GitHub's published thumbprint as of 2024. If GitHub rotates their cert, you'll need to update the thumbprint — watch [github/security-advisories](https://github.com/github/docs/issues) for announcements.

## Checking OIDC claims from a running workflow

If workflows are failing with `AssumeRoleWithWebIdentity: access denied`, dump the token claims to debug:

```yaml
- name: Debug OIDC token
  run: |
    TOKEN=$(curl -sSL -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
      "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=sts.amazonaws.com" | jq -r .value)
    echo "$TOKEN" | cut -d. -f2 | base64 -d | jq .
```

Check the `sub` claim against your role's trust policy `StringLike` condition.
