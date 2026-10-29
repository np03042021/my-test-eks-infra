variable "region" {
  description = "AWS region for all resources."
  type        = string
  default     = "ap-south-1"
}

variable "github_owner" {
  description = "GitHub user/org that owns both repos (used in OIDC trust conditions)."
  type        = string
  default     = "np03042021"
}

variable "app_repo" {
  description = "Application repo name; only its 'production' environment may push to ECR."
  type        = string
  default     = "secure-paved-road-eks"
}

variable "infra_repo" {
  description = "Infra repo name; used by the optional read-only plan role."
  type        = string
  default     = "secure-paved-road-eks-infra"
}

variable "ecr_repo_name" {
  description = "ECR repository for the application image."
  type        = string
  default     = "secure-paved-road-app"
}

variable "budget_email" {
  description = "Email address that receives AWS Budget alerts."
  type        = string
}

variable "budget_limit_usd" {
  description = "Monthly budget limit in USD."
  type        = number
  default     = 20
}

variable "create_plan_role" {
  description = "Create the optional read-only OIDC role for 'terraform plan' on infra-repo PRs."
  type        = bool
  default     = false
}
