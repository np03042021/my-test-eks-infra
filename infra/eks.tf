############################################
# EKS cluster
# Cost: control plane $0.10/hr (~$2.40/day) in standard support; $0.60/hr in extended support.
############################################
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "21.29.0" # check: https://registry.terraform.io/modules/terraform-aws-modules/eks/aws/latest

  name               = local.name
  kubernetes_version = var.kubernetes_version

  # API endpoint: public only from my IP /32, plus private so nodes talk to it inside the VPC.
  # Prod: endpoint_public_access = false, reach the API via VPN/bastion/SSM.
  endpoint_public_access       = true
  endpoint_public_access_cidrs = [var.my_ip_cidr]
  endpoint_private_access      = true

  # Access entries (EKS API) instead of the legacy aws-auth ConfigMap: auditable, managed via IAM APIs.
  authentication_mode                      = "API"
  enable_cluster_creator_admin_permissions = true # the SSO role running Terraform becomes cluster admin

  # Envelope-encrypt Kubernetes Secrets in etcd with a KMS key the module creates.
  # Cost: $1/month per CMK, prorated (~$0.03/day).
  encryption_config = {
    resources = ["secrets"]
  }
  kms_key_deletion_window_in_days = 7 # minimum allowed; key is deleted soon after destroy

  # Control-plane logs: who did what (audit), API activity, and IAM authentication.
  # Cost: CloudWatch ingestion ~$0.50-0.76/GB; a quiet demo cluster is cents per day.
  enabled_log_types                      = ["api", "audit", "authenticator"]
  cloudwatch_log_group_retention_in_days = 3 # DEMO ONLY: prod keeps audit logs >= 1 year (often shipped to a SIEM)

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.public_subnets # DEMO ONLY: prod uses private subnets

  # Managed add-ons, versions pinned (most_recent = false) so applies are reproducible.
  # Check defaults: aws eks describe-addon-versions --kubernetes-version 1.36 --addon-name <name>
  addons = {
    vpc-cni = {
      addon_version  = "v1.22.4-eksbuild.8"
      most_recent    = false
      before_compute = true # CNI must exist before nodes join, or pods have no network
      # Turns on the VPC CNI network policy agent so Kubernetes NetworkPolicies are ENFORCED.
      configuration_values = jsonencode({
        enableNetworkPolicy = "true"
      })
    }
    eks-pod-identity-agent = {
      addon_version  = "v1.4.1-eksbuild.3"
      most_recent    = false
      before_compute = true # controllers need credentials as soon as they start
    }
    kube-proxy = {
      addon_version = "v1.36.0-eksbuild.55"
      most_recent   = false
    }
    coredns = {
      addon_version = "v1.14.7-eksbuild.19"
      most_recent   = false
    }
  }

  eks_managed_node_groups = {
    spot = {
      # Cost: t3/t3a.medium Spot in ap-south-1 is $0.009-0.021/hr each (2026-10-28; ~$0.45-1.00/day for 2),
      # check: aws ec2 describe-spot-price-history --instance-types t3.medium t3a.medium --product-descriptions Linux/UNIX
      # plus 20 GB gp3 (~$0.06/day for 2) and a public IPv4 per node ($0.005/hr each).
      ami_type       = "AL2023_x86_64_STANDARD"
      capacity_type  = "SPOT"                      # DEMO ONLY: prod uses On-Demand (or mixed) for critical workloads
      instance_types = ["t3.medium", "t3a.medium"] # two pools = better Spot availability

      min_size     = 1
      max_size     = 2
      desired_size = 2

      subnet_ids = module.vpc.public_subnets

      # IMDSv2 only, hop limit 1: containers (one extra network hop) cannot reach the instance
      # metadata service, so pods cannot steal the node IAM role. Pods get AWS creds via Pod Identity.
      metadata_options = {
        http_endpoint               = "enabled"
        http_tokens                 = "required"
        http_put_response_hop_limit = 1
      }

      # Encrypted gp3 root volume (AWS-managed EBS key).
      block_device_mappings = {
        xvda = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size           = 20
            volume_type           = "gp3"
            encrypted             = true
            delete_on_termination = true # no orphaned (billable) volumes after scale-in or destroy
          }
        }
      }
      # No key_name / remote access: no SSH. Node SG has no inbound rule from the internet.
      # Break-glass access in prod: SSM Session Manager.
    }
  }
}
