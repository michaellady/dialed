# hello-stateless — no-VPC reference impl

Public Lambda with a Function URL. No shared tier, no VPC, no fck-nat cost. Simplest possible DIALED project; useful when your app doesn't need to live inside a private network.

Same Go source as hello-world, just with no VPC config on the Lambda.

## Files

- `main.go` — handler (shared with hello-world — same app code).
- `go.mod` — module.
- `.dialed.yml.example` — config with `needs_vpc: false`.
- `stack.tf.snippet` — Terraform for Lambda + Function URL (no API Gateway, no VPC).

## Walkthrough

Same as hello-world but set `needs_vpc: false` during setup. DIALED skips the shared tier; the Lambda lives in the public subnet (implicitly — no VPC attached).

If you later outgrow this and need a VPC (e.g. adding RDS), run `dialed:add-shared`.

## stack.tf.snippet

```hcl
resource "aws_iam_role" "lambda" {
  name = "${local.name_prefix}-lambda"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_lambda_function" "hello" {
  function_name = "${local.name_prefix}-hello"
  role          = aws_iam_role.lambda.arn
  runtime       = "provided.al2023"
  handler       = "bootstrap"
  architectures = ["arm64"]

  filename         = "../../dist/bootstrap.zip"
  source_code_hash = filebase64sha256("../../dist/bootstrap.zip")

  environment {
    variables = {
      DIALED_ENV = var.environment
      DIALED_PR  = var.pr_number
    }
  }
}

resource "aws_lambda_function_url" "hello" {
  function_name      = aws_lambda_function.hello.function_name
  authorization_type = "NONE"
}

# In outputs.tf:
# output "stack_url" {
#   value = aws_lambda_function_url.hello.function_url
# }
```
