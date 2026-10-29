# Phase 1: Infra repo code (secure-paved-road-eks-infra)

**Goal:** One repo that creates all the AWS infrastructure for the paved road, with security on by default and one-command teardown.
**Built:** 2026-10-28. **Committed and pushed:** 2026-10-29 (c3f35c3 feat, 01f43c9 gitleaks fix). **CI:** all 5 jobs green. **AWS cost of this phase:** $0 (nothing applied yet).

## How the pieces fit

```
bootstrap/  (run once, local state)   →  S3 state bucket, ECR, GitHub OIDC + push role, Budget
     │ outputs the bucket name
     ▼
infra/  (state stored in that bucket)  →  VPC → EKS + Spot nodes → Pod Identity roles → Helm (LBC, ESO, Argo CD)
                                         + Secrets Manager secret + daily auditor Lambda
     ▼
k8s-bootstrap/  (kubectl apply)        →  ClusterSecretStore + Argo CD project/app → pulls the app repo
scripts/up.sh runs all three in order; scripts/down.sh reverses them safely.
```

## Pinned versions (as of 2026-10-28)

- Terraform 1.15.4 locally and in CI (`>= 1.10` for bootstrap, `>= 1.11` for infra because of write-only attributes).
- Providers: AWS 6.70, Helm 3.3, random 3.9, archive 2.8. Lock files cover darwin_arm64 + linux_amd64.
- Modules: VPC 6.7.3, EKS 21.29.0, eks-pod-identity 2.10.0.
- Helm charts: AWS Load Balancer Controller 3.6.2, External Secrets 2.14.0, Argo CD (argo-cd chart) 10.11.6.
- Kubernetes 1.36 (standard support until 2027-08-02). Add-ons: vpc-cni v1.22.4-eksbuild.8, eks-pod-identity-agent
  v1.4.1-eksbuild.3, kube-proxy v1.36.0-eksbuild.55, coredns v1.14.7-eksbuild.19.

How to check each is current:

| What | How |
|---|---|
| Providers | `terraform -chdir=infra init -upgrade`, review `.terraform.lock.hcl`, re-lock: `terraform providers lock -platform=darwin_arm64 -platform=linux_amd64` |
| Modules | registry pages linked in the `version =` comments |
| Helm charts | `helm repo update && helm search repo <repo>/<chart>` |
| EKS version | `aws eks describe-cluster-versions` (must be STANDARD_SUPPORT) |
| Add-ons | `aws eks describe-addon-versions --kubernetes-version 1.36 --addon-name <name>` |
| Actions / hooks | release page of each action; `pre-commit autoupdate --freeze` |

---

## 1. `bootstrap/` — applied once with SSO admin, local state

- **versions.tf**: AWS provider `~> 6.70`; local state on purpose (this stack creates the state bucket — chicken and egg). Prod: migrate this state into the bucket after first apply.
- **variables.tf**: region, GitHub owner, repo names, budget. `budget_email` has no default so the email is never committed. `create_plan_role` defaults to false.
- **main.tf**:

| Block | What | Why |
|---|---|---|
| `default_tags` | Project/Stack/Environment/ManagedBy on everything | cost allocation; leftovers easy to find |
| State bucket | versioned, SSE-KMS (aws/s3 key, bucket key on), public access block, `BucketOwnerEnforced` (no ACLs), noncurrent versions expire after 30d | state holds sensitive attributes; versioning recovers bad state |
| TLS-only bucket policy | Deny `s3:*` when `aws:SecureTransport=false` | no plaintext access |
| `force_destroy = true` | DEMO ONLY so `down.sh --all` works | prod: false + SCP deletion protection |
| ECR | IMMUTABLE tags, scan on push, KMS, keep last 5 images, `force_delete` (DEMO ONLY) | tag/digest always means the same bits; capped storage |
| GitHub OIDC provider | short-lived creds for Actions; no thumbprint (AWS validates GitHub's CA itself) | no AWS keys in GitHub |
| Push role trust | `StringEquals` aud = sts.amazonaws.com and sub = `repo:np03042021/secure-paved-road-eks:environment:production` | only the approved production environment; never `StringLike` wildcards |
| Push role policy | `ecr:GetAuthorizationToken` on `*` (AWS requires it) + push/pull/DescribeImages on one repo ARN; 1h max session | least privilege; **no EKS access — Argo CD pulls from Git** |
| Optional plan role | read-only OIDC role for infra-repo PRs | off: ReadOnlyAccess can read the state bucket, and plan would also need the cluster API |
| Budget | $20/month, emails at 50/80/100% | cost safety net; first 2 budgets free |

- **outputs.tf**: state bucket, ECR URL, push role ARN (→ GitHub variables in Phase 6), optional plan role ARN.

## 2. `infra/` — the platform

- **versions.tf**: S3 backend with `use_lockfile = true` (S3-native locking, no DynamoDB); bucket passed at `init -backend-config`.
- **variables.tf**:
  - `kubernetes_version = "1.36"` — standard support (extended support is 6x the price).
  - `azs` pinned to ap-south-1a/1b with validation of exactly 2 (fix for a Checkov finding about the AZ data source — fixed, not skipped).
  - `my_ip_cidr` validated: must be a /32 and never 0.0.0.0 — the API can't be opened to the world even by mistake.
- **main.tf**:
  - Helm provider authenticates via `aws eks get-token` (short-lived, from SSO) — no stored kubeconfig or SA token.
  - VPC: 2 public /20 subnets, **no NAT** (~$1.30/day saved; DEMO ONLY — prod: private subnets + NAT or VPC endpoints for ECR/STS/S3/Secrets Manager), DNS on, default SG locked to zero rules, subnets tagged `kubernetes.io/role/elb=1`.
- **eks.tf**:

| Setting | Why |
|---|---|
| Public endpoint only from `my_ip_cidr`, private endpoint on | only the laptop reaches the API; nodes use the private endpoint. Prod: private only via VPN/SSM |
| `authentication_mode = "API"` + creator admin | access entries instead of the aws-auth ConfigMap; auditable via IAM |
| `encryption_config = secrets` | KMS envelope encryption of Secrets in etcd (~$0.03/day) |
| Logs api/audit/authenticator, 3-day retention | who did what; DEMO ONLY retention (prod >= 1 year / SIEM) |
| Add-ons pinned, `most_recent = false`; vpc-cni + pod-identity-agent `before_compute` | reproducible; networking and creds ready before nodes |
| vpc-cni `enableNetworkPolicy = "true"` | otherwise NetworkPolicies exist but are NOT enforced (Phase 8 demo depends on it) |
| Spot t3/t3a.medium, min 1 / max 2 / desired 2, AL2023 | two pools improve Spot availability; DEMO ONLY Spot |
| IMDSv2 required, **hop limit 1** | pods are one hop away, so they can't reach IMDS and steal the node role; pods use Pod Identity |
| 20 GB encrypted gp3, `delete_on_termination` | no orphaned billable volumes |
| No `key_name` | no SSH; prod break-glass via SSM |

- **pod_identity.tf**:
  - LBC: community module with AWS's maintained policy.
  - **ESO role hand-written**: the module's ESO policy grants `ListSecrets` + `BatchGetSecretValue` on `*` and `kms:Decrypt` on all keys. Trust = `pods.eks.amazonaws.com` with confused-deputy conditions (`aws:SourceAccount` + `aws:SourceArn` = this cluster). Permissions = `GetSecretValue`/`DescribeSecret` on the one `spr/demo` ARN. No kms:Decrypt needed (AWS-managed key).
- **helm.tf** (single replicas — DEMO ONLY, prod >= 2 + PDBs):
  - LBC 3.6.2: `region` and `vpcId` explicit (hop limit 1 blocks IMDS discovery); `enableServiceMutatorWebhook = false` because we only use Ingress and a fail-closed webhook with 1 replica would block every Service creation when the pod is down.
  - ESO 2.14.0: SA name must match the Pod Identity association.
  - Argo CD 10.11.6: dex + notifications off (DEMO ONLY: local admin; prod OIDC SSO), server ClusterIP via port-forward — no second LB, no internet exposure.
- **secrets.tf**: `ephemeral "random_password"` + write-only `secret_string_wo` → **the token never enters state or plan output**. Rotate by bumping `secret_string_wo_version`. `recovery_window_in_days = 0` is DEMO ONLY.
- **auditor.tf**: zips only `handler.py`; log group created by Terraform (7-day retention, so no `logs:CreateLogGroup`); IAM = exactly the 5 API calls (`*` only where AWS doesn't support resource scoping) + write to its own log group; arm64 python3.12; daily EventBridge rule; `aws_lambda_permission` lets only that rule invoke it.
- **outputs.tf**: cluster name, region, `vpc_id` (used by down.sh), secret name, Lambda name, kubeconfig command.

## 3. `infra/auditor/` — Python with supply-chain hygiene

- **handler.py**: pure rule functions (no AWS calls) separated from a thin boto3 adapter; boto3 imported lazily inside `handler()`.
  - `find_open_security_groups`: 0.0.0.0/0 or ::/0 on anything except 80/443; all-traffic = `"ALL"`; a 80–443 range is flagged.
  - `find_stale_access_keys`: active keys > 90 days; `now` injected for tests; key IDs masked (`AKIA...3456`).
  - `find_public_eks_endpoints`: public endpoint allowing 0.0.0.0/0.
  - One JSON log line per finding → ready for a CloudWatch metric-filter alarm.
- **tests/test_handler.py**: 16 tests — every rule plus IPv6, ICMP, exactly-90-days, inactive keys, private-only endpoint, and an end-to-end handler test with a fake boto3.
- **requirements-dev.in** (just `pytest`) → **requirements-dev.txt** from `pip-compile --generate-hashes --strip-extras` on Python 3.12 (same as Lambda). Regenerate, never hand-edit.

## 4. `k8s-bootstrap/`

- **cluster-secret-store.yaml**: no `auth` block → no static creds, ESO uses Pod Identity. `conditions.namespaces: [spr-app]` so other namespaces can't copy `spr/demo` (beyond the spec).
- **argocd-app.yaml.tpl**: dedicated AppProject `spr` (only the app repo, only `spr-app`, only Namespace as a cluster-scoped kind) instead of `default`; Application with automated prune + selfHeal and the `resources-finalizer` so deleting the app deletes the Ingress → ALB.

## 5. `scripts/`

- **up.sh** (`APP_REPO` and `BUDGET_EMAIL` required, `AUTO_APPROVE=1` optional): check SSO → detect IP and validate IPv4 → apply bootstrap → read outputs → init infra against the bucket and apply (15–20 min) → update-kubeconfig → wait for ESO CRDs → apply manifests (template rendered with `sed`) → print `gh variable set` commands, Argo CD login, cost reminder.
- **down.sh** (`--all` also destroys bootstrap): if the IP changed, add the new /32 to the endpoint first → delete Argo CD app → delete all Ingresses → **wait until 0 ALBs in the VPC** (controller-made ALBs' ENIs would hang the VPC destroy) → destroy infra → optional bootstrap → leftover check (LBs, classic LBs, EIPs, unattached volumes, clusters, NAT gateways).
- **verify-tools.sh**: Phase 0 tool check.

## 6. Hygiene and CI

- **.gitignore**: state, tfvars, `.terraform/`, build zip, SARIF, Python caches, editor dirs. Lock files ARE committed. CLAUDE.md and notes/ are local only.
- **.pre-commit-config.yaml**: gitleaks, terraform_fmt, detect-private-key, check-yaml; every `rev` frozen to a commit SHA (tags are mutable).
- **.checkov.yaml**: fix first, suppress second. One repo-wide skip (`CKV_TF_1` — modules pinned by exact registry version, not git SHA; prod: private registry or `git::...?ref=<sha>`). All other skips inline with reasons.
- **.github/workflows/iac.yml**: `permissions: {}` default, per-job opt-in; every action SHA-pinned with version comment; `persist-credentials: false`; concurrency cancels stale runs. Jobs:
  - gitleaks over full history (`fetch-depth: 0`).
  - terraform matrix (bootstrap, infra): `fmt -check`, `init -backend=false -lockfile=readonly` (fails on provider hash drift), `validate`. No AWS creds in CI.
  - checkov (Terraform + GitHub Actions) → SARIF uploaded even on failure (`security-events: write`).
  - auditor: `pip install --require-hashes --only-binary ':all:'` (wheels only, no build scripts), pytest, pip-audit.
- **README.md**: layout, usage, cost table, DEMO ONLY table, security notes, version-check table.

## Where the build deviated from the spec, and why

- Secret value never enters Terraform state (ephemeral password + write-only attribute) instead of a plain `random_password`.
- ESO role hand-written; the community module's policy was too broad.
- ClusterSecretStore restricted to `spr-app`.
- Argo CD uses a dedicated AppProject instead of `default`.
- LBC Service webhook disabled (fail-closed + 1 replica would block Service creation).
- AZs pinned to ap-south-1a/1b — Checkov flagged the AZ lookup, fixed rather than skipped.

## Problems hit while building (good interview stories)

- checkov-action's "latest release" (v12.1347.0) actually ran **Checkov 2.0.930 from 2022**. Pinned v12.3135.0 (runs 3.3.30). Lesson: check what a pinned SHA actually runs, not just its label.
- `pre-commit autoupdate --freeze` via pipx pinned gitleaks v8.30.0; hand-pinned the v8.30.1 SHA to match the local binary.
- macOS bash 3.2 errors on empty arrays under `set -u` → `${APPROVE[@]+"${APPROVE[@]}"}` pattern in up.sh/down.sh.
- **First CI run failed on gitleaks (2026-10-29)** even though local pre-commit passed. Cause: gitleaks-action downloads
  its own default scanner (8.24.3) while the local hook runs 8.30.1; the older ruleset flagged the fake key
  `AKIAEXAMPLEKEY123456` in the auditor tests. Fix (no suppression): pinned `GITLEAKS_VERSION: "8.30.1"` in iac.yml and
  changed the fixture to `TESTKEYID00000003456`. Lesson: pin the *scanner version*, not just the action SHA — the same
  drift as the checkov-action story. Commit 01f43c9; run 40847748573 all green.
- check-yaml caught `--only-binary :all: ` in the workflow (YAML parsed it as a key/value) → quoted `':all:'`.

## Local verification results (2026-10-28)

| Check | Result |
|---|---|
| `terraform fmt -check -recursive` | clean |
| `terraform validate` (bootstrap, infra) | both valid |
| Checkov Terraform | 128 passed, 0 failed, 13 skipped (all with reasons) |
| Checkov GitHub Actions | 80 passed, 0 failed |
| pytest (auditor) | 16 passed |
| pip-audit (hashed lockfile) | no known vulnerabilities |
| pre-commit (4 hooks) | 4/4 passed |

Re-run locally:

```bash
export PATH="$HOME/.local/bin:$PATH"
terraform fmt -recursive -check .
terraform -chdir=infra init -backend=false && terraform -chdir=infra validate
checkov --config-file .checkov.yaml
(cd infra/auditor && python3.12 -m pytest -q)
pip-audit -r infra/auditor/requirements-dev.txt --require-hashes
pre-commit run --all-files
```

## Common errors

| Symptom | Fix |
|---|---|
| CI `terraform init`: Inconsistent dependency lock file | `terraform providers lock -platform=darwin_arm64 -platform=linux_amd64`, commit the lock file |
| SARIF upload: Resource not accessible by integration | repo must be public (it is) and the job needs `security-events: write` (it has it) |
| pre-commit gitleaks fails on commit | inspect with `gitleaks git --staged -v`; never `--no-verify` |
| pip: Hashes are required in --require-hashes mode | someone hand-edited the lockfile; regenerate with the pip-compile command in requirements-dev.in |

## Say this in the interview

> "The infra repo is the paved road itself. CI authenticates to AWS through OIDC, and only from a GitHub environment I have to approve. The push role can touch exactly one ECR repo, and nothing in CI can reach the cluster, because Argo CD pulls from Git. I reviewed the community modules' generated IAM rather than trusting them. The External Secrets policy granted ListSecrets on every secret, so I wrote that role myself. The secret's value never lands in Terraform state, because I used an ephemeral password with a write-only attribute. Every Checkov suppression sits next to its resource with a reason, and my rule is fix first: when Checkov flagged the AZ data source, I changed the code instead of skipping the check."

Likely follow-ups to be ready for:
- *Why hop limit 1?* Pods are one extra network hop from IMDS; with limit 1 the response can't reach them, so they can't use the node role. They get scoped creds through Pod Identity instead.
- *Why Pod Identity over IRSA?* No per-cluster OIDC provider to manage, trust policy is a single service principal with SourceArn/SourceAccount conditions, and associations are managed through the EKS API.
- *Why not public subnets in prod?* Nodes would have public IPs; prod uses private subnets + NAT or VPC endpoints. Here it's a cost trade-off, labelled DEMO ONLY.
- *How do you know your pinned action does what its tag says?* The checkov-action story above.
