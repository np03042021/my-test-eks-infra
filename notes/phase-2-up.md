# Phase 2: Bring the platform up (`scripts/up.sh`) and verify it

**Done:** 2026-10-29. **Billing:** started at up.sh (~$3.50/day until the ALB in Phase 6). Run `scripts/down.sh` the same day.

## Command

```bash
aws sso login
APP_REPO=https://github.com/np03042021/secure-paved-road-eks.git \
BUDGET_EMAIL=<budget email> \
bash scripts/up.sh          # run in a separate Terminal window, not inside Claude
```

`APP_REPO` and `BUDGET_EMAIL` are required on purpose (`${VAR:?}` guard) — the script refuses to guess them.

## Result

- Infra apply: **67 resources added**. Cluster `spr`, Kubernetes v1.36.5, VPC `vpc-0b2023e2cfbaffd37`.
- Outputs feed Phase 6 GitHub variables: `AWS_REGION`, `ECR_REPOSITORY` (…/secure-paved-road-app), `AWS_ROLE_ARN` (github-actions-ecr-push).
- Argo CD finalizer warning (`prefer a domain-qualified finalizer name`) is harmless: `resources-finalizer.argocd.argoproj.io` is Argo CD's official name.

## Verification evidence

| Check | How | Result |
|---|---|---|
| Nodes | `kubectl get nodes -o wide` | 2 × Ready, AL2023, amd64, containerd |
| Spot + IMDS | `aws ec2 describe-instances ... MetadataOptions` | both `spot`, HttpTokens `required`, hop limit `1` |
| **Pods can't reach IMDS** | throwaway curl pod → `PUT 169.254.169.254/latest/api/token` | **timed out, HTTP 000 — blocked** |
| Add-ons | `aws eks describe-addon` | vpc-cni, pod-identity-agent, kube-proxy, coredns all ACTIVE at pinned versions |
| NetworkPolicy enforcement | vpc-cni `configurationValues` | `{"enableNetworkPolicy":"true"}` |
| EKS endpoint | `describe-cluster ... resourcesVpcConfig` | public + private on; public allows only my /32 |
| Pod Identity | `aws eks list-pod-identity-associations` | kube-system/aws-load-balancer-controller, external-secrets/external-secrets |
| Controllers | `kubectl get pods` in kube-system, external-secrets, argocd | all Running 1/1 |
| ClusterSecretStore | `kubectl get clustersecretstore` | `Valid`, `READY True` (ESO authenticated via Pod Identity, no static creds) |
| Argo CD app | `kubectl -n argocd get application spr-app` | `Unknown` / ComparisonError `charts/app: app path does not exist` — **expected** until the chart exists (Phase 5/6) |
| Auditor Lambda | `aws lambda invoke --function-name spr-security-auditor` | 200; checked 5 SGs, 0 access keys, 1 cluster; **0 findings** |

Notes:
- `CAPABILITIES ReadWrite` on the ClusterSecretStore is what the ESO *provider* supports, not what the IAM role allows — the role can only `GetSecretValue`/`DescribeSecret` on `spr/demo`.
- 0 findings is the correct baseline: no open SGs, no IAM users with keys (SSO only), endpoint limited to a /32. Phase 8 opens an SG by hand to show the auditor catch it.

## Argo CD UI

```bash
kubectl -n argocd port-forward svc/argocd-server 8080:443     # leave running; open https://localhost:8080 (user admin)
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
```

The browser warns about a self-signed cert — expected; Argo CD's own cert over a local port-forward. No load balancer, no internet exposure.

## Gotcha

- A non-interactive shell (e.g. Claude's) may not load `~/.zshrc`, so `aws` says `NoCredentials` while `kubectl` still works
  (update-kubeconfig stored `AWS_PROFILE` in the kubeconfig exec block). Fix: `export AWS_PROFILE=spr`.

## Say this in the interview

> "I don't just claim pods can't steal the node role — I proved it. A pod's request to the instance metadata service
> times out because IMDSv2 is required with a hop limit of 1, and the only AWS credentials a pod can get come from Pod
> Identity, scoped per ServiceAccount. External Secrets authenticated to Secrets Manager that way with no static keys, and
> the daily auditor ran clean as a baseline, so any finding later is a real change."
