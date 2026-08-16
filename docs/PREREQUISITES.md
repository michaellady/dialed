# Prerequisites

DIALED expects these tools and permissions in place before you run `dialed:setup` in a consumer project.

## Local tooling

| Tool | Minimum version | Why |
|---|---|---|
| AWS CLI | v2 | Bootstrap creates S3 state buckets + DynamoDB lock tables via `aws` commands before any Terraform runs. |
| Terraform | 1.9 | Uses modern variable validation and `import` block syntax. |
| `gh` | 2.40 | Used by stale-PR warning workflow and for manual repo operations during setup. |
| `actionlint` | latest | Local lint for generated GitHub Actions workflows. |
| `jq` | 1.6 | Used by setup/verify scripts to read `.dialed.yml`. |
| `bash` | 4+ | Setup/verify/bootstrap scripts are POSIX bash. |

Install on macOS via Homebrew:

```
brew install awscli terraform gh actionlint jq
```

## AWS permissions

The credentials you have locally when running `dialed:setup` (typically an admin or power-user role) must be able to, **in each account that will host an env**:

- Create/read/write S3 buckets (state buckets).
- Create DynamoDB tables (state locking).
- Create IAM OIDC identity providers, roles, and policies.
- Read account identity (`sts:GetCallerIdentity`).

Once OIDC is bootstrapped, day-to-day deploys use the scoped `dialed-<project>-deploy-<env>` role — your local creds are only needed during initial setup and recovery.

## GitHub permissions

- Ability to push to the repository where DIALED is being installed.
- **Admin** rights on the repo. Setup uses `gh api` to create GitHub Environments (the `prod` environment locked to `main` — the branch gate for prod deploys — plus `dev`/`staging` with no branch policy) and a default-branch protection rule on `main` (require a PR + up-to-date passing status checks before merging). These endpoints require admin; without it, setup fails at the environment/branch-protection step.
- Ability to create GitHub Actions secrets is **not** required (OIDC replaces secrets for AWS auth).
- Workflow permissions must allow `id-token: write` (the default for most repos; confirm at `Settings → Actions → General → Workflow permissions`).
- `gh` must be authenticated (`gh auth status`) as a user with the admin rights above.

## Accounts

You need the AWS account IDs for every env you'll operate:

- **2-env model:** `dev_account_id`, `prod_account_id` (or a single ID if `account_model=1`).
- **3-env model:** add `staging_account_id`.

DIALED prompts for these during setup. If you haven't carved separate accounts yet, you can start with `account_model=1` and migrate later — the setup skill supports each valid env × account combination.
