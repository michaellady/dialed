# Architecture

DIALED is a Claude Code skill that scaffolds GitHub Actions + Terraform + AWS into a project so it gets per-PR ephemeral stacks, staged testing, and dev → prod promotion without reinventing the pattern each time. This doc explains why the pieces are shaped the way they are.

## The pattern, briefly

```
PR open/sync    ────▶  unit+int tests ▶ tf apply (dev-pr-N) ▶ wait-ready ▶ system tests
PR close        ────▶  tf destroy (3 retries) + orphan cleanup Lambda
push to main    ────▶  unit+int ▶ dev ▶ system ▶ [staging ▶ system+smoke] ▶ prod ▶ smoke
cron (daily)    ────▶  comment on PRs idle > N days
path: shared/** ────▶  deploy shared tier per env
```

All wiring runs under AWS OIDC — no long-lived access keys in GitHub. Each env has its own scoped IAM role; trust policies are pinned to the consumer's `owner/repo`.

## Origin

DIALED is a generalization of the pattern in [roxas](https://github.com/michaellady/roxas) — a production Go/Lambda app using dual AWS accounts, shared RDS + VPC, and per-PR ephemeral Lambda stacks. Roxas proved the shape works; DIALED extracts it so the next project doesn't rebuild the scaffolding from scratch.

Key departures from roxas (in `MIGRATING-FROM-ROXAS.md`):

- OIDC instead of static `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`.
- Stack-shape agnostic — DIALED scaffolds the pipeline, the user fills in `terraform/stack/`.
- Single `.dialed.yml` config read by both workflows and Terraform (roxas had values spread across `TF_VAR_*` secrets, hardcoded strings in workflows, and Terraform tfvars).

## Layers

```
.dialed.yml            ← project-specific config (committed, single source of truth)

.github/
  actions/dialed-setup/  ← composite action: load .dialed.yml → derive role ARN → assume → install TF
  workflows/
    pr-deploy          ← per-PR stack: unit+int → apply → wait-ready → system test
    pr-cleanup         ← tf destroy + orphan cleanup on PR close
    pr-stale-warn      ← daily cron: comment on idle PRs
    main-deploy        ← dev → [staging] → prod, fully automated
    shared-deploy      ← path-filtered: apply terraform/shared/** changes
    test               ← fast unit tests on every push

terraform/
  bootstrap/           ← per-account: OIDC provider + deploy roles (one-time)
  shared/              ← per-env: VPC + NAT + (M2: RDS, cache, ...)
    modules/network    ← VPC + fck-nat or managed NAT Gateway
  stack/               ← per-env + per-PR: your app's Terraform
```

## Key design decisions

### Why per-PR Terraform workspaces

Workspace-per-PR (`dev-pr-<N>`) gives state isolation without requiring separate backends. One state bucket per account, one DynamoDB lock table, and workspace selection handles the rest. Destroying a PR's workspace destroys its resources atomically. If we used separate state keys per PR, we'd have to manage per-PR backend objects ourselves.

### Why OIDC

Static IAM keys in GitHub secrets are the most common infrastructure compromise vector in small CI setups. Workflows leak keys via debug output, third-party actions, or misconfigured `pull_request_target` triggers. OIDC replaces long-lived keys with short-lived STS tokens scoped to the specific repo (and for prod, the specific branch). There's no credential to leak.

Trade-off: OIDC requires a one-time bootstrap per AWS account to set up the identity provider and deploy role. DIALED handles that bootstrap mechanically.

### Why single-account mode is supported

Multi-account AWS is the strongest isolation model, but it's overkill for side projects and hackathons. Single-account mode uses IAM conditions (`StringEquals: aws:RequestTag/Env: <env>`) on the per-env deploy roles to prevent the dev role from touching prod resources. Weaker than separate accounts (IAM condition coverage on AWS actions is imperfect), but cheap and still meaningful.

### Why the shared tier is foundational in v1

A fresh VPC per PR takes ~5 minutes to provision and burns VPC quota fast (default 5 per region). A shared VPC per env with per-PR Lambda/ECS resources inside is the only sane pattern. So DIALED creates a VPC at setup (via fck-nat for ~$3-5/mo) whenever `needs_vpc=y`. RDS, caches, queues — those are product decisions and get added later via `dialed:add-module`.

### Why fck-nat as the default NAT

Managed NAT Gateway is ~$32/mo per AZ + data charges — expensive for dev envs that barely egress. fck-nat (single t4g.nano EC2 instance in ASG-of-1) costs ~$3-5/mo and handles the same traffic for most apps. Roxas uses this in production. Projects that outgrow it can flip `nat_mode=managed` in `terraform/shared/main.tf`.

### Why the cleanup Lambda

`terraform destroy` can fail on resources with network interfaces (Lambda in VPC leaves ENIs around briefly) or security groups with cross-references. Retry + exponential backoff handles most cases; the cleanup Lambda is the fallback for the rest. It's deployed as part of the shared tier (has network reachability to delete private-subnet resources), invoked by `pr-cleanup.yml` when TF retries are exhausted.

### Why not plan-on-PR

DIALED's pitch is "see the real stack before merging." Teams that prefer `terraform plan` on PR + manual apply on merge should not use DIALED — the workflows assume apply-on-PR. It's a different philosophy; not wrong, just different.

### Why fully-automated prod deploys

The default `main-deploy` flow goes dev → system → prod → smoke with no human gate. The gate IS the test suite — if unit, integration, and system tests all pass, prod deploys. Projects that want manual prod approval can add a GitHub `environment: prod` protection rule requiring reviewer approval; DIALED doesn't force it.

## Scaling paths

- Need RDS / Postgres per PR? → `dialed:add-module database` (M2 — not yet shipped).
- Need custom modules (Redis, Kafka, your own thing)? → `dialed:add-module --source ./my_module`.
- Started stateless, need a VPC later? → `dialed:add-shared`.
- Want a third env for staging? → Re-run `dialed:setup` with `env_model=3-env`, OR manually add staging workspace + backend HCL + main-deploy-3env workflow.

## What's explicitly out of scope

- Monitoring/observability stacks (CloudWatch dashboards, alarms, Grafana). Documented as recommendations in `anatomy.md`; not generated.
- Budget alerts. Projects should configure AWS Budgets per account themselves.
- Multi-region. DIALED is single-region per project.
- Multi-tenant SaaS (customer-per-account or customer-per-namespace). Pattern-wise distinct from ephemeral PR stacks.
- Rollback tooling beyond `git revert` + re-deploy.
- Language-specific build tooling. Projects wire their own `build_cmd` / `test_*_cmd` in `.dialed.yml`.
