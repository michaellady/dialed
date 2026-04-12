# Partial backend config. Populated at `terraform init` time by the
# shared-deploy workflow (or add-shared at local setup time).
#
# Expected -backend-config values:
#   bucket=dialed-{project}-{account}-tfstate-shared
#   key=shared/terraform.tfstate
#   region=<aws_region>
#   dynamodb_table=dialed-{project}-{account}-tflocks
#   encrypt=true

terraform {
  backend "s3" {}
}
