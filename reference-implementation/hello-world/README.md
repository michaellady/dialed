# hello-world — VPC-enabled Lambda reference impl

A minimal Go Lambda behind an API Gateway HTTP API, deployed inside DIALED's foundational shared VPC. When you hit the stack URL, you get `{"env":"dev","pr":"42","msg":"hello from DIALED"}`.

This demonstrates:

- `needs_vpc=y` path: shared VPC + fck-nat provisioned once per env, consumed by every PR stack.
- Per-PR stack isolation: each open PR gets its own Lambda + API GW.
- System test contract: `make test-system` curls `$STACK_URL` and asserts.

## Files in this directory

- `main.go` — Lambda handler.
- `go.mod` — module definition.
- `Makefile.snippet` — entries to merge into the DIALED-generated `Makefile` for Go-specific build + system-test commands.
- `stack.tf.snippet` — Terraform to paste into `terraform/stack/main.tf` after `dialed:setup`. Defines the Lambda, its IAM role, and the API Gateway.
- `.dialed.yml.example` — fully-populated config with placeholder account IDs.

## End-to-end walkthrough

```bash
cd ~/dev                       # or wherever
gh repo create my-hello --public --clone
cd my-hello

# Copy the app source
cp ~/dev/dialed/reference-implementation/hello-world/main.go .
cp ~/dev/dialed/reference-implementation/hello-world/go.mod .
go mod tidy

git add -A && git commit -m "Initial hello-world source"

# Invoke DIALED's setup in Claude Code
# (Paste from .dialed.yml.example; supply your real account IDs and region)

# After setup writes .github/workflows/, terraform/, Makefile:

# 1. Paste stack.tf.snippet into terraform/stack/main.tf (after the
#    "YOUR RESOURCES HERE" marker) and set stack_url in outputs.tf.
# 2. Merge Makefile.snippet into the generated Makefile's build: and
#    test-system: targets (or adjust the commands in .dialed.yml to
#    point at them).

# Commit + push
git add -A && git commit -m "Wire up DIALED pipeline"
git push

# Open a PR against main
git checkout -b test-pr
echo '// test comment' >> main.go
git commit -am "Trivial change to exercise pr-deploy"
gh pr create --fill
```

pr-deploy should run, apply a per-PR Terraform workspace, deploy the Lambda into a `dev-pr-<N>`-tagged slot inside the shared VPC, wait for readiness, and comment on the PR with the stack URL. Hit that URL — you should get a JSON response with the PR number in it.

Close the PR; pr-cleanup tears everything down.

## Stack URL behavior

`stack_url` in `terraform/stack/outputs.tf` should resolve to the API Gateway default endpoint. If you configured `domain` in `.dialed.yml`, point it to `https://pr-<N>.<domain>` instead (requires Route 53 + ACM, not included in this minimal example).

## Cost

- Shared dev VPC + fck-nat: ~$3-5/mo.
- Each open PR: Lambda + API GW default URL — effectively free unless you're hammering it. Stays up until the PR closes.
- Prod: same as dev, so doubled.
