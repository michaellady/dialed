---
name: dialed:add-module
description: Wire a module into an existing DIALED shared tier. Supports DIALED-shipped modules (network, database) and custom modules authored in the project. Triggers - "add module to dialed", "dialed add module", "install RDS in dialed project".
---

# dialed:add-module

Copies a module into `terraform/modules/`, adds it to `terraform/shared/main.tf`, and exposes its outputs from `terraform/shared/outputs.tf`. Then (after user confirmation) runs `terraform apply` on the shared tier.

v1 ships one DIALED-owned module: `network` (already installed by `dialed:setup` when `needs_vpc=y`). M2 adds `database` (RDS + per-PR logical DB). Custom modules are supported from day one: pass a path to a module directory, and DIALED wires it in the same way.

## Preconditions

1. `.dialed.yml` exists and `needs_vpc: true` (the shared tier must exist). If not, tell the user to run `dialed:add-shared` first.
2. `terraform/shared/main.tf` exists.
3. `DIALED_HOME` resolves.

## Collect input

1. **Module name** — ask the user. Valid values:
    - `network` — already installed at setup; re-running updates the existing module (e.g. after editing the shipped version). Confirm this is the intent.
    - `database` — M2; RDS cluster + per-PR logical DB helper. Ship-detect: check `$DIALED_HOME/skill/templates/terraform/modules/database/` exists. If not, tell the user the module hasn't shipped yet.
    - **path to custom module** — any directory containing a valid Terraform module. DIALED copies it into `terraform/modules/<basename>/`.

2. **Module alias** (if custom) — short name used as the TF module block's label (e.g. `module "cache" { source = "../modules/my_redis" }`). Default: basename of the source path.

3. **Envs** — which envs should receive this module on the next shared-deploy. Default: all. Affects only the confirmation wording; the apply loop hits each env sequentially.

## Confirm

Summarize: module source path, destination, the block that will be added to `shared/main.tf`, the outputs that will be re-exported, and the cost impact if known (database module surfaces an RDS cost; custom modules are user's responsibility to disclose).

## Execute

Run:

```
bash "$DIALED_HOME/skill/scripts/add-module.sh" --name MODULE_NAME [--source PATH]
```

The script:

1. Copies the module (DIALED-shipped or user-supplied) into `terraform/modules/<name>/`.
2. Appends a `module "<alias>" { source = "../modules/<name>" ... }` block to `terraform/shared/main.tf`.
3. Appends output declarations for the module's outputs to `terraform/shared/outputs.tf`, prefixed with the alias to avoid collisions.
4. For `database` specifically (M2): also installs `modules/per_pr_database/` and patches `terraform/stack/main.tf` with a conditional `module "per_pr_db"` block gated on `var.pr_number != ""`.
5. Deploys to each env's shared tier (after confirmation per env).

## After success

Tell the user to commit the new files. Note that PR stacks now see the module's outputs via `data.terraform_remote_state.shared.outputs.*` — they can reference the new resources in `terraform/stack/main.tf`.
