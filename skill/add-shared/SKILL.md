---
name: dialed:add-shared
description: Retrofit a shared infrastructure tier (VPC + fck-nat) to a DIALED project that set needs_vpc=false at setup. Use when a project has outgrown stateless PR stacks and needs a long-lived VPC. Triggers - "add shared infra", "add VPC to dialed project", "retrofit shared tier".
---

# dialed:add-shared

Adds a shared tier to a DIALED project that didn't ask for one at setup. Creates `terraform/shared/` with the network module, drops in `shared-deploy.yml`, flips `needs_vpc` to true in `.dialed.yml`, activates the `data "terraform_remote_state" "shared"` block in the app stack, and runs `terraform apply` on the shared tier for each opted-in env.

Only needed for projects that set `needs_vpc=n` at setup. Projects created with `needs_vpc=y` already have everything.

## Preconditions

1. `.dialed.yml` exists at repo root.
2. `.dialed.yml` has `needs_vpc: false` (otherwise this skill is a no-op; run `dialed:verify` instead).
3. `DIALED_HOME` resolves to a valid dialed checkout.
4. AWS credentials are available; user will be prompted to switch when addressing each env's account.

## Collect input

Ask, one question at a time:

1. **Which envs get a shared tier?** Default: all envs currently configured (`dev`, `prod` in 2-env; `dev`, `staging`, `prod` in 3-env). The user can deselect envs where they don't want a VPC yet — partial enablement is fine.
2. **vpc_cidr** — default `10.0.0.0/16`. Used for every env's VPC (they're in separate accounts / tagged by env, so CIDR collisions are only a concern if envs share an account AND you'll peer them later).

## Confirm

Summarize what will happen per env (VPC + fck-nat, ~$3-5/mo each) and total cost. Explicit "yes" before proceeding.

## Execute

1. Update `.dialed.yml` using the Edit tool: flip `needs_vpc: true` and set `vpc_cidr`.
2. Run:

    ```
    bash "$DIALED_HOME/skill/scripts/add-shared.sh"
    ```

    The script:
    - Copies `terraform/shared/`, `terraform/modules/network/`, and `.github/workflows/shared-deploy.yml` into the project.
    - Per opted-in env: runs `bootstrap-state.sh --shared` in that env's account, then `terraform apply` on the shared tier.
    - The `data "terraform_remote_state" "shared"` block in `terraform/stack/main.tf` is already present (gated on `var.needs_vpc`); flipping the var activates it on the next apply.

## After success

Tell the user to commit the new files and push. Next stack deploys will read shared state automatically.
