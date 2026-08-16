# DIALED

**D**eploying **I**nfrastructure with **A** **L**ow **E**ffort **D**elivery.

A Claude Code skill that bootstraps GitHub Actions + Terraform + AWS deployment pipelines for any project: per-PR ephemeral stacks, staged testing, and automated dev → prod promotion on merge.

## What you get

- **Per-PR stacks.** Every PR gets its own isolated Terraform workspace in the dev AWS account. Open a PR, a real stack comes up; close the PR, it tears down.
- **Staged tests.** Unit + integration pre-deploy (fast fail), system tests against the live PR stack, smoke tests post-prod.
- **Dev → prod promotion.** Merge to main auto-deploys through dev (and optionally staging) into prod.
- **AWS OIDC, least-privilege.** No long-lived access keys in GitHub secrets. Deploy-role trust is narrowed to the exact OIDC subjects DIALED jobs emit (prod: `environment:prod` only; dev/staging: `pull_request` + `environment:<env>`), so a comment-triggered / main-branch bot can't assume a deploy role.
- **Environment + branch gating.** Setup creates GitHub Environments (prod locked to `main`, the branch gate for prod deploys) and a default-branch protection rule (PR + up-to-date passing checks required to merge).
- **Foundational VPC included.** Shared network tier with fck-nat (~$3–5/mo) so PR stacks can live inside a long-lived VPC without re-creating one each time.

Stack-shape agnostic — DIALED scaffolds the pipeline and the wiring; you fill in the Terraform for whatever your app actually is.

## Install

```
make install-skill
```

Then in any project:

```
dialed:setup
```

## Status

Early development. See `docs/ARCHITECTURE.md` for design rationale.

## Dependencies / prerequisites

Before running `dialed:setup` in a consumer project, you need:

**Local tooling** (installable on macOS via `brew install awscli terraform gh actionlint jq yq`):

| Tool | Minimum | Why |
|---|---|---|
| AWS CLI | v2 | Bootstraps S3 state buckets + DynamoDB lock tables before Terraform runs. |
| Terraform | 1.9 | Modern variable validation; used by every deploy step. |
| `gh` | 2.40 | Powers the stale-PR warning and manual repo operations. |
| `actionlint` | latest | Lints generated workflow YAML locally. |
| `yq` | v4 | Reads `.dialed.yml` from scripts and the composite action. |
| `jq` | 1.6 | Minor helpers in setup/verify scripts. |
| `bash` | 4+ | All scripts are POSIX bash. |

**AWS access** in each account that will host an env:

- Permissions to create S3 buckets, DynamoDB tables, IAM OIDC providers, IAM roles + policies.
- Ability to run `aws sts get-caller-identity`.

Once OIDC is bootstrapped, day-to-day deploys use the scoped `dialed-<project>-deploy-<env>` role — your local creds are only needed for initial setup and recovery.

**GitHub permissions**:

- Push access to the consumer repository.
- **Admin** rights on the repo — setup creates GitHub Environments (prod locked to `main`; dev/staging open) and a `main` branch-protection rule via `gh api`. Without admin these calls fail.
- Workflow permissions allow `id-token: write` (default on most repos; confirm under `Settings → Actions → General → Workflow permissions`).
- No static GitHub secrets for AWS — OIDC replaces `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`.

**Accounts**: AWS account IDs for every env. 2-env needs `dev_account_id` + `prod_account_id`; 3-env adds `staging_account_id`. Single-account mode (`account_model=1`) reuses one ID for all envs.

Full detail in `docs/PREREQUISITES.md`.
