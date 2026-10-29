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

# GitHub sends "immutable" OIDC subjects that include numeric IDs:
#   repo:<owner>@<owner_id>/<repo>@<repo_id>:environment:production
# IDs are never reused, so a deleted-and-recreated (or renamed-and-squatted) repo with the same name can't
# assume these roles. Look them up with:
#   gh api repos/<owner>/<repo> -q '"repo_id=\(.id) owner_id=\(.owner.id)"'
#   gh api repos/<owner>/<repo>/actions/oidc/customization/sub     # shows the exact sub prefix
variable "github_owner_id" {
  description = "Numeric GitHub ID of github_owner (part of the immutable OIDC subject)."
  type        = number
  default     = 94600928
}

variable "app_repo_id" {
  description = "Numeric GitHub ID of app_repo (part of the immutable OIDC subject)."
  type        = number
  default     = 1436999333
}

variable "infra_repo_id" {
  description = "Numeric GitHub ID of infra_repo (part of the immutable OIDC subject)."
  type        = number
  default     = 1436999057
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
