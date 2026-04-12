# Troubleshooting

Common failures when running DIALED and how to recover.

## Setup

### `AWS credentials are for account X, not Y`

`bootstrap-state.sh` verifies `sts:GetCallerIdentity` against the expected account before doing anything. Set `AWS_PROFILE` or assume a role in the correct account, then re-run.

### `Error: BucketAlreadyOwnedByYou`

Non-fatal; the bucket exists. Script handles this gracefully (skips creation). If you see it as a hard error, the bucket probably exists in a different region — check AWS console and either delete the stray bucket or adopt the existing one by matching region in `.dialed.yml`.

### Terraform bootstrap: `already exists` on the OIDC provider

An OIDC provider for `token.actions.githubusercontent.com` can only exist once per account. If another tool (or a previous DIALED run on a different project) already created one, re-run bootstrap with `-var='assume_oidc_provider_exists=true'` — the module reuses the existing provider instead of failing.

### `resource "aws_iam_openid_connect_provider" "github": EntityAlreadyExists`

Same root cause. Flip `assume_oidc_provider_exists` to `true` via `terraform apply -var=…` once; subsequent applies are no-ops.

## PR deploys

### `Error: Workspace "dev-pr-42" already exists` on `terraform workspace new`

Harmless. `pr-deploy.yml` uses `terraform workspace select -or-create`, which handles this. If you see it in an older workflow version, upgrade to the v1 template (`dialed:setup` re-run will overwrite).

### PR stack comes up but `wait-ready` fails

Most likely: `stack_url` in `terraform/stack/outputs.tf` is still the default empty value. Set it to reference your API Gateway / Function URL / custom domain. Or override `make wait-ready` for non-HTTP apps.

### `AssumeRoleWithWebIdentity: access denied`

Trust policy mismatch. Check:

- `.dialed.yml`'s `github_repo` matches the actual repo you're pushing to (`owner/name`, case-sensitive).
- The workflow has `permissions: { id-token: write }` at the top.
- For prod: you're pushing to `main`, not a branch. The prod role's trust is pinned to `refs/heads/main`.

Run `dialed:verify` — it checks trust policies against `.dialed.yml`.

## Cleanup

### `Error: DependencyViolation` on `aws_vpc` or subnets during destroy

Something outside Terraform's knowledge is still attached to the VPC — commonly ENIs from a Lambda that was in the VPC. The cleanup Lambda handles this for PR stacks. For the shared VPC itself: check for manually-created resources in the AWS console.

### Workspace stuck in "failed-destroy" state after pr-cleanup

`pr-cleanup.yml` leaves the workspace intact if destroy fails after 3 retries, on the theory that automatic deletion would lose state needed for manual recovery. Steps:

1. `cd terraform/stack`
2. `terraform workspace select dev-pr-<N>`
3. `terraform destroy` (interactive — may reveal a specific resource that's misbehaving)
4. If still stuck: `terraform state list` to see what's left; delete from AWS console and `terraform state rm` the stale entries.
5. Once empty: `terraform workspace select default && terraform workspace delete dev-pr-<N>`.

## Verify

### `✗ IAM role dialed-deploy-dev missing`

Bootstrap didn't run (or ran against a different account). Re-run `dialed:setup` or manually `cd terraform/bootstrap && terraform apply` with the right creds.

### `✗ trust policy does not reference owner/repo`

Happens if `.dialed.yml`'s `github_repo` was edited after setup. Fix: re-run bootstrap with the updated value — `terraform apply` regenerates the trust policy.

### `⊘ role check for env=staging skipped (creds not switched)`

Informational. `dialed:verify` checks the current AWS account only. Switch creds to the other account and re-run to cover all envs.

## Local development

### `terraform: required_version = ">= 1.6"` but local is 1.5.x

DIALED's templates require Terraform 1.6+. Upgrade via `brew upgrade terraform` (via `hashicorp/tap/terraform`) or download from hashicorp.com. Local `make test` skips TF validation gracefully when the version is too old; CI uses 1.6.6.

### `yq: command not found` in scripts

`brew install yq`. The composite action installs it in the runner; the skill scripts assume it's locally available.

### The cleanup Lambda's deployment package is outdated

`terraform/shared/` uses `archive_file` to zip `lambda/cleanup.py` at apply time. If the `.py` source changes and you don't see the Lambda picking it up: re-run `terraform apply` in `terraform/shared/`. The `source_code_hash` changes → Lambda updates.

## Database module (v2)

### `per_pr_database` times out connecting to Postgres

The `cyrilgdn/postgresql` provider tries to TCP-connect to the RDS endpoint on port 5432 during `terraform plan` and `apply`. GitHub-hosted runners are NOT in your VPC by default, so they can't reach a private RDS endpoint.

See `reference-implementation/hello-world/database.md` for the three solution strategies. Quick diagnosis: run `nslookup <rds-endpoint>` from a runner — if it resolves to a private IP (10.x.x.x), the runner can't reach it directly.

### `pr_<N>` database exists but the Lambda sees "no DATABASE_URL"

The Lambda module's `environment.variables.DATABASE_URL` is typically set to `module.per_pr_db[0].connection_string`. Check:

1. Is `per_pr_db` being created? `terraform state list | grep per_pr_db` — if the count expression evaluates to 0, `pr_number` is empty (means this isn't a PR stack).
2. Is DATABASE_URL actually passed to the Lambda? `aws lambda get-function-configuration --function-name <fn> --query 'Environment.Variables' --output json` — confirm `DATABASE_URL` is present and non-empty.

### RDS destroy blocked by `deletion_protection = true`

Happens in prod. Flip `deletion_protection = false` in `terraform/modules/database/main.tf` (or pass `environment != "prod"` temporarily), `terraform apply` to update the instance, THEN destroy. Don't leave deletion protection off permanently.

### Per-PR DB cleanup fails on destroy — `database "pr_42" does not exist`

Means the DB was already dropped by the cleanup Lambda or a previous failed destroy. Run `terraform state rm module.per_pr_db[0].postgresql_database.pr_db` to evict the stale state entry, then re-run `terraform destroy`.

### `cannot drop role pr_42_user` — other objects depend on it

The role owns objects in the database. If the database was dropped but the role wasn't, objects can linger. Connect to the admin DB with the master secret and run:

```sql
REASSIGN OWNED BY pr_42_user TO dialed_admin;
DROP OWNED BY pr_42_user;
DROP ROLE pr_42_user;
```

Then `terraform state rm module.per_pr_db[0].postgresql_role.pr_user` and re-apply.
