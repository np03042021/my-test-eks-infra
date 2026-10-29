output "cluster_name" {
  value = module.eks.cluster_name
}

output "region" {
  value = var.region
}

output "vpc_id" {
  description = "Used by down.sh to wait for ALBs to disappear before destroying the VPC."
  value       = module.vpc.vpc_id
}

output "secret_name" {
  value = aws_secretsmanager_secret.demo.name
}

output "auditor_lambda_name" {
  value = aws_lambda_function.auditor.function_name
}

output "kubeconfig_command" {
  value = "aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.region}"
}
