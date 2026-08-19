# tfboundary-lint

A CI guard that fails if any DIALED-authored IAM role is minted without a
`permissions_boundary`.

## Why

The bootstrap deploy role's policy gates `iam:CreateRole` (and the other
role-mutation actions) on `role/dialed/${project_name}-*` with a **required**
`iam:PermissionsBoundary` condition. Every IAM role the deploy role creates —
the shared tier, the stack tier, and the modules they consume — must therefore
declare a `permissions_boundary`, or the `terraform apply` fails with
`AccessDenied`.

That rule used to live only as a comment. The shared-tier cleanup Lambda role
skipped it and would have broken **every** shared-tier apply (see the PR that
added this tool). This linter turns the convention into a gate.

## What it checks

For every `*.tf` under `skill/templates/terraform/`, excluding the **bootstrap**
tier and any vendored `.terraform/` cache, each `resource "aws_iam_role"` block
must set a non-empty `permissions_boundary` (any `local.*`/`var.*` value counts;
a literal `null` or `""` does not).

The bootstrap tier is exempt on purpose: its `deploy` role is minted by the
bootstrap/admin principal (not by the deploy role) and is the very role the
boundary constrains.

## Run it

```bash
cd tools/tfboundary-lint
go test ./...
go run . ../../skill/templates/terraform
```

Also runs as part of `make test` and the `iam boundary lint` CI job.
