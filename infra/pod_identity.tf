############################################
# EKS Pod Identity: one role per controller, bound to one ServiceAccount. Cost: $0.
# Credentials come from the pod identity agent on the node, not from IMDS (blocked by hop limit 1).
############################################

# AWS Load Balancer Controller: the module ships AWS's maintained LBC policy.
module "lbc_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "2.10.0" # check: https://registry.terraform.io/modules/terraform-aws-modules/eks-pod-identity/aws/latest

  name                            = "${local.name}-aws-lbc"
  attach_aws_lb_controller_policy = true

  associations = {
    this = {
      cluster_name    = module.eks.cluster_name
      namespace       = "kube-system"
      service_account = "aws-load-balancer-controller"
    }
  }
}

# External Secrets Operator: written by hand on purpose. The community module's ESO policy also grants
# secretsmanager:ListSecrets and BatchGetSecretValue on "*" and kms:Decrypt on all keys.
# This role can read exactly one secret and nothing else.
data "aws_iam_policy_document" "eso_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
    # Confused-deputy protection: only Pod Identity acting for THIS account's THIS cluster.
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [module.eks.cluster_arn]
    }
  }
}

resource "aws_iam_role" "eso" {
  name               = "${local.name}-external-secrets"
  description        = "External Secrets Operator: read-only access to the spr/demo secret only"
  assume_role_policy = data.aws_iam_policy_document.eso_trust.json
}

data "aws_iam_policy_document" "eso" {
  statement {
    sid = "ReadDemoSecretOnly"
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
    ]
    resources = [aws_secretsmanager_secret.demo.arn]
  }
  # No kms:Decrypt needed: the secret uses the AWS-managed aws/secretsmanager key,
  # which Secrets Manager uses on the caller's behalf.
}

resource "aws_iam_role_policy" "eso" {
  name   = "read-spr-demo-secret"
  role   = aws_iam_role.eso.id
  policy = data.aws_iam_policy_document.eso.json
}

resource "aws_eks_pod_identity_association" "eso" {
  cluster_name    = module.eks.cluster_name
  namespace       = "external-secrets"
  service_account = "external-secrets"
  role_arn        = aws_iam_role.eso.arn
}
