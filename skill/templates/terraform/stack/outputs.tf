# Outputs from your per-env stack. Exactly one output is CONTRACT: `stack_url`.
# The pr-deploy and main-deploy workflows run `terraform output -raw stack_url`
# after apply and feed it to the wait-ready + system-test steps as STACK_URL.
#
# If your app doesn't have an HTTP surface (e.g. queue consumer,
# scheduled job), override `make wait-ready` and `make test-system` in
# your project's Makefile to define readiness + success in terms that
# make sense. `stack_url` can be any string the tests know how to use —
# it's a convention, not an enforced URL.

output "stack_url" {
  value = ""
  # Replace with a reference to your actual endpoint, e.g.:
  #   value = aws_apigatewayv2_api.main.api_endpoint
  #   value = "https://pr-${var.pr_number}.${var.domain}"
  #   value = aws_lb.app.dns_name
  description = "Endpoint the system-test step hits. Default empty means 'skip readiness + system tests'."
}
