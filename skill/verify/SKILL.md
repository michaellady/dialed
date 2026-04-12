---
name: dialed:verify
description: Check that a DIALED-ified project's setup is still sound — state buckets, OIDC roles, workflow references, Makefile targets, optional shared-tier state. Triggers - "dialed verify", "check dialed setup", "verify deploy pipeline".
---

# dialed:verify

Reads `.dialed.yml` in the current working directory and validates that the AWS + GitHub state matches what DIALED expects. Reports any drift; does not fix anything.

## Preconditions

1. `.dialed.yml` exists at the repo root. If not: "This project isn't DIALED-ified. Run `dialed:setup` first."
2. `DIALED_HOME` resolves to a valid dialed checkout (defaults `~/dev/dialed`).
3. AWS credentials are available for at least one of the configured accounts. The script will switch as needed; ask the user to set up creds for any account that fails.

## Execute

Run:

```
bash "$DIALED_HOME/skill/scripts/verify.sh"
```

Stream output. The script checks, per account:

- S3 state bucket `dialed-{project}-{account}-tfstate` exists + versioned + encrypted.
- DynamoDB lock table `dialed-{project}-{account}-tflocks` exists.
- (If needs_vpc=y) shared-tier state bucket `dialed-{project}-{account}-tfstate-shared` exists.
- GitHub OIDC provider is present in the account.
- Per-env IAM roles `dialed-deploy-{env}` exist with trust policies scoped to `github_repo`.
- Derived role ARNs match the naming convention DIALED's runtime expects.

Per-repo:

- `.github/workflows/` has `pr-deploy.yml`, `pr-cleanup.yml`, `test.yml`, `main-deploy.yml`.
- (If enable_stale_pr_warning=y) `pr-stale-warn.yml` exists.
- (If needs_vpc=y) `shared-deploy.yml` exists.
- `.github/actions/dialed-setup/action.yml` exists.
- `terraform/bootstrap/`, `terraform/stack/` exist.
- `Makefile` defines `wait-ready` target.

## Reporting

Print a summary with ✓ / ✗ per check. On any ✗, include the remediation path (re-run setup, fix manually, etc.). Exit 0 if all checks pass, non-zero otherwise — so CI can gate on verify.
