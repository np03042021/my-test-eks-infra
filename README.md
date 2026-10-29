# secure-paved-road-eks-infra

Terraform for the **Secure Paved Road on EKS** demo. It creates every piece of AWS infrastructure a team
needs to ship a container safely, with security turned on by default:

- **GitHub OIDC** instead of AWS keys.
- **A CI role that can only push to one ECR repo.**
- **Pull-based deploys:** Argo CD pulls from Git, so CI never holds cluster credentials.
- **Per-controller EKS Pod Identity roles.**
- **KMS-encrypted Kubernetes Secrets.**
- **Enforced NetworkPolicies.**
- **A daily Python security auditor.**

> **Cost warning:** about **USD 4–5 per day** while the cluster runs. Run `./scripts/down.sh` **the same day.**

## Layout

| Path | What | State |
|---|---|---|
| `bootstrap/` | S3 state bucket, ECR repo, GitHub OIDC provider and push role, AWS Budget | local (gitignored) |
| `infra/` | VPC, EKS, node group, Pod Identity, LBC / ESO / Argo CD (Helm), Secrets Manager secret, auditor Lambda | S3 (`use_lockfile`) |
| `infra/auditor/` | Lambda source, pytest suite, hash-pinned dev lockfile | n/a |
| `k8s-bootstrap/` | `ClusterSecretStore`, Argo CD `AppProject` and `Application` | applied by `up.sh` |
| `scripts/` | `up.sh`, `down.sh`, `verify-tools.sh` | n/a |

## Usage

```bash
aws sso login
export APP_REPO=https://github.com/np03042021/secure-paved-road-eks.git
export BUDGET_EMAIL=you@example.com
./scripts/up.sh            # ~20 min; AUTO_APPROVE=1 skips the Terraform prompts
./scripts/down.sh          # destroys infra, the billable part
./scripts/down.sh --all    # also destroys bootstrap (state bucket, ECR, OIDC, budget)
```

## Cost estimate (ap-south-1, USD)

| Resource | Rate | Per day |
|---|---|---|
| EKS control plane (standard support) | $0.10/hr | 2.40 |
| 2× Spot t3/t3a.medium nodes | $0.009–0.021/hr each (Spot, 2026-10-28) | 0.45–1.00 |
| Public IPv4: 2 nodes (+2 for the ALB from Phase 6) | $0.005/hr each | 0.24 (0.48) |
| 2× 20 GB gp3 root volumes | ~$0.08–0.09/GB-month | ~0.12 |
| ALB (from Phase 6) | ~$0.0225/hr + LCU | ~0.55 |
| KMS key for EKS Secrets | $1/month | 0.03 |
| CloudWatch control-plane logs (3-day retention) | ingestion per GB | 0.05–0.20 |
| Secrets Manager (1 secret) | $0.40/month | 0.01 |
| Lambda, EventBridge, ECR, S3 state, Budget | free tier / KB-scale | ~0.00 |
| **Total** | | **~3.3–4.0 without the ALB, ~4.0–4.8 with it** |

The budget alerts by email at 50%, 80% and 100% of $20/month. Avoided on purpose: NAT gateway (~$1.30/day plus data),
a second load balancer for Argo CD (port-forward instead), and extended-support Kubernetes (6× the control-plane price).

## DEMO ONLY shortcuts and production alternatives

| Shortcut | Production alternative |
|---|---|
| Public subnets, no NAT | Private node subnets + NAT or VPC endpoints (ECR, STS, S3, Secrets Manager) |
| Spot nodes, single-replica controllers | On-Demand or mixed capacity, ≥2 replicas + PodDisruptionBudgets |
| Public EKS endpoint (your /32 only) | Private endpoint only, reached through VPN or SSM |
| `force_destroy` / `force_delete` / `recovery_window_in_days = 0` | Deletion protection and recovery windows |
| AWS-managed keys for S3, ECR, Secrets Manager, logs | Customer-managed KMS keys with scoped key policies |
| Short log retention (3 / 7 days) | ≥1 year, or shipped to a SIEM |
| Argo CD local admin, no SSO | OIDC SSO (Identity Center), local admin disabled |
| Bootstrap uses local state | Migrate it into the bucket after the first apply |

## Security notes worth knowing

- **Secret value never touches Terraform state.** It uses an `ephemeral "random_password"` and the
  write-only `secret_string_wo` attribute.
- **The ESO role is hand-written.** The community module's policy grants `ListSecrets`/`BatchGetSecretValue`
  on `*` and `kms:Decrypt` on every key. This role reads exactly `spr/demo`. The `ClusterSecretStore` is
  also limited to the `spr-app` namespace.
- **IMDSv2 with hop limit 1.** Pods can't reach instance metadata, so they can't use the node role. That's
  why the LBC gets `region` and `vpcId` explicitly.
- **Scoped Argo CD project.** The `AppProject` allows only the app repo and the `spr-app` namespace, and the
  only cluster-scoped resource it can create is its own Namespace.

## Keeping versions current

| What | How to check |
|---|---|
| Providers | `terraform -chdir=infra init -upgrade`, then review the diff in `.terraform.lock.hcl`. Re-lock for both platforms: `terraform providers lock -platform=darwin_arm64 -platform=linux_amd64` |
| Modules | Registry pages linked in the `version =` comments |
| Helm charts | `helm repo update && helm search repo eks/aws-load-balancer-controller` (same for `external-secrets/external-secrets` and `argo/argo-cd`) |
| EKS version | `aws eks describe-cluster-versions --query "clusterVersions[].[clusterVersion,versionStatus]"` (stay in `STANDARD_SUPPORT`) |
| EKS add-ons | `aws eks describe-addon-versions --kubernetes-version 1.36 --addon-name vpc-cni` |
| GitHub Actions | `gh api repos/<owner>/<action>/tags`. Pin the SHA of the newest **semver tag**, not the "latest release" badge, which was stale for checkov-action |
| pre-commit hooks | `pre-commit autoupdate --freeze` |

## Local checks (same as CI)

```bash
terraform fmt -recursive -check .
terraform -chdir=bootstrap init -backend=false && terraform -chdir=bootstrap validate
terraform -chdir=infra init -backend=false && terraform -chdir=infra validate
checkov --config-file .checkov.yaml
cd infra/auditor && python3.12 -m venv .venv \
  && .venv/bin/pip install --require-hashes --only-binary ':all:' -r requirements-dev.txt \
  && .venv/bin/pytest -q && pip-audit --require-hashes --disable-pip -r requirements-dev.txt
pre-commit run --all-files
```
