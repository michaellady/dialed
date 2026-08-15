---
name: dialed:setup
description: Bootstrap GitHub Actions + Terraform + AWS OIDC deploy pipeline in a project using DIALED. Per-PR ephemeral stacks, staged testing, dev→prod promotion. Triggers - "set up dialed", "dialed setup", "add deploy pipeline", "bootstrap CI/CD for this project".
---

# dialed:setup

Scaffolds a DIALED-ified project in the current working directory. Writes `.dialed.yml`, copies workflows + Terraform templates, bootstraps AWS OIDC, and optionally provisions a shared VPC per env.

Run this in the target project's root directory — **NOT** in the dialed repo itself.

## Preconditions (fail fast, before any questions)

1. `pwd` is a git repo: `git rev-parse --is-inside-work-tree` must succeed.
2. `pwd` is not the dialed repo itself: `[ "$(pwd)" != "$DIALED_HOME" ]`.
3. `.dialed.yml` doesn't already exist. If it does, ask: "This project already has DIALED set up. Re-run setup (idempotent), or switch to `dialed:verify`?"
4. Prerequisites installed: `aws --version`, `terraform version`, `yq --version`, `gh --version`, `jq --version`, `actionlint --version`. On any missing, print `$DIALED_HOME/docs/PREREQUISITES.md` and stop.
5. `DIALED_HOME` resolves to a valid dialed checkout — defaults to `~/dev/dialed`. Verify `$DIALED_HOME/skill/templates/dialed.config.template.yml` exists.
6. AWS credentials work: `aws sts get-caller-identity` returns a result. If not, tell the user to set up credentials first.

## Collect configuration

Ask the user **one question at a time**, using AskUserQuestion where multiple-choice fits. Infer sensible defaults and present them.

Questions, in order:

1. **project_name** — lowercase, hyphens only, 3–30 chars. Default: `basename "$(pwd)"` (slugified).
2. **aws_region** — e.g. `us-east-1`, `us-west-2`.
3. **github_repo** — `owner/name` form. Default: parse from `git remote get-url origin`.
4. **env_model** — `2-env` (dev+prod, default) or `3-env` (dev+staging+prod).
5. **account_model** — `1`, `2`, or `3`. Constraint: `account_model ≤ env count`. Default `2`. Common pairings to present:
   - 2-env + 1-account: both envs in one account (tag-based isolation).
   - 2-env + 2-account: dev account, prod account (default, strongest isolation).
   - 3-env + 2-account: dev+staging share, prod separate.
   - 3-env + 3-account: one account per env.
6. **AWS account IDs** — ask once per distinct account slot. E.g. for 2-env + 2-account: ask `dev_account_id` and `prod_account_id`. For 3-env + 1-account: ask once.
7. **domain** — optional. Used for per-PR URLs like `pr-<N>.<domain>`. Empty if none.
8. **enable_stale_pr_warning** — y/n, default y. Daily cron that comments on PRs idle > N days.
9. **stale_pr_idle_days** — integer, default 7. Only asked if enable_stale_pr_warning=y.
10. **needs_vpc** — y/n, default y. When y: foundational VPC + fck-nat per env (~$3-5/mo/env). Needed if your app has any resources that live in a VPC (Lambda-in-VPC, ECS, EC2, RDS, ...).
11. **vpc_cidr** — default `10.0.0.0/16`. Only asked if needs_vpc=y.
12. **build_cmd** — shell string, e.g. `make build`, `npm run build`, `go build ./...`. Can be empty if nothing to build.
13. **test_unit_cmd**, **test_integration_cmd**, **test_system_cmd**, **test_smoke_cmd** — each a shell string, each can be empty. System + smoke get `$STACK_URL` exported by the workflow.

## Confirm before creating AWS resources

Before running any AWS commands, summarize the plan for the user and wait for explicit "yes". Include:

- Which accounts get bootstrapped (S3 bucket + DynamoDB table created in each).
- Which accounts get an OIDC IAM role set (one `dialed-deploy-{env}` per env).
- That the prod GitHub environment will be created (if absent) and locked to `main` — the branch gate for prod deploys.
- If needs_vpc=y: which envs get a VPC created (list with estimated cost: ~$3-5/mo per env with fck-nat, ~$32/mo per env if nat_mode=managed later).
- Total rough monthly cost estimate.

## Write .dialed.yml

Use the Write tool to create `.dialed.yml` at the project root from the collected answers. Structure matches `$DIALED_HOME/skill/templates/dialed.config.template.yml` — same field names, same nesting.

## Execute setup.sh

Run:

```
bash "$DIALED_HOME/skill/scripts/setup.sh"
```

Stream its output. It will:

1. Copy workflow templates into `.github/workflows/`.
2. Copy the `dialed-setup` composite action into `.github/actions/dialed-setup/`.
3. Copy Terraform templates: `terraform/bootstrap/`, `terraform/stack/`, and if `needs_vpc=y`: `terraform/shared/` + `terraform/modules/network/`.
4. Generate a project `Makefile` with the minimum contract targets (`wait-ready`, `test-*` stubs that call the config commands).
5. For each distinct account ID in `.dialed.yml`, prompt the user to switch AWS credentials to that account, then run:
   - `scripts/bootstrap-state.sh` (idempotent S3 + DDB creation)
   - `terraform apply` on `terraform/bootstrap/` (OIDC provider + deploy roles)
6. Lock the prod GitHub environment to `main` via `gh api` (creates the `prod`
   environment if absent, enables custom branch policies, allows only `main`).
   This is the branch gate for prod: the prod deploy role trusts the
   `environment:prod` OIDC subject, so main-only is enforced here, not in the
   AWS trust policy. Idempotent.
7. If `needs_vpc=y`, for each env, switch credentials to its account and run `terraform apply` on `terraform/shared/` after confirming cost.

## After setup.sh succeeds

Print this checklist and stop:

1. Review the generated files. The biggest one to customize is `terraform/stack/main.tf` (look for the `# YOUR RESOURCES HERE` marker) and `terraform/stack/outputs.tf` (define `stack_url`).
2. Commit: `git add -A && git commit -m "Add DIALED deploy pipeline" && git push`.
3. Open a test PR against `main` and confirm `pr-deploy` runs, deploys, and comments with a stack URL.
4. Re-run `dialed:verify` anytime to confirm the setup is still consistent.

## If setup fails partway

`setup.sh` is idempotent. Fix the underlying issue (permissions, bad account ID, AWS credentials not for the right account) and re-run. `bootstrap-state.sh` skips resources that already exist; `terraform apply` naturally handles re-runs.
