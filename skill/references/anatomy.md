# Anatomy — what every generated file does

When `dialed:setup` finishes, your project has a lot of new files. Here's what each one is for, so editing them is safe.

## Root

| File | Purpose | Safe to edit? |
|---|---|---|
| `.dialed.yml` | Single source of truth. Every workflow + Terraform call reads it. | Yes, carefully. Re-run `dialed:verify` after editing. |
| `Makefile` | Project-level commands (build, test-*, wait-ready, tf-*). Rendered once at setup; not re-rendered later unless you re-run setup. | Yes — it's yours now. |

## `.github/workflows/`

| File | Trigger | What it does |
|---|---|---|
| `pr-deploy.yml` | PR open/sync (target: main) | unit+int → tf apply workspace=dev-pr-N → wait-ready → system tests, comments on PR with stack URL. |
| `pr-cleanup.yml` | PR close | tf destroy (3 retries) → delete workspace. Invokes cleanup Lambda if destroy fails. |
| `pr-stale-warn.yml` | Daily cron | Comments on PRs idle > N days. |
| `shared-deploy.yml` | Path filter on `terraform/shared/**` + manual | Deploys shared tier per env. Skips envs where creds aren't configured. |
| `main-deploy.yml` | Push to main | dev → system → [staging → system+smoke] → prod → smoke. Fully automated. |
| `test.yml` | Every push + PR | Unit tests only (no AWS). Fast feedback. |

Edits to the generated workflows are yours to make, but remember they won't re-render if you re-run setup — setup regenerates them from templates, overwriting any edits. Consider committing your edits to the dialed repo's templates instead.

## `.github/actions/dialed-setup/action.yml`

Composite action. Reads `.dialed.yml`, derives `DIALED_ROLE_ARN = arn:aws:iam::{account_ids[env]}:role/dialed/dialed-{project_name}-deploy-{env}`, assumes it, installs Terraform, exports env vars. Used by every deploy workflow.

**Environment variables exported:**
- `DIALED_PROJECT_NAME`, `DIALED_ACCOUNT_ID`, `DIALED_ROLE_ARN`, `DIALED_WORKSPACE`, `DIALED_ENV`, `DIALED_DOMAIN`
- `AWS_REGION`, `TF_WORKSPACE`
- `DIALED_BUILD_CMD`, `DIALED_TEST_UNIT_CMD`, `DIALED_TEST_INTEGRATION_CMD`, `DIALED_TEST_SYSTEM_CMD`, `DIALED_TEST_SMOKE_CMD`

## `terraform/bootstrap/`

One-time setup per AWS account. Creates the GitHub OIDC identity provider, the per-env `dialed-{project_name}-deploy-<env>` IAM roles (project-namespaced so multiple DIALED services can share one account), and the `dialed-{project_name}-boundary` permissions boundary. Trust is scoped to `github_repo` AND narrowed to the exact OIDC subjects DIALED jobs emit — prod trusts only `environment:prod`; dev/staging trust `pull_request` + `environment:<env>` (no `repo:*` wildcard, no bare `ref:refs/heads/main`), so a comment-triggered / main-branch bot can't assume a deploy role. The prod "only from main" gate therefore lives in the prod GitHub environment's deployment-branch policy (`dialed:setup` locks it to main), not the trust policy. After bootstrap completes once per account, don't touch this unless you're changing the trust policy or role permissions.

Permissions: `PowerUserAccess` (no IAM user management) + scoped inline IAM policy allowing the role to manage project-owned IAM roles + instance profiles (needed for Lambda execution roles), with explicit deny on `iam:*User*` and `organizations:*`. The role-mutation grants are gated on `iam:PermissionsBoundary` — every `{project}-*` role the deploy role mints MUST carry `dialed-{project}-boundary` (Deny `iam:*`/`organizations:*`/`account:*`, Allow `*`), so a compromised deploy role can't create an Administrator-escalatable role. `iam:PassRole` is pinned to `lambda.amazonaws.com` + `ec2.amazonaws.com`. See `terraform/bootstrap/boundary.tf`.

## `terraform/shared/`

Long-lived per-env infrastructure. Own Terraform state (different bucket from `terraform/stack/`). Created when `needs_vpc=y` at setup; added post-hoc by `dialed:add-shared`.

- `main.tf`: composes modules. Ships wired to `modules/network`. Product modules (`database` etc.) added later via `dialed:add-module`.
- `cleanup_lambda.tf`: Python Lambda that deletes orphan ENIs + security groups tagged with a PR's workspace. Invoked by `pr-cleanup.yml` when `tf destroy` fails.

Outputs (the PR-stack contract): `vpc_id`, `vpc_cidr_block`, `public_subnet_ids`, `private_subnet_ids`, `availability_zones`, `nat_security_group_id`, `cleanup_lambda_name`. M2 adds database outputs.

## `terraform/modules/network/`

VPC + public/private subnets + IGW + route tables + NAT egress.

- `nat_mode = "fck-nat"` (default): t4g.nano EC2 in ASG-of-1 via `RaJiska/fck-nat/aws`. ~$3-5/mo.
- `nat_mode = "managed"`: AWS NAT Gateway + EIP. ~$32/mo per AZ + data. HA.

## `terraform/modules/database/` (v2, optional)

Present after `dialed:add-module database`. RDS Postgres instance — default db.t4g.micro, 20GB gp3, single-AZ, 7-day backups. Master credentials auto-generated and stored in Secrets Manager. `multi_az`, `instance_class`, `backup_retention_days` knobs in the module block under `terraform/shared/main.tf` — bump for prod.

Per-env behavior: prod gets `deletion_protection=true` and a final snapshot on destroy; dev/staging skip the final snapshot so teardown is fast.

Outputs exposed through `terraform/shared/outputs.tf`: `database_endpoint`, `database_port`, `database_name`, `database_master_secret_arn`, `database_security_group_id`. PR stacks and app stacks consume these via `data.terraform_remote_state.shared`.

## `terraform/modules/per_pr_database/` (v2, optional, stack-side)

Installed alongside `modules/database/`. This one lives at the **stack layer** — it's invoked by `terraform/stack/main.tf` from a conditional block that activates only on PR stacks (`count = var.pr_number != "" ? 1 : 0`). Creates a Postgres logical database `pr_<N>` and a scoped role inside the shared RDS cluster, drops both on destroy.

Uses `cyrilgdn/postgresql` provider → requires network reachability from the GitHub runner to the RDS endpoint. Three strategies (SSM tunnel, temporary public subnet, self-hosted runner) documented in `reference-implementation/hello-world/database.md`.

Outputs: `database_name`, `username`, `password` (sensitive), `connection_string` (sensitive). Typical consumer: Lambda `environment.variables.DATABASE_URL`.

## `terraform/stack/`

Your app's per-env Terraform. Runs once per env (`dev`, `staging`, `prod`) and once per open PR (`dev-pr-N`). State shared across workspaces in one bucket.

- `main.tf`: `YOUR RESOURCES HERE` marker. Reads shared state via `data.terraform_remote_state.shared` (when `needs_vpc=y`).
- `tags.tf`: `default_tags` on the AWS provider. Every resource gets `ManagedBy=dialed`, `Project`, `Env`, `Workspace`, `PR`, `Tier=app`.
- `outputs.tf`: `stack_url` contract — the URL system tests hit. Set this.

## Naming conventions DIALED claims

Don't collide with these — DIALED creates and manages them:

- S3 buckets: `dialed-{project}-{account}-tfstate`, `dialed-{project}-{account}-tfstate-shared`.
- DynamoDB tables: `dialed-{project}-{account}-tflocks`.
- IAM roles: `dialed-{project}-deploy-{env}` under path `/dialed/`.
- IAM permissions boundary: `dialed-{project}-boundary` (caps every `{project}-*` role).
- IAM OIDC provider: `token.actions.githubusercontent.com` (one per account, shared if another tool already made it — set `assume_oidc_provider_exists=true`).
- TF workspaces: `dev`, `staging`, `prod`, `dev-pr-<N>`.
- Lambdas: `dialed-{project}-cleanup-{env}`.

## Single-account IAM scoping (account_model=1)

The deploy roles use IAM conditions to prevent cross-env access:

```
Condition: {
  StringEquals: {
    "aws:RequestTag/Env": "dev"   // or staging, or prod
  }
}
```

Every resource DIALED creates gets `Env={env}` via `default_tags` on the provider. PR stacks also get `Env=dev` (not `Env=dev-pr-42`) so the IAM condition is a clean exact-match; workspace-level granularity is preserved via a separate `Workspace` tag.

IAM conditions on `aws:RequestTag/Env` are best-effort: not every AWS action supports tag-based conditions, and some resources are scoped differently. For hard multi-account isolation, use `account_model=2` or `3`.

## What's NOT in the generated project

- Monitoring dashboards, CloudWatch alarms — author these yourself in `terraform/stack/`.
- AWS Budgets — configure per account.
- Secrets management beyond OIDC — use AWS Secrets Manager references in your stack.
- Language-specific build tooling — configure via `.dialed.yml` `commands.*`.
