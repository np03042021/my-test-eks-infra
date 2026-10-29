provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = "secure-paved-road"
      Stack       = "infra"
      Environment = "demo"
      ManagedBy   = "terraform"
    }
  }
}

# Helm talks to the cluster with a short-lived token from `aws eks get-token` (your SSO session).
# No static kubeconfig or long-lived ServiceAccount token is stored anywhere.
provider "helm" {
  kubernetes = {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.region]
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  name       = var.name
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  azs        = var.azs
}

############################################
# VPC: 2 AZs, public subnets only, NO NAT gateway.
# DEMO ONLY: production puts nodes in private subnets with NAT or VPC endpoints (ECR, STS, S3, Secrets Manager).
# Cost: VPC/subnets/IGW are free; NAT would be ~$1.30/day + data, which is why it's omitted.
############################################
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "6.7.3" # check: https://registry.terraform.io/modules/terraform-aws-modules/vpc/aws/latest

  name = local.name
  cidr = var.vpc_cidr
  azs  = local.azs

  public_subnets          = [cidrsubnet(var.vpc_cidr, 4, 0), cidrsubnet(var.vpc_cidr, 4, 1)] # 10.30.0.0/20, 10.30.16.0/20
  map_public_ip_on_launch = true                                                             # DEMO ONLY: nodes need a public IP to reach ECR/STS without NAT

  enable_nat_gateway   = false
  enable_dns_hostnames = true # required for the EKS private endpoint to resolve inside the VPC
  enable_dns_support   = true

  # Lock down the default SG: no ingress, no egress. Nothing should ever use it.
  manage_default_security_group  = true
  default_security_group_ingress = []
  default_security_group_egress  = []

  # Lets the AWS Load Balancer Controller discover subnets for internet-facing ALBs.
  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }
}
