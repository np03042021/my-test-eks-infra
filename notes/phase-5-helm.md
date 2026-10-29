# Phase 5: Helm chart `charts/app` + local render, lint and validation (repo: secure-paved-road-eks)

**Built:** 2026-10-29. **AWS cost:** $0 extra (validated locally, plus a server-side dry run against the running cluster).
Staged in the app repo together with Phases 3 and 4, not yet committed.

## Files

```
charts/app/
  Chart.yaml                 name spr-app, version 0.1.0, kubeVersion >=1.33 (needs native preStop sleep)
  values.yaml                every security-relevant value commented, DEMO ONLY items labelled
  values.schema.json         guardrails: Helm refuses to render unsafe values (see below)
  templates/
    _helpers.tpl             standard app.kubernetes.io labels, secret name
    namespace.yaml           spr-app with PSS restricted for enforce/audit/warn, pinned v1.36
    serviceaccount.yaml      dedicated SA, automountServiceAccountToken: false
    deployment.yaml          hardened pod (below)
    service.yaml             ClusterIP only
    pdb.yaml                 minAvailable: 1
    networkpolicy.yaml       default-deny-all, allow-dns-egress, allow-http-from-vpc
    externalsecret.yaml      external-secrets.io/v1, explicit key list, creationPolicy Owner
    ingress.yaml             internet-facing ALB, target-type ip, health check /actuator/health
scripts/validate-chart.sh    lint --strict, template, kubeconform 1.36 strict, Checkov, 7 guardrail tests
src/main/resources/application.properties   + spring.config.import=optional:configtree:/etc/spr/config/
src/test/.../config/SecretFileConfigTest.java   proves a mounted secret file sets GREETING_PREFIX
```

## Verified before writing (not guessed)

- Cluster serves `external-secrets.io/v1` only — **`v1beta1` is `served=false`**, so older ExternalSecret examples would be rejected.
- IngressClass `alb` exists; Deployment/Ingress/NetworkPolicy/PDB API versions read from `kubectl api-resources`.
- kubeconform schemas exist for v1.36.0 (yannh) and the ExternalSecret CRD (datreeio CRDs-catalog).
- Native `lifecycle.preStop.sleep` is in the 1.36 schema (distroless has no `sleep` binary). Server: v1.36.4-eks.

## Design, control by control

| Control | Implementation | Why |
|---|---|---|
| PSS | namespace labels `enforce/audit/warn: restricted`, `*-version: v1.36` | API server rejects non-compliant pods; pinned so a cluster upgrade can't change the policy silently |
| Identity | `runAsNonRoot`, UID/GID 65532 (= Dockerfile `USER`), `fsGroup` 65532 | numeric, high, non-root |
| Container | `allowPrivilegeEscalation: false`, `privileged: false`, `capabilities.drop: [ALL]`, `seccompProfile: RuntimeDefault`, `readOnlyRootFilesystem: true` | what PSS restricted demands + immutable FS |
| Writable path | `/tmp` = `emptyDir{medium: Memory, sizeLimit: 64Mi}` | Tomcat/JVM temp files; nothing else writable |
| API access | `automountServiceAccountToken: false` on SA **and** pod; `enableServiceLinks: false` | app never calls the K8s API; no env var injection of other Services |
| Secrets | ESO syncs **only `GREETING_PREFIX`** (explicit `data` list, not `dataFrom`); mounted read-only at `/etc/spr/config` (mode 0440); Spring `configtree` reads it | API_TOKEN never enters the cluster; secrets as files, not env vars |
| Image | `repository@sha256:…` only; `required` + schema pattern; `pullPolicy: Always` | fail closed until release.yml writes a scanned digest |
| Resources | req 100m/512Mi, limit 1 CPU/512Mi (memory req = limit) | fits t3.medium Spot; JVM heap = 75% of 512Mi |
| Probes | startup (liveness path, 30×5 s = 150 s), liveness, readiness on `/actuator/health/*` | slow JVM start on a busy Spot node doesn't trigger restarts |
| Availability | 2 replicas, topology spread by hostname, PDB minAvailable 1, `maxUnavailable: 0` rollouts | one Spot interruption leaves one replica |
| Shutdown | `preStop.sleep: 10`, `terminationGracePeriodSeconds: 45`, Spring graceful shutdown | ALB deregisters the target before the app stops accepting requests |
| Network | default-deny all ingress+egress; egress only to CoreDNS (kube-system, k8s-app=kube-dns) on 53 UDP/TCP; ingress 8080 only from VPC CIDR | the app makes no outbound calls at all |
| Ingress | `scheme: internet-facing`, `target-type: ip`, `healthcheck-path`, `listen-ports HTTP 80`, `inbound-cidrs`, `drop_invalid_header_fields.enabled=true`, cost tags | DEMO ONLY: HTTP and 0.0.0.0/0 (prod: ACM + 443 redirect, restricted CIDRs/WAF) |

DEMO ONLY NetworkPolicy caveat (say it before they ask): pods share the public subnets with the ALB, so the VPC-CIDR ingress rule also matches other pods' IPs. Production: separate pod subnets (VPC CNI custom networking) so only the ALB subnets are allowed, or Security Groups for Pods.

## Guardrails (values.schema.json) — each rejection verified for the right reason

| Bad value | Rejected by |
|---|---|
| no digest | `'/image/digest': '' does not match pattern '^sha256:[a-f0-9]{64}$'` |
| `digest=latest` (a tag) | same pattern |
| `docker.io/library/nginx` | repository must match `<12-digit account>.dkr.ecr.<region>.amazonaws.com/...` |
| `replicaCount=1` | `minimum: got 1, want 2` |
| `podSecurity.uid=0` | `minimum: got 0, want 10,000` |
| `networkPolicy.ingressCidr=0.0.0.0/0` | `'not' failed` |
| `env.API_TOKEN=…` | `invalid propertyName 'API_TOKEN'` (pattern secret/token/password/key) |

## Verification results

| Check | Result |
|---|---|
| `helm lint --strict` | 0 failed (only "icon is recommended" info) |
| Rendered objects | Namespace, ServiceAccount, Deployment, Service, PDB, 3× NetworkPolicy, ExternalSecret, Ingress (10) |
| kubeconform 1.36 strict + CRD schema | **10 valid, 0 invalid, 0 skipped** |
| Checkov (kubernetes) on rendered chart | first run 95 passed / **1 failed (CKV_K8S_35 secrets as env vars)** → fixed → **96 passed, 0 failed, 0 skipped** |
| Guardrails | 7/7 rejected for the intended reason |
| App tests after configtree change | **38 tests** (new SecretFileConfigTest), 0 failures, coverage gate met |
| Image with secret as file | `docker run` with only `/etc/spr/config/GREETING_PREFIX` mounted read-only, no env var → `{"message":"Hello from a mounted secret, Nikhil"}`; env count of GREETING_PREFIX = 0 |
| **Server-side dry run on the live cluster** (temp namespace `spr-validate` with the chart's PSS labels) | all 9 objects `created (server dry run)` — real PSS admission + ESO/LBC webhooks accepted them, no PSS warnings |
| **PSS negative test** | privileged root pod → `Forbidden: violates PodSecurity "restricted:v1.36": privileged …, allowPrivilegeEscalation != false …` |
| gitleaks on staged files | no leaks |

Temp namespace deleted afterwards.

## Problems hit (interview stories)

1. **Checkov caught a real weakness and I fixed the design instead of skipping it.** The first draft passed `GREETING_PREFIX` as an env var from `secretKeyRef` → `CKV_K8S_35`. Env vars leak via `/proc/<pid>/environ`, child processes, crash dumps and debug output. Fix: mount the secret read-only as files and use Spring's `configtree` import — one line in application.properties, one new test, no change to the app's code. Env var still works locally. Then proved it in Docker with no env var at all.
2. **ESO v1beta1 is switched off** on this ESO version — checked `served` on the CRD before writing, so the chart uses `external-secrets.io/v1`.
3. **Validated against the real API server**, not just schemas: server-side dry run proves PSS admission and the controllers' webhooks accept the objects — something kubeconform alone can't show.

## How Argo CD will behave

The Argo CD Application (infra repo) points at `charts/app` on `main`. With `image.digest: ""` the schema makes rendering fail, so Argo shows a clear ComparisonError ("does not match pattern") instead of deploying an unknown image. In Phase 6 release.yml builds, scans and pushes the image, writes the digest to values.yaml, and Argo deploys it.

## Commands

```bash
cd ~/code/secure-paved-road-eks
./scripts/validate-chart.sh
helm template spr-app charts/app -n spr-app --set image.digest=sha256:$(printf '0%.0s' {1..64}) | less
```

## Common errors

| Symptom | Fix |
|---|---|
| `image.digest ... does not match pattern` | expected before the first release; set by release.yml (or `--set image.digest=sha256:<64 hex>` locally) |
| ExternalSecret `no matches for kind ... in version external-secrets.io/v1beta1` | use `external-secrets.io/v1` |
| ExternalSecret `SecretSyncedError` / store not allowed | ClusterSecretStore only serves `spr-app` (infra repo condition); ESO role only reads `spr/demo` |
| Pod `CreateContainerConfigError: secret "spr-app-config" not found` | ExternalSecret hasn't synced yet; `kubectl -n spr-app describe externalsecret spr-app-config` |
| Pods Pending | 512Mi requests × 2 + controllers on 2 × t3.medium; check `kubectl describe pod` for Insufficient memory |
| ALB not created | `kubectl -n kube-system logs deploy/aws-load-balancer-controller`; subnets need `kubernetes.io/role/elb=1` (set in infra) |
| Readiness fails behind ALB but works locally | NetworkPolicy ingressCidr must cover the VPC (10.30.0.0/16) |

## Say this in the interview

> "The chart is the paved road for workloads: a team gets restricted Pod Security, a read-only non-root pod, default-deny
> networking with DNS-only egress, and secrets from Secrets Manager — by default. The values schema is the guardrail:
> Helm won't even render a tag instead of a digest, a non-ECR registry, a single replica, root, an internet-open
> NetworkPolicy or a secret-looking env var. I validated it three ways — kubeconform against 1.36, Checkov, and a
> server-side dry run on the real cluster, where Pod Security also rejected a privileged root pod. Checkov flagged
> secrets as env vars; instead of suppressing it I switched to read-only files with Spring's configtree, so the value
> never appears in the process environment."
