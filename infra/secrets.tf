############################################
# Demo application secret in Secrets Manager. Cost: $0.40/month per secret, prorated (~$0.01/day).
############################################

# Ephemeral: the generated token exists only during the apply and is never written to Terraform state.
ephemeral "random_password" "api_token" {
  length  = 32
  special = false
}

resource "aws_secretsmanager_secret" "demo" {
  #checkov:skip=CKV_AWS_149:AWS-managed aws/secretsmanager key is free; a CMK is $1/month. Prod: CMK with key policy limited to the ESO role.
  #checkov:skip=CKV2_AWS_57:No rotation Lambda for a demo token. Prod: managed rotation; ESO refreshInterval picks up new values.
  name                    = "spr/demo"
  description             = "Demo app config synced into Kubernetes by External Secrets Operator"
  recovery_window_in_days = 0 # DEMO ONLY: delete immediately on destroy. Prod: 7-30 day recovery window.
}

resource "aws_secretsmanager_secret_version" "demo" {
  secret_id = aws_secretsmanager_secret.demo.id

  # Write-only attribute (Terraform >= 1.11): sent to AWS but never stored in state or plan.
  # Bump secret_string_wo_version to rotate the value.
  secret_string_wo = jsonencode({
    GREETING_PREFIX = "Hello from the secure paved road"
    API_TOKEN       = ephemeral.random_password.api_token.result
  })
  secret_string_wo_version = 1
}
