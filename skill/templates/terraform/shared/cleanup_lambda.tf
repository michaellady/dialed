# Orphan cleanup Lambda — invoked by pr-cleanup.yml when `terraform destroy`
# fails. Cleans up ENIs and security groups tagged with the PR's workspace.
# M2 extends its env + IAM to also drop the per-PR database.

data "archive_file" "cleanup_lambda" {
  type        = "zip"
  source_file = "${path.module}/lambda/cleanup.py"
  output_path = "${path.module}/lambda/cleanup.zip"
}

resource "aws_iam_role" "cleanup_lambda" {
  name = "${local.name_prefix}-cleanup-lambda"
  path = "/dialed/"

  # Minted WITH the project's boundary — the bootstrap deploy role's
  # iam:CreateRole is gated on iam:PermissionsBoundary. Unlike the fck-nat role,
  # this Lambda exists for every service (needs_vpc true or false), so an
  # unbounded role here would AccessDeny on every shared-tier apply.
  permissions_boundary = local.permissions_boundary_arn

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action    = "sts:AssumeRole"
        Effect    = "Allow"
        Principal = { Service = "lambda.amazonaws.com" }
      }
    ]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "cleanup_lambda_basic" {
  role       = aws_iam_role.cleanup_lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "cleanup_lambda_inline" {
  name = "${local.name_prefix}-cleanup-lambda-policy"
  role = aws_iam_role.cleanup_lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EniAndSgCleanup"
        Effect = "Allow"
        Action = [
          "ec2:DescribeNetworkInterfaces",
          "ec2:DeleteNetworkInterface",
          "ec2:DescribeSecurityGroups",
          "ec2:DeleteSecurityGroup",
          "ec2:DescribeTags",
        ]
        Resource = "*"
      },
      # M2 stub: when database module is added, uncomment these for Secrets
      # Manager + (optional) RDS IAM auth so the Lambda can drop pr_<N> DBs.
      # {
      #   Sid      = "ReadDbMasterSecret"
      #   Effect   = "Allow"
      #   Action   = ["secretsmanager:GetSecretValue"]
      #   Resource = aws_secretsmanager_secret.rds_master.arn
      # }
    ]
  })
}

resource "aws_lambda_function" "cleanup" {
  function_name = "dialed-${var.project_name}-cleanup-${var.environment}"
  role          = aws_iam_role.cleanup_lambda.arn
  runtime       = "python3.12"
  handler       = "cleanup.handler"
  timeout       = 60
  memory_size   = 256

  filename         = data.archive_file.cleanup_lambda.output_path
  source_code_hash = data.archive_file.cleanup_lambda.output_base64sha256

  # M2: when the database module is added, these get populated so the
  # Lambda knows how to connect to RDS and drop pr_<N> DBs.
  environment {
    variables = {
      DIALED_ENV = var.environment
    }
  }

  tags = local.common_tags
}
