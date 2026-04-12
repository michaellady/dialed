# DIALED reference implementations

Worked examples of DIALED-ified projects. These are **illustrative, not prescriptive** — DIALED is stack-agnostic. These exist so you can see a concrete end-to-end example before wiring DIALED into your own project.

Two flavors, exercising both setup paths:

| Project | `needs_vpc` | Stack shape | Exercises |
|---|---|---|---|
| [`hello-world/`](./hello-world/) | `y` | Lambda in VPC + API Gateway | Foundational shared tier, fck-nat, PR stacks inside long-lived VPC, system test hitting API GW URL. This is the primary v1 reference. |
| [`hello-stateless/`](./hello-stateless/) | `n` | Public Lambda + Function URL | No shared tier, no VPC cost, simplest possible DIALED project. Proves the `needs_vpc=false` path. |

Each subdirectory contains:

- **Application source** (Go, but the Lambda pattern trivially ports to Python/Node/TS).
- **Makefile hooks** — what `build_cmd`, `test_*_cmd` fields should be set to in `.dialed.yml`.
- **terraform/stack/main.tf additions** — example resources to paste into the DIALED-scaffolded skeleton.
- **.dialed.yml.example** — a fully-populated config with placeholder account IDs.
- **README** walking through the end-to-end flow: install skill, run setup, commit, open PR.

## How to actually run one

Real AWS accounts required — OIDC trust and IAM role scoping don't work under LocalStack.

```bash
# 1. Install DIALED's skills
cd ~/dev/dialed
make install-skill

# 2. Create a throwaway GitHub repo for the reference impl
gh repo create my-dialed-smoke --public --clone
cd my-dialed-smoke

# 3. Copy the reference-implementation source in
cp -r ~/dev/dialed/reference-implementation/hello-world/* .
git add -A && git commit -m "Initial reference-impl source"

# 4. Invoke dialed:setup in Claude Code
#    (paste .dialed.yml.example values when prompted; supply real account IDs)

# 5. Commit the DIALED-generated files, push
git add -A && git commit -m "Add DIALED pipeline" && git push

# 6. Open a PR against main to exercise pr-deploy
gh pr create --fill

# 7. Watch the PR deploy, hit the stack URL, close the PR, watch cleanup
```

If pr-deploy goes green and the stack URL responds — DIALED is working for your account shape.
