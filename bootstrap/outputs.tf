output "state_bucket" {
  description = "S3 bucket for the infra stack's remote state (pass to terraform init -backend-config)."
  value       = aws_s3_bucket.tfstate.bucket
}

output "ecr_repository_url" {
  description = "ECR repository URL (GitHub variable ECR_REPOSITORY)."
  value       = aws_ecr_repository.app.repository_url
}

output "github_ecr_push_role_arn" {
  description = "Role assumed by the app repo's release workflow via OIDC (GitHub variable AWS_ROLE_ARN)."
  value       = aws_iam_role.ecr_push.arn
}

output "github_plan_role_arn" {
  description = "Optional read-only plan role (null when create_plan_role = false)."
  value       = try(aws_iam_role.plan[0].arn, null)
}
