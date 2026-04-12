# Partial backend config. The bucket name + key + lock table are passed via
# `terraform init -backend-config=...` during setup, since they depend on
# the caller's account ID which isn't known until runtime.
#
# The caller invokes:
#   terraform init \
#     -backend-config="bucket=dialed-{project}-{account}-tfstate" \
#     -backend-config="key=bootstrap/terraform.tfstate" \
#     -backend-config="region={region}" \
#     -backend-config="dynamodb_table=dialed-{project}-{account}-tflocks" \
#     -backend-config="encrypt=true"

terraform {
  backend "s3" {}
}
