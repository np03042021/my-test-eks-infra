terraform {
  # >= 1.10 for S3 native state locking (use_lockfile) in the infra stack.
  required_version = ">= 1.10.0"

  required_providers {
    # Exact version is recorded in .terraform.lock.hcl (committed, with hashes).
    # Check for updates: https://registry.terraform.io/providers/hashicorp/aws/latest
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.70"
    }
  }

  # Local state on purpose: this stack creates the remote-state bucket (chicken-and-egg).
  # terraform.tfstate is gitignored. Production: migrate this state into the bucket after first apply.
}
