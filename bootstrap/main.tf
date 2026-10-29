provider "aws" {
  region = var.region

  # Tags on every resource: cost allocation + makes leftovers easy to find.
  default_tags {
    tags = {
      Project     = "secure-paved-road"
      Stack       = "bootstrap"
      Environment = "demo"
      ManagedBy   = "terraform"
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  account_id   = data.aws_caller_identity.current.account_id
  state_bucket = "spr-tfstate-${local.account_id}"
  github_oidc  = "token.actions.githubusercontent.com"
}

############################################
# Terraform remote-state bucket
# Cost: a few KB of state, effectively $0.
############################################
resource "aws_s3_bucket" "tfstate" {
  #checkov:skip=CKV_AWS_18:Access logging needs a second log bucket; state access is already in CloudTrail management events.
  #checkov:skip=CKV_AWS_144:Cross-region replication doubles cost; versioning covers accidental overwrite for a demo.
  #checkov:skip=CKV2_AWS_62:Event notifications have no consumer in this demo.
  #checkov:skip=CKV_AWS_145:SSE-KMS with the AWS-managed aws/s3 key is used; a CMK costs $1/month. Prod: CMK with restricted key policy.
  bucket        = local.state_bucket
  force_destroy = true # DEMO ONLY: lets down.sh --all delete a non-empty bucket. Prod: false + deletion protection via SCP.
}

# Versioning: recover from a corrupted or accidentally overwritten state file.
resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  versioning_configuration {
    status = "Enabled"
  }
}

# Encryption at rest. State contains resource attributes, so it is sensitive.
resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms" # no kms_master_key_id = AWS-managed aws/s3 key (free)
    }
    bucket_key_enabled = true # fewer KMS calls, lower cost
  }
}

# Block every form of public access, regardless of future ACLs or policies.
resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket                  = aws_s3_bucket.tfstate.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Disable ACLs entirely; access is governed only by IAM and the bucket policy.
resource "aws_s3_bucket_ownership_controls" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# Keep old state versions for 30 days only (cost) and clean up failed multipart uploads.
resource "aws_s3_bucket_lifecycle_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  rule {
    id     = "expire-noncurrent-state"
    status = "Enabled"
    filter {}
    noncurrent_version_expiration {
      noncurrent_days = 30
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

# TLS-only: deny any request that is not over HTTPS.
data "aws_iam_policy_document" "tfstate_tls_only" {
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.tfstate.arn,
      "${aws_s3_bucket.tfstate.arn}/*",
    ]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  policy = data.aws_iam_policy_document.tfstate_tls_only.json
  # Public access block must exist first, or the policy call can race it.
  depends_on = [aws_s3_bucket_public_access_block.tfstate]
}

############################################
# ECR repository for the app image
# Cost: $0.10/GB-month storage; a ~100 MB distroless image x 5 = ~$0.05/month.
############################################
resource "aws_ecr_repository" "app" {
  name = var.ecr_repo_name

  # Immutable tags: a pushed tag can never be overwritten, so a digest/tag always means the same bits.
  image_tag_mutability = "IMMUTABLE"

  # Basic scanning on push (free). Prod: Enhanced scanning (Inspector) for continuous re-scans.
  image_scanning_configuration {
    scan_on_push = true
  }

  # KMS encryption with the AWS-managed aws/ecr key (free). Prod: customer-managed key.
  encryption_configuration {
    encryption_type = "KMS"
  }

  force_delete = true # DEMO ONLY: deletes images on destroy. Prod: false.
}

# Keep only the last 5 images to cap storage cost.
resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep only the 5 most recent images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 5
      }
      action = { type = "expire" }
    }]
  })
}

############################################
# GitHub Actions OIDC: no long-lived AWS keys in GitHub. Cost: $0.
############################################
resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://${local.github_oidc}"
  client_id_list = ["sts.amazonaws.com"]
  # thumbprint_list omitted: AWS validates GitHub's OIDC certificate against its own trusted CA store.
}

# Trust: ONLY jobs running in the app repo's "production" environment (which requires my approval).
# PRs, forks, other branches and other repos cannot assume this role.
data "aws_iam_policy_document" "ecr_push_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.github_oidc}:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals" # exact match, never StringLike with wildcards
      variable = "${local.github_oidc}:sub"
      values   = ["repo:${var.github_owner}/${var.app_repo}:environment:production"]
    }
  }
}

resource "aws_iam_role" "ecr_push" {
  name                 = "github-actions-ecr-push"
  description          = "GitHub Actions (production env) pushes images to one ECR repo. No cluster access: Argo CD pulls from Git."
  assume_role_policy   = data.aws_iam_policy_document.ecr_push_trust.json
  max_session_duration = 3600 # 1 hour; a release job takes minutes
}

data "aws_iam_policy_document" "ecr_push" {
  # GetAuthorizationToken does not support resource-level permissions; "*" is required by AWS.
  statement {
    sid       = "EcrLogin"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  # Push/pull scoped to this single repository.
  statement {
    sid = "PushPullThisRepoOnly"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
      "ecr:DescribeImages", # read back the pushed digest
    ]
    resources = [aws_ecr_repository.app.arn]
  }
}

resource "aws_iam_role_policy" "ecr_push" {
  name   = "ecr-push-single-repo"
  role   = aws_iam_role.ecr_push.id
  policy = data.aws_iam_policy_document.ecr_push.json
}

############################################
# OPTIONAL: read-only role for `terraform plan` on infra-repo PRs. Off by default.
# Caveats: the infra plan also needs Kubernetes API access for helm_release (cluster endpoint is
# limited to my IP), and ReadOnlyAccess can read the state bucket. Kept off for the demo.
############################################
data "aws_iam_policy_document" "plan_trust" {
  count = var.create_plan_role ? 1 : 0
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.github_oidc}:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.github_oidc}:sub"
      values   = ["repo:${var.github_owner}/${var.infra_repo}:pull_request"]
    }
  }
}

resource "aws_iam_role" "plan" {
  count                = var.create_plan_role ? 1 : 0
  name                 = "github-actions-terraform-plan"
  assume_role_policy   = data.aws_iam_policy_document.plan_trust[0].json
  max_session_duration = 3600
}

resource "aws_iam_role_policy_attachment" "plan_readonly" {
  count      = var.create_plan_role ? 1 : 0
  role       = aws_iam_role.plan[0].name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/ReadOnlyAccess"
}

############################################
# AWS Budget: $20/month, email at 50/80/100%. Cost: $0 (first 2 budgets are free).
############################################
resource "aws_budgets_budget" "monthly" {
  name         = "spr-monthly-budget"
  budget_type  = "COST"
  limit_amount = tostring(var.budget_limit_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  dynamic "notification" {
    for_each = [50, 80, 100]
    content {
      comparison_operator        = "GREATER_THAN"
      threshold                  = notification.value
      threshold_type             = "PERCENTAGE"
      notification_type          = "ACTUAL"
      subscriber_email_addresses = [var.budget_email]
    }
  }
}
