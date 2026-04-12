# Partial backend config. Populated at `terraform init` time by every
# deploy workflow via -backend-config flags.
#
# Expected -backend-config:
#   bucket=dialed-{project}-{account}-tfstate
#   key=stack/terraform.tfstate
#   region=<aws_region>
#   dynamodb_table=dialed-{project}-{account}-tflocks
#   encrypt=true

terraform {
  backend "s3" {}
}
