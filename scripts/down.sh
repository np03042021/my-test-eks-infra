#!/usr/bin/env bash
# Tear everything down in a safe order.
#   ./scripts/down.sh          destroy infra (cluster, VPC, controllers, secret, auditor)
#   ./scripts/down.sh --all    also destroy bootstrap (state bucket, ECR, OIDC roles, budget)
# Set AUTO_APPROVE=1 to skip the Terraform approval prompts.
set -euo pipefail

ALL=false
[[ "${1:-}" == "--all" ]] && ALL=true
REGION="${AWS_REGION:-ap-south-1}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APPROVE=()
[[ "${AUTO_APPROVE:-0}" == "1" ]] && APPROVE=(-auto-approve)
export AWS_PAGER=""

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

aws sts get-caller-identity --query Arn --output text \
  || { echo "No valid AWS session. Run: aws sso login"; exit 1; }

MY_IP="$(curl -fsS https://checkip.amazonaws.com | tr -d '[:space:]')"
STATE_BUCKET="$(terraform -chdir="$ROOT/bootstrap" output -raw state_bucket 2>/dev/null || true)"

if [[ -n "$STATE_BUCKET" ]]; then
  terraform -chdir="$ROOT/infra" init -input=false -reconfigure -backend-config="bucket=${STATE_BUCKET}" >/dev/null
  CLUSTER="$(terraform -chdir="$ROOT/infra" output -raw cluster_name 2>/dev/null || true)"
  VPC_ID="$(terraform -chdir="$ROOT/infra" output -raw vpc_id 2>/dev/null || true)"
else
  CLUSTER=""; VPC_ID=""
fi

if [[ -n "$CLUSTER" ]] && aws eks describe-cluster --name "$CLUSTER" --region "$REGION" >/dev/null 2>&1; then
  # If your IP changed since up.sh, the API (and Terraform's Helm provider) can't be reached. Allow the new /32 first.
  ALLOWED="$(aws eks describe-cluster --name "$CLUSTER" --region "$REGION" \
    --query 'cluster.resourcesVpcConfig.publicAccessCidrs' --output text)"
  if [[ "$ALLOWED" != *"${MY_IP}/32"* ]]; then
    log "Your IP changed; allowing ${MY_IP}/32 on the EKS endpoint so teardown can reach the cluster"
    aws eks update-cluster-config --name "$CLUSTER" --region "$REGION" \
      --resources-vpc-config "endpointPublicAccess=true,endpointPrivateAccess=true,publicAccessCidrs=${MY_IP}/32" >/dev/null
    aws eks wait cluster-active --name "$CLUSTER" --region "$REGION"
  fi

  aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION" >/dev/null

  log "Deleting the Argo CD application (cascade-deletes the Ingress -> ALB)"
  kubectl -n argocd delete application spr-app --ignore-not-found --timeout=5m || true

  log "Deleting any remaining Ingresses"
  kubectl delete ingress --all --all-namespaces --ignore-not-found --timeout=3m || true

  # ALBs are created by the controller, not Terraform. If they still exist, their ENIs and
  # security groups block the VPC/subnet deletion and terraform destroy hangs.
  if [[ -n "$VPC_ID" ]]; then
    log "Waiting for load balancers in ${VPC_ID} to be deleted"
    for _ in $(seq 1 30); do
      COUNT="$(aws elbv2 describe-load-balancers --region "$REGION" \
        --query "length(LoadBalancers[?VpcId=='${VPC_ID}'])" --output text)"
      [[ "$COUNT" == "0" ]] && { echo "No load balancers left in the VPC."; break; }
      echo "  ${COUNT} load balancer(s) still deleting..."; sleep 10
    done
  fi
fi

if [[ -n "$STATE_BUCKET" ]]; then
  log "Destroying infra"
  terraform -chdir="$ROOT/infra" destroy -input=false ${APPROVE[@]+"${APPROVE[@]}"} -var "my_ip_cidr=${MY_IP}/32"
fi

if $ALL; then
  log "Destroying bootstrap (state bucket, ECR, OIDC roles, budget)"
  terraform -chdir="$ROOT/bootstrap" destroy -input=false ${APPROVE[@]+"${APPROVE[@]}"} -var "budget_email=unused@example.com"
fi

log "Leftover check in ${REGION} (everything below should be empty)"
echo "-- Load balancers (ALB/NLB):"
aws elbv2 describe-load-balancers --region "$REGION" --query 'LoadBalancers[].[LoadBalancerName,VpcId]' --output text
echo "-- Classic load balancers:"
aws elb describe-load-balancers --region "$REGION" --query 'LoadBalancerDescriptions[].LoadBalancerName' --output text
echo "-- Elastic IPs:"
aws ec2 describe-addresses --region "$REGION" --query 'Addresses[].[PublicIp,AllocationId,AssociationId]' --output text
echo "-- Unattached EBS volumes:"
aws ec2 describe-volumes --region "$REGION" --filters Name=status,Values=available --query 'Volumes[].[VolumeId,Size]' --output text
echo "-- EKS clusters:"
aws eks list-clusters --region "$REGION" --query 'clusters' --output text
echo "-- NAT gateways (should never exist in this project):"
aws ec2 describe-nat-gateways --region "$REGION" --filter Name=state,Values=available,pending --query 'NatGateways[].NatGatewayId' --output text
