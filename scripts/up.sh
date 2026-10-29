#!/usr/bin/env bash
# Bring up the whole demo: bootstrap -> infra -> k8s-bootstrap.
#   APP_REPO=https://github.com/np03042021/secure-paved-road-eks.git \
#   BUDGET_EMAIL=you@example.com ./scripts/up.sh
# Set AUTO_APPROVE=1 to skip the Terraform approval prompts.
# COST: the cluster bills ~USD 4-5/day while up. Run ./scripts/down.sh the SAME DAY.
set -euo pipefail

: "${APP_REPO:?Set APP_REPO, e.g. https://github.com/np03042021/secure-paved-road-eks.git}"
: "${BUDGET_EMAIL:?Set BUDGET_EMAIL for AWS Budget alerts}"
REGION="${AWS_REGION:-ap-south-1}"
GITHUB_OWNER="${GITHUB_OWNER:-np03042021}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APPROVE=()
[[ "${AUTO_APPROVE:-0}" == "1" ]] && APPROVE=(-auto-approve)
export AWS_PAGER=""

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

log "Checking AWS credentials"
aws sts get-caller-identity --query Arn --output text \
  || { echo "No valid AWS session. Run: aws sso login"; exit 1; }

log "Detecting your public IP (only this /32 may reach the EKS API)"
MY_IP="$(curl -fsS https://checkip.amazonaws.com | tr -d '[:space:]')"
[[ "$MY_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || { echo "Could not detect a valid IPv4 address: '$MY_IP'"; exit 1; }
echo "Public IP: ${MY_IP}/32"

log "Applying bootstrap (state bucket, ECR, GitHub OIDC, budget)"
terraform -chdir="$ROOT/bootstrap" init -input=false
terraform -chdir="$ROOT/bootstrap" apply -input=false ${APPROVE[@]+"${APPROVE[@]}"} \
  -var "budget_email=${BUDGET_EMAIL}" -var "github_owner=${GITHUB_OWNER}"

STATE_BUCKET="$(terraform -chdir="$ROOT/bootstrap" output -raw state_bucket)"
ECR_URL="$(terraform -chdir="$ROOT/bootstrap" output -raw ecr_repository_url)"
PUSH_ROLE="$(terraform -chdir="$ROOT/bootstrap" output -raw github_ecr_push_role_arn)"

log "Applying infra (VPC, EKS, controllers, secret, auditor) - takes ~15-20 min"
terraform -chdir="$ROOT/infra" init -input=false -reconfigure -backend-config="bucket=${STATE_BUCKET}"
terraform -chdir="$ROOT/infra" apply -input=false ${APPROVE[@]+"${APPROVE[@]}"} -var "my_ip_cidr=${MY_IP}/32"

CLUSTER="$(terraform -chdir="$ROOT/infra" output -raw cluster_name)"

log "Configuring kubectl"
aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION"
kubectl get nodes -o wide

log "Applying k8s-bootstrap (ClusterSecretStore, Argo CD project + application)"
kubectl wait --for=condition=Established --timeout=120s crd/clustersecretstores.external-secrets.io
kubectl apply -f "$ROOT/k8s-bootstrap/cluster-secret-store.yaml"
# Render the template with sed (no envsubst dependency); '|' delimiter because the URL contains '/'.
sed "s|__APP_REPO__|${APP_REPO}|g" "$ROOT/k8s-bootstrap/argocd-app.yaml.tpl" | kubectl apply -f -

log "Done. Set these GitHub repository variables on ${GITHUB_OWNER}/secure-paved-road-eks (Phase 6):"
cat <<EOF
  gh variable set AWS_REGION     --repo ${GITHUB_OWNER}/secure-paved-road-eks --body "${REGION}"
  gh variable set ECR_REPOSITORY --repo ${GITHUB_OWNER}/secure-paved-road-eks --body "${ECR_URL}"
  gh variable set AWS_ROLE_ARN   --repo ${GITHUB_OWNER}/secure-paved-road-eks --body "${PUSH_ROLE}"
EOF

log "Argo CD UI (no load balancer - port-forward only)"
cat <<'EOF'
  kubectl -n argocd port-forward svc/argocd-server 8080:443
  # then open https://localhost:8080  (user: admin)
  kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
EOF

printf '\n\033[1;31mREMINDER: this costs ~USD 4-5/day. Run ./scripts/down.sh today.\033[0m\n'
