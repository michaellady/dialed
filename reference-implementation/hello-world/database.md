# Adding the database module to hello-world

Extends `hello-world` with a per-PR Postgres database. Each PR's Lambda gets its own `pr_<N>` logical DB inside a shared RDS instance; on PR close, the DB is dropped along with the rest of the stack.

This section walks through what to do **after** the base hello-world setup from the primary README.

## 1. Install the module

From the consumer repo (where `dialed:setup` was already run):

```
dialed:add-module database
```

This:

- Copies `terraform/modules/database/` into your project.
- Appends a fully-wired `module "database" { ... }` block to `terraform/shared/main.tf`.
- Copies `terraform/modules/per_pr_database/` into your project.
- Appends a conditional `module "per_pr_db" { count = var.pr_number != "" ? 1 : 0 ... }` to `terraform/stack/main.tf`.
- Re-exports `database_*` outputs from `terraform/shared/outputs.tf` (already present as `try()` outputs since v1 — adding the module populates them).

## 2. Deploy the shared tier

The shared tier now contains an RDS instance. Deploy it:

```
cd terraform/shared
terraform apply  # creates the RDS instance, ~10 min
```

Or push and let `shared-deploy.yml` do it.

## 3. Update the Lambda to consume the DB

Extend `main.go` to read from the per-PR DB:

```go
package main

import (
    "context"
    "database/sql"
    "encoding/json"
    "os"

    "github.com/aws/aws-lambda-go/events"
    "github.com/aws/aws-lambda-go/lambda"
    _ "github.com/lib/pq"
)

type response struct {
    Env   string   `json:"env"`
    PR    string   `json:"pr"`
    Rows  []string `json:"rows"`
    DBErr string   `json:"db_err,omitempty"`
}

var db *sql.DB

func init() {
    if url := os.Getenv("DATABASE_URL"); url != "" {
        d, err := sql.Open("postgres", url)
        if err == nil {
            db = d
        }
    }
}

func handler(ctx context.Context, _ events.APIGatewayV2HTTPRequest) (events.APIGatewayV2HTTPResponse, error) {
    res := response{
        Env: os.Getenv("DIALED_ENV"),
        PR:  os.Getenv("DIALED_PR"),
    }

    if db != nil {
        _, err := db.ExecContext(ctx, `CREATE TABLE IF NOT EXISTS visits (at TIMESTAMPTZ DEFAULT NOW())`)
        if err == nil {
            _, err = db.ExecContext(ctx, `INSERT INTO visits DEFAULT VALUES`)
        }
        if err == nil {
            rows, err2 := db.QueryContext(ctx, `SELECT at FROM visits ORDER BY at DESC LIMIT 5`)
            if err2 == nil {
                defer rows.Close()
                for rows.Next() {
                    var at string
                    _ = rows.Scan(&at)
                    res.Rows = append(res.Rows, at)
                }
            } else {
                res.DBErr = err2.Error()
            }
        } else {
            res.DBErr = err.Error()
        }
    } else {
        res.DBErr = "no DATABASE_URL"
    }

    body, _ := json.Marshal(res)
    return events.APIGatewayV2HTTPResponse{
        StatusCode: 200,
        Headers:    map[string]string{"Content-Type": "application/json"},
        Body:       string(body),
    }, nil
}

func main() { lambda.Start(handler) }
```

Add to `go.mod`:

```
github.com/lib/pq v1.10.9
```

## 4. Pass DATABASE_URL into the Lambda

In `terraform/stack/main.tf`, find the `aws_lambda_function.hello` block and extend its `environment`:

```hcl
environment {
  variables = {
    DIALED_ENV   = var.environment
    DIALED_PR    = var.pr_number
    DATABASE_URL = length(module.per_pr_db) > 0 ? module.per_pr_db[0].connection_string : ""
  }
}
```

The Lambda's SG also needs egress to RDS:

```hcl
resource "aws_security_group_rule" "lambda_to_rds" {
  count                    = length(module.per_pr_db)
  type                     = "egress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  security_group_id        = aws_security_group.lambda.id
  source_security_group_id = data.terraform_remote_state.shared[0].outputs.database_security_group_id
  description              = "Postgres egress to shared RDS"
}
```

And the RDS SG needs a reciprocal ingress rule from the Lambda SG. Edit `terraform/modules/database/main.tf` to accept a `lambda_sg_ids` var, or add it as a standalone rule in your stack.

## 5. Exercise end-to-end

```
git add -A && git commit -m "Add per-PR DB to hello-world"
git push

# Open a PR
gh pr create --fill

# After pr-deploy is green, hit the stack URL a few times:
curl $(terraform -chdir=terraform/stack output -raw stack_url)

# Response shows the `rows` growing over subsequent calls, confirming
# the pr_<N> database is real and isolated from other PRs.

# Close the PR and verify the pr_<N> DB is gone:
gh pr close --delete-branch <PR_NUM>
# Then in psql against the admin DB:
#   \l  -- should NOT list pr_<N>
```

## Cost

RDS db.t4g.micro: ~$12/mo (the fixed cost for the dev env once you add the database module). Each per-PR logical DB inside the instance is effectively free — it's just more rows in Postgres's catalog.

## Network reachability gotcha

The `per_pr_database` module uses the `cyrilgdn/postgresql` provider to connect to RDS and `CREATE DATABASE pr_<N>`. GitHub Actions runners are NOT inside your VPC by default, so they can't reach a private RDS endpoint.

Three ways to solve this; pick one:

1. **Tunnel via SSM** (preferred — no public exposure): Register an SSM-capable bastion (fck-nat works) and use `aws ssm start-session --target <instance> --document-name AWS-StartPortForwardingSession` to forward 5432 locally, then point the PG provider at `localhost`. Requires Session Manager plugin + a bit of orchestration; writeup forthcoming in anatomy.md.

2. **Temporary public-subnet DB** (dev only, NOT recommended for prod): Put the RDS in a public subnet for dev env and allow GitHub runner CIDRs in the RDS SG. Fast to set up; wide attack surface.

3. **Self-hosted runner inside the VPC**: One EC2 instance in the private subnet serves as the workflow runner. Heaviest; only worth it for teams already running self-hosted runners.

For early-stage dev use, option 2 is the quickest path to "it works." Migrate to option 1 before prod.
