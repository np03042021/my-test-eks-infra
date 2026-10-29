terraform {
  # >= 1.11 for write-only attributes (secret_string_wo) used in secrets.tf.
  required_version = ">= 1.11.0"

  # Exact versions + hashes are recorded in .terraform.lock.hcl (committed).
  # Check for updates: https://registry.terraform.io/providers/hashicorp/<name>/latest
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.70"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.3"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.9"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.8"
    }
  }

  # Bucket is passed at init: terraform init -backend-config="bucket=spr-tfstate-<account_id>"
  backend "s3" {
    key          = "infra/terraform.tfstate"
    region       = "ap-south-1"
    encrypt      = true # SSE on the state object
    use_lockfile = true # S3-native locking (Terraform >= 1.10); no DynamoDB table needed
  }
}
