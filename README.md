# DIALED

**D**eploying **I**nfrastructure with **A** **L**ow **E**ffort **D**elivery.

A Claude Code skill that bootstraps GitHub Actions + Terraform + AWS deployment pipelines for any project: per-PR ephemeral stacks, staged testing, and automated dev → prod promotion on merge.

## What you get

- **Per-PR stacks.** Every PR gets its own isolated Terraform workspace in the dev AWS account. Open a PR, a real stack comes up; close the PR, it tears down.
- **Staged tests.** Unit + integration pre-deploy (fast fail), system tests against the live PR stack, smoke tests post-prod.
- **Dev → prod promotion.** Merge to main auto-deploys through dev (and optionally staging) into prod.
- **AWS OIDC.** No long-lived access keys in GitHub secrets.
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

Early development. See `docs/ARCHITECTURE.md` for design rationale and `docs/PREREQUISITES.md` for required tooling.
