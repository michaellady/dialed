# Migrating from roxas to DIALED

If you're maintaining roxas (or a project patterned on it) and want to adopt DIALED's improvements, here's the concrete diff.

## 1. Replace static AWS keys with OIDC

**Roxas today:** every workflow has

```yaml
- uses: aws-actions/configure-aws-credentials@v4
  with:
    aws-access-key-id: ${{ secrets.AWS_ACCESS_KEY_ID }}
    aws-secret-access-key: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
    aws-region: ${{ secrets.AWS_REGION }}
```

**DIALED:** workflows call a composite action that assumes an OIDC-federated IAM role.

```yaml
- uses: ./.github/actions/dialed-setup
  with:
    env: dev
```

Migration:

1. Run DIALED's `terraform/bootstrap/` in each AWS account — it creates the GitHub OIDC identity provider and one `dialed-deploy-<env>` role per env.
2. Add `permissions: { id-token: write, contents: read }` to every deploy workflow.
3. Delete `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` / `AWS_REGION` from GitHub secrets.
4. Replace the old `configure-aws-credentials` block with `uses: ./.github/actions/dialed-setup`.

## 2. Extract config to .dialed.yml

**Roxas today:** config values are scattered —

- Bucket names in `terraform/backend-dev.hcl` / `backend-prod.hcl` (hardcoded).
- Account IDs implicit in the static access keys (different keys = different accounts).
- Domain `roxasapp.com` hardcoded in `pr-deploy-dev.yml` at line 205.
- `TF_VAR_*` secrets per-workflow: `WEBHOOK_SECRET`, `GH_APP_ID`, etc.

**DIALED:** one `.dialed.yml` at the repo root, read by the composite action and Terraform (as `dialed.auto.tfvars.json`). Application secrets stay in GitHub secrets — only infrastructure config moves.

Migration:

1. Write `.dialed.yml` with: `project_name: roxas`, `aws_region`, `github_repo: michaellady/roxas`, `env_model: 2-env`, `account_model: 2`, `account_ids: {dev, prod}`, `domain: roxasapp.com`, etc.
2. Per-workflow: remove hardcoded references to `roxas-terraform-state-dev`, `roxasapp.com`, etc. — the composite action exports `DIALED_PROJECT_NAME`, `DIALED_DOMAIN`, `DIALED_ACCOUNT_ID`, `DIALED_WORKSPACE` as env vars.
3. Keep app-secret TF vars in `secrets.*` (WEBHOOK_SECRET etc.). DIALED doesn't replace those; it only replaces infrastructure config.

## 3. Rename workspaces + state keys

Roxas uses workspace names like `dev-pr-123`; DIALED uses the same naming. No migration needed for workspace names.

**But:** roxas's bucket naming is `roxas-terraform-state-dev` / `-prod`. DIALED uses `dialed-{project}-{account}-tfstate`. Migrating the actual state buckets is risky — safer to leave the roxas buckets alone and adopt DIALED's naming for new projects.

## 4. Shared-tier re-organization

**Roxas today:** `terraform/shared/` mixes VPC, RDS, secrets, cleanup Lambda, budgets, ACM. Single module, single state.

**DIALED:** `terraform/shared/` composes smaller modules (`modules/network`, future `modules/database`, etc.). One state per env, still — but the module-per-concern shape is easier to evolve.

Migration is NOT straightforward — would require re-importing resources into the new module structure. For roxas itself, probably not worth the risk. DIALED is the target for _new_ projects; roxas can stay as-is.

## 5. Test stages

Roxas's workflows call `make test`, `make test-int`, `make e2e`, etc. directly inside workflow YAML. DIALED reads commands from `.dialed.yml` and the composite action exports them as `DIALED_BUILD_CMD` / `DIALED_TEST_*_CMD`. Workflows are language-agnostic.

Migration: move the command strings from the workflow YAML into `.dialed.yml`'s `commands.*` fields. Workflows become a generic `eval "$DIALED_TEST_UNIT_CMD"` pattern.

## Summary

| Roxas | DIALED |
|---|---|
| Static AWS access keys | GitHub OIDC |
| Config scattered across workflows + tfvars + backend HCL | Single `.dialed.yml` |
| Hardcoded `roxasapp.com` | `DIALED_DOMAIN` env var |
| Hardcoded bucket + lock-table names | Derived from `project_name` + `account_id` |
| Monolithic `terraform/shared/` | Composed `terraform/shared/` + `modules/*` |
| Workflows Go-specific | Language-agnostic via `.dialed.yml` commands |

For a living roxas deployment, retrofitting all of this is probably more work than it's worth. The practical migration is: use DIALED for the next project, let roxas be the reference implementation.
