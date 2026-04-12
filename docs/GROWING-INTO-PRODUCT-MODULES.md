# Growing into product modules

DIALED v1 ships lean. The shared tier gives you a VPC + NAT per env, and the app stack gives you per-PR Terraform. Everything else — databases, caches, queues, search, whatever — you add as needs become real.

This doc explains when to reach for `dialed:add-module`, what ships in the box, and how to author custom modules.

## When to reach for shared product modules

The default shape (v1) is: stateless app stack + shared VPC. This works great for:

- Pure API Lambdas with external state (Stripe, third-party APIs, S3 directly).
- Background workers triggered by SNS/SQS/EventBridge.
- Projects where "state" means writes to an existing RDS/Dynamo instance you don't own.

Reach for a shared product module when:

- **Database**: Every PR needs isolated data. Spinning up a fresh RDS per PR is slow (10+ min) and expensive. Shared RDS + per-PR logical DB inside it gets you isolation for ~$12/mo total.
- **Cache** (Redis/Memcached): Same cost argument — shared cluster, per-PR keyspace or logical DB.
- **Search** (OpenSearch): Extreme cost per cluster; sharing one across envs is the only way.
- **Anything with >5-minute spin-up time**: Make it shared and long-lived.

Conversely: things that spin up fast and scale to zero (DynamoDB, S3 buckets, SQS queues, Step Functions) belong in `terraform/stack/` per-PR. No need to share.

## What's shipped in DIALED v2

| Module | What it creates | Cost (dev) | Use when |
|---|---|---|---|
| `network` | VPC, subnets, IGW, fck-nat (default) or NAT Gateway | ~$3-5/mo | Any app with VPC-bound resources (Lambda-in-VPC, RDS, ECS). Installed at setup when `needs_vpc=y`. |
| `database` | RDS Postgres instance + Secrets Manager master creds | ~$12/mo (db.t4g.micro) | Your app needs Postgres per-PR. Pairs with the `per_pr_database` stack-side module. |
| `per_pr_database` (stack-side) | Logical `pr_<N>` database + scoped role, dropped on destroy. Uses cyrilgdn/postgresql provider. | $0 (lives inside the shared instance) | Automatically installed when you run `dialed:add-module database`. |

## Invoking add-module

Shipped modules:

```
dialed:add-module database
```

Custom modules (yours, authored under any directory):

```
dialed:add-module --source ./my-redis-module --name my_redis
```

Either path: DIALED copies the module into `terraform/modules/<name>/`, appends a `module "<alias>" { source = "../modules/<name>" }` block to `terraform/shared/main.tf` (with TODO markers where inputs need filling), and exposes its outputs via `terraform/shared/outputs.tf`.

For the shipped `database` module specifically, the module block is **pre-wired** with the right inputs (name_prefix, vpc_id, subnets, etc.) — no TODO required.

## Authoring custom modules

DIALED modules are plain Terraform modules. No DIALED-specific boilerplate. Authoring checklist:

1. **Keep it VPC-aware if it touches network**: accept `vpc_id`, `private_subnet_ids`, `vpc_cidr_block` as inputs when placing resources inside the VPC.
2. **Declare outputs the PR stack will consume**. `terraform/shared/outputs.tf` re-exports them via `try()` to the shared state; PR stacks read them through `data.terraform_remote_state.shared`.
3. **Tag everything**. The shared tier's `default_tags` will propagate `ManagedBy=dialed`, `Project`, `Env`, `Tier=shared` automatically — but explicit `Name` tags per resource help in the console.
4. **Use environment-aware defaults**: `prod` should get multi-AZ / deletion protection; `dev` shouldn't. Mirror what `modules/database/` does with `var.environment`.
5. **Include a brief README.md in the module** explaining inputs, outputs, cost.

Drop your module anywhere (typically a directory adjacent to the consumer project, or a separate git repo), and `dialed:add-module --source PATH --name my_thing` pulls it in.

## The per-PR pattern in custom modules

If your module's resource is expensive enough to share but you want per-PR isolation inside it, the pattern is:

1. **Shared tier module**: creates the long-lived resource (e.g. Redis cluster, search index parent).
2. **Stack-side module**: consumes outputs from (1) and creates the per-PR logical unit (keyspace, namespace, etc.) — scoped by `var.pr_number`.

`database` + `per_pr_database` is the canonical example. `dialed:add-module database` installs both and wires them together. For custom modules, your `add-module` invocation installs just the shared piece; the stack-side piece (if you have one) you add manually to `terraform/stack/main.tf` with a `count = var.pr_number != "" ? 1 : 0` guard.

## Removing a module

There's no `dialed:remove-module` in v2. To remove:

1. Delete the `module "x" { ... }` block from `terraform/shared/main.tf` (and any stack-side block in `terraform/stack/main.tf`).
2. `terraform -chdir=terraform/shared apply` (destroys the resources).
3. `rm -rf terraform/modules/x/`.
4. Remove the module's entries from `terraform/shared/outputs.tf`.

Before running apply, `terraform plan` will show the destruction — sanity check it.

## What DIALED still doesn't do

Even with v2, DIALED doesn't generate:

- Monitoring dashboards, CloudWatch alarms. Author in `terraform/stack/` per-env.
- AWS Budgets. Set up per account via the AWS console or a separate module.
- Secret rotation. Secrets Manager handles storage; rotation is per-app-specific.
- Backup/disaster recovery runbooks. Your incident response doc, not DIALED's.
- Compliance checkers (SOC 2, HIPAA). Use an external tool.

These are intentional — each is its own domain. DIALED focuses on the deploy pipeline + foundational infrastructure and stops there.
