# Phase 10: Interview prep — Secure Paved Road on EKS

Target role: Senior DevSecOps / Platform Security Engineer, GenAI delivery on AWS, regulated healthcare/life sciences.
Everything below is backed by code in the two public repos. Per-phase detail: `notes/phase-0` … `phase-6`.

Repos:
- https://github.com/np03042021/secure-paved-road-eks-infra — Terraform: the road (AWS, EKS, controllers, auditor)
- https://github.com/np03042021/secure-paved-road-eks — the workload: app, image, chart, CI gates, gated release

---

## 1. Three-minute walkthrough (say it, don't read it)

**0:00 – 0:30 · The problem and the idea**
> "In a regulated environment every team has to ship securely, and if each team solves security on its own, some get
> it wrong. A paved road makes the secure path the easiest path: a team gets a hardened pipeline, image and runtime by
> default. I built a small, working one on EKS so every claim I make here is something you can open and check."

**0:30 – 1:15 · The road (infra repo)**
> "Terraform builds it in two stacks. Bootstrap creates the encrypted, TLS-only state bucket, an ECR repo with
> immutable tags and scan-on-push, and GitHub OIDC — CI never holds AWS keys, and the push role trusts exactly one
> repo's production environment, pinned by GitHub's numeric repo IDs. The platform stack is EKS 1.36 in standard
> support: API endpoint limited to my /32, access entries instead of aws-auth, KMS-encrypted secrets, audit logs,
> IMDSv2 with hop limit 1 so pods can't steal the node role — I proved that with a pod whose metadata call timed out —
> and Pod Identity with one least-privilege role per controller. I hand-wrote the External Secrets role because the
> community module granted ListSecrets on everything. The app secret never touches Terraform state: ephemeral
> password plus a write-only attribute."

**1:15 – 2:15 · The workload (app repo)**
> "The app is small on purpose. Allow-list input validation, Actuator deny-by-default, config validated at startup.
> The image is multi-stage onto distroless, digest-pinned, non-root, no shell: 327 MB down to 85 MB, and nine fixable
> HIGH CVEs down to zero — six of those nine were in Maven's own jars, the build tool shipped to production. The Helm
> chart enforces Pod Security restricted, a read-only non-root pod, default-deny networking with DNS-only egress, and
> the secret is mounted as a file, not an env var. A values schema refuses to render a tag instead of a digest, a
> public registry, one replica, root, or an open network policy."

**2:15 – 3:00 · The pipeline and how it's governed**
> "Every PR runs seven required checks: gitleaks, tests with an 80% coverage gate, CodeQL, Trivy SCA, chart
> validation, Checkov, and an image gate that fails on fixable HIGH or CRITICAL. Release only runs after I approve the
> production environment: OIDC into AWS, build, scan the exact image, push, read the digest back from ECR and commit it
> — Argo CD pulls it, so CI never has cluster credentials. Every action is SHA-pinned and GitHub enforces that; scanner
> binaries are hash-pinned because trivy-action itself was hijacked in March 2026. And I verified everything I was
> handed — including AI output: several of my best stories are the tool or the generator being wrong."

---

## 2. JD → evidence

| JD requirement | Evidence (file / proof) |
|---|---|
| Hands-on CI/CD (Jenkins shared libs preferred) | `ci.yml` 7 required checks + `release.yml` gated by environment approval. **Reuse model:** GitHub Actions (see §7 on reusable workflows). Jenkins: discuss from experience; not built here |
| Multi-stage, digest-pinned, non-root images | `Dockerfile`: maven build stage on `$BUILDPLATFORM` → distroless java21-debian13 `nonroot`, both `tag@sha256`, `USER 65532:65532`; `scripts/compare-images.sh` |
| Python & Node supply chain: lockfiles, hash pinning, safe index resolution, scanning | Python: `infra/auditor/requirements-dev.txt` via `pip-compile --generate-hashes`, `pip install --require-hashes --only-binary :all:`, pip-audit in CI. Node: not in this project — answer from principles (§5 Q8) |
| Least-privilege IAM | ECR push role → 1 repo; ESO role → 1 secret, hand-written; auditor → exactly 5 read APIs; IMDS hop limit 1; Pod Identity per controller; release job `GITHUB_TOKEN` is read-only |
| Secrets management | Secrets Manager → External Secrets (Pod Identity, no static creds) → K8s Secret → **file mount + Spring configtree**; only the needed key synced; ephemeral + write-only in Terraform (never in state) |
| Hardened container & serverless workloads | PSS restricted, read-only root FS, caps dropped, seccomp, no SA token; auditor Lambda: least-privilege role, only its EventBridge rule can invoke it, Terraform-owned log group |
| Secret scanning with pre-commit gating | gitleaks pre-commit + CI full-history scan + GitHub push protection; CI gitleaks **caught** a fake key the newer local version allowed (version drift story) |
| SAST, SCA, IaC scanning as enforced gates + false-positive tuning | CodeQL security-extended; Trivy fs/image with `--ignore-unfixed` gate; Checkov on Terraform, Dockerfile, rendered chart, workflows; suppressions inline or in `.trivyignore.yaml`/`.checkov.yaml` with reason + owner + expiry; "fix first" examples (AZ pin, ARG→literal FROM, env→file secret) |
| TLS/PKI fundamentals | State bucket denies non-TLS; OIDC trust chain (AWS validates GitHub's issuer cert); Argo CD self-signed over port-forward. **Gap stated:** ALB is HTTP — next step ACM + 443 |
| Daily AI coding agents with review & verification | Built with Claude; every artifact verified — see the story bank (§4): fake Initializr version, stale checkov-action, wrong test assumption, duplicate YAML key, misleading image sizes |
| Nice to have: Helm, artifact registries | Chart with schema guardrails, kubeconform 1.36 + server-side dry run; ECR immutable + scan-on-push + lifecycle |
| Nice to have: Bedrock/RAG security | Not built — next step (§6) |

---

## 3. Numbers to have ready

| Fact | Value |
|---|---|
| Image pull size / on disk | 327 MB → **85 MB** / 993 MB → 306 MB |
| CVEs total / fixable HIGH+CRIT | 164 → 66 / **9 → 0**; remaining 4 HIGH = Debian `libuuid1`, no fix published |
| Base image choice | distroless debian12 had 10 fixable HIGH/CRIT (fails gate); debian13 had 0 |
| Checkov | infra Terraform 128 passed / 0 failed / 13 skipped (all with reasons); chart 96/0/0; Dockerfile 42/0/1; workflows 48/0 |
| Tests | auditor 16 pytest; app 38 JUnit 5, 84.6% line coverage (gate 80%) |
| Chart validation | kubeconform 10/10 (K8s 1.36); 7/7 guardrails reject; server dry-run accepted; privileged pod rejected by PSS |
| Required checks | 7 |
| Cost | ~$3.3–4.0/day without ALB, ~$4.0–4.8 with; $20/month budget alerts at 50/80/100% |
| Teardown | `down.sh` (ALB-safe order + leftover check); `--all` removes bootstrap too |

---

## 4. Story bank — "tell me about a time…" (all real, from this build)

| # | Story | Lesson |
|---|---|---|
| 1 | checkov-action's "latest release" ran **Checkov from 2022**; pinned a SHA that runs 3.3.30 | verify what a pin actually executes |
| 2 | gitleaks passed locally, failed in CI: the action downloaded an **older scanner** (8.24.3 vs 8.30.1) | pin the tool version, not just the action |
| 3 | Spring Initializr generated a parent version (`4.1.2.RELEASE`) that **doesn't exist** on Maven Central | generators and AI are suggestions — check the registry |
| 4 | My own test assumed `?name=` → 400; Spring applies the default → 200. Kept behaviour, fixed the test | tests encode real semantics, not assumptions |
| 5 | Maven Wrapper's checksum failed in Docker: no `unzip` → silent zip→tar.gz switch. Investigated, didn't delete the check | an integrity failure is an alarm, not an obstacle |
| 6 | Docker reported 326 vs 306 MB; containerd store only counts unpacked layers after a run. Real: 327→85 MB | verify evidence before presenting it |
| 7 | ARGs in `FROM` blinded Checkov (and Dependabot) → literal `FROM tag@digest` | fix the code, not the scanner config |
| 8 | Checkov CKV_K8S_35: secret as env var → switched to read-only file + Spring configtree | design fix over suppression |
| 9 | GitHub won't let the Actions app bypass a ruleset on a personal repo → deploy key scoped to the production environment + 2 loop guards | understand platform limits; keep the bypass narrow |
| 10 | First release: `AssumeRoleWithWebIdentity` denied. CloudTrail showed GitHub's **immutable ID-pinned subject**; tightened the trust policy to it | read the evidence (CloudTrail), fix stricter not looser |
| 11 | Maven Central rate-limited the runner during Trivy SCA → resolve deps first | CI must be a good citizen of shared infra |
| 12 | Auto mode refused to let the AI mint a deploy key or apply an IAM change — a human did | AI writes, humans hold credentials and approve prod |
| 13 | trivy-action hijacked (March 2026) → tools installed from binaries with **hashes pinned in the repo** | a release's own checksum file can be forged by whoever controls the release |

Pick 3 to lead with: **#10** (cloud IAM + forensics), **#1 or #2** (supply chain), **#3/#12** (AI verification & governance).

---

## 5. Ten likely follow-up questions

**Q1. Why OIDC instead of access keys, and how do you stop other repos or branches using the role?**
Short-lived STS credentials per job, nothing to leak or rotate. Trust policy: `aud = sts.amazonaws.com` and
`sub` **StringEquals** (never wildcards) the immutable subject
`repo:np03042021@94600928/secure-paved-road-eks@1436999333:environment:production`. Only the production environment
matches, it needs my approval, and it only deploys from main. Numeric IDs stop a recreated or renamed repo with the
same name from matching. The role can push to one ECR repo and has no EKS permissions.

**Q2. Why does CI not deploy to the cluster?**
Pull-based GitOps: Argo CD pulls from Git, so no CI system holds cluster credentials and the API endpoint isn't
opened to CI runners. Git is the audit log of what runs; self-heal reverts manual drift; prune removes what Git removes.
Argo is restricted by an AppProject to one repo and one namespace.

**Q3. Walk me through what stops a vulnerable image reaching production.**
Base images pinned by digest and bumped by Dependabot (7-day cooldown) → PR gates: Trivy SCA on the dependency tree,
CodeQL, Trivy image gate on the built image (fixable HIGH/CRIT fail) → release rebuilds and **re-scans the exact image**
it pushes → ECR scan-on-push → deploy **by digest only** (chart schema rejects tags). Unfixed CVEs are visible in the
Security tab but don't block — blocking on unfixable issues just teaches teams to bypass gates.

**Q4. How do you handle false positives without weakening the gate?**
Fix first (examples: AZ pin, literal FROM, secret as file). If a suppression is justified, it's scoped to one resource,
inline or in `.trivyignore.yaml`/`.checkov.yaml`, with reason, owner and **expiry** — Trivy re-reports after
`expired_at`. Never lower thresholds globally; suppressions go through PR review like code.

**Q5. How are secrets handled end to end?**
Generated by Terraform as an **ephemeral** value and written with a **write-only** attribute → never in state or plan.
Stored in Secrets Manager. ESO reads it with its own Pod Identity role that can read only that ARN; the
ClusterSecretStore only serves the app namespace; the ExternalSecret syncs only the key the app needs. The pod mounts
it read-only as a file (not env) and Spring's configtree reads it. No secret in Git, image, Helm values or CI.
Prod additions: CMK with a scoped key policy, rotation.

**Q6. What does IMDS hop limit 1 actually do, and how did you verify it?**
IMDSv2 responses have IP TTL = hop limit; a pod is one extra network hop from the node, so with limit 1 the
response never reaches it. Verified: a curl pod's token request to 169.254.169.254 timed out. Pods get scoped
credentials via Pod Identity instead of inheriting the node role.

**Q7. How do you know your NetworkPolicies are enforced, and what are their limits here?**
VPC CNI with `enableNetworkPolicy=true` (verified on the add-on config). Default-deny in and out, DNS-only egress,
8080 ingress from the VPC CIDR. Limit I'd state myself: pods share subnets with the ALB, so the CIDR also matches other
pods; production uses separate pod subnets (custom networking) or Security Groups for Pods.

**Q8. Python and Node supply chain — lockfiles, hashes, dependency confusion?**
Python here: `pip-compile --generate-hashes`, `--require-hashes`, wheels only (`--only-binary :all:`), pip-audit.
Dependency confusion: `--extra-index-url` lets pip pick the **highest version from any index**, so an attacker
publishes your internal package name publicly with a higher version. Safe alternative: a single `--index-url` pointing
at a private proxy (CodeArtifact/Artifactory) that serves internal names and proxies PyPI, plus hash pinning. Node:
committed `package-lock.json`, `npm ci` (fails on lock mismatch), `--ignore-scripts` where possible, scoped
packages bound to a private registry in `.npmrc`, `npm audit`/Trivy, and a cooldown before new versions.

**Q9. How would you scale this paved road to 50 teams?**
Reusable GitHub Actions workflows (`workflow_call`) in a central repo, versioned by tag and consumed by SHA; required
via org rulesets (required workflows / required checks), so teams can't skip gates. Chart as a library chart with
the values schema as the contract. Policy-as-code at admission (Kyverno/Gatekeeper) as the backstop for anything
that bypasses CI. Paved road = default, not a cage: teams can deviate with an exception that has an owner and expiry.

**Q10. How would you secure a GenAI / Bedrock RAG workload on this platform?**
Bedrock via VPC endpoint (PrivateLink), IAM scoped to specific model ARNs, no wildcard `bedrock:*`. Guardrails for
PII/PHI redaction, denied topics and prompt-attack filters on input **and** output. RAG: index only data the caller
may see (document-level access control enforced at retrieval, not in the prompt), KMS-encrypted vector store,
treat retrieved text as untrusted (indirect prompt injection), no tool execution without allow-lists. Logging of
prompts/responses with PHI controls, model invocation logging to a protected bucket. Same pipeline gates for the
app; add evals for jailbreak and leakage as a release gate.

Extra questions worth a rehearsal: "Why distroless and not Alpine?", "Why Spot?", "What breaks if the ALB controller is
down?", "How would you sign images?", "How do you rotate the deploy key?", "Why not `latest` for EKS add-ons?".

---

## 6. Trade-offs to state before they ask (all labelled DEMO ONLY in code)

| Shortcut | Why | Production |
|---|---|---|
| Public subnets, no NAT | NAT ≈ $1.30/day | private node subnets + NAT or VPC endpoints (ECR, STS, S3, Secrets Manager) |
| Spot nodes, single-replica controllers | cost | On-Demand/mixed, ≥2 replicas + PDBs |
| HTTP, no ACM | no domain for the demo | ACM cert, 443 only, 80→443 redirect, WAF |
| ALB open to 0.0.0.0/0 | public smoke test | restricted CIDRs or CloudFront + WAF |
| No image signing / SBOM yet | scope | cosign keyless signing + SBOM attestation, verified at admission |
| Public EKS endpoint (my /32) | laptop access | private endpoint via VPN/SSM |
| AWS-managed KMS keys, short log retention | cost | CMKs with scoped key policies, ≥1 year logs to a SIEM |
| Argo CD local admin, no SSO | setup time | OIDC SSO, local admin disabled |
| NetworkPolicy VPC CIDR matches other pods | shared subnets | pod subnets / SG for pods |
| Deploy-key bypass for digest commits | personal-repo ruleset limit | GitHub App owned by the org as the bypass actor |
| ASCII-only name validation | simplicity | Unicode letters after NFC normalisation |

## 7. Next steps (what I'd build next)

1. **cosign keyless signing + SBOM** (Syft/Trivy CycloneDX) attested to the image digest in release.yml; verify
   signature and provenance at admission.
2. **Kyverno** policies: require signed images from our ECR, digest-only, PSS-equivalent rules as a backstop for
   anything that didn't come through the pipeline.
3. **Reusable workflows**: move the 7 gates into a central `workflow_call` workflow consumed by SHA; org-level
   required checks. *(Today the gates live in this repo's `ci.yml`; it's not yet a shared workflow — don't claim it is.)*
4. **Bedrock Guardrails** + VPC endpoints for a RAG feature (see Q10).
5. HTTPS with ACM, private EKS endpoint, NAT/VPC endpoints, CMKs.
6. Code-scanning merge protection (block on new high-severity CodeQL alerts).

## 8. Don't claim (keep it honest — the repos are public)

- **SonarQube** — not in the pipeline. Say: "SonarQube was my quality gate before; here CodeQL is the SAST gate; adding
  Sonar is one job plus a required check" (details in `phase-6-pipelines.md`).
- **Fortify** — not integrated (licence). Describe how you used it before and where it plugs in (SARIF → code scanning).
- **Jenkins shared library** — not built (skipped by choice). Talk from experience.
- **Reusable/shared GitHub workflow** — not built yet; it's next step #3.
- **Break-and-fix demos (Phase 8)** — skipped. Some evidence exists anyway: privileged pod rejected by PSS (Phase 5
  dry run), IMDS blocked (Phase 2), CI gitleaks catch (Phase 1), Trivy gate counts (Phase 4).

## 9. Live-exercise playbooks

**Harden a Dockerfile** — checklist in order: multi-stage; pin base by `tag@sha256`; minimal runtime (distroless/
chainguard/alpine with reasons); `.dockerignore` allow-list; no secrets in `ARG`/`ENV`/layers (use BuildKit
`--mount=type=secret`); numeric non-root `USER`; exec-form `ENTRYPOINT`; no package manager/shell in runtime; copy
only artifacts; `--platform` for the target arch; then prove it: `hadolint`, `trivy image --severity HIGH,CRITICAL
--ignore-unfixed`, `docker run --read-only --cap-drop ALL --user 65532`.

**Fix a dependency-resolution problem** — read the full error first (which package, which constraint); `pip install
--dry-run`/`pipdeptree`/`mvn dependency:tree -Dverbose`; adjust the *direct* requirement in `.in` (not the lockfile);
`pip-compile --generate-hashes`; reinstall with `--require-hashes`; pip-audit. Never `--extra-index-url` to "make it
work"; never hand-edit hashes.

**Add a scanning gate** — pin the action by SHA (or install a hash-pinned binary); least-privilege `permissions`;
SARIF upload with `if: success() || failure()` (report even when failing); separate report step from gate step;
threshold = fixable HIGH/CRITICAL; suppression file with reason/owner/expiry; add the job to required checks.

## 10. Demo checklist (screen-share order, ~5 min)

1. GitHub app repo → **Actions**: a green `ci` run (7 jobs) and the `release` run with the approval step.
2. **Settings → Rules**: `main-protection` (PR + 7 checks, deploy-key-only bypass); **Environments → production**.
3. **Security tab**: CodeQL/Trivy/Checkov results; Dependabot.
4. `README.md` before/after image table; `charts/app/values.schema.json`.
5. Infra repo: `bootstrap/main.tf` OIDC trust (immutable sub), `infra/pod_identity.tf` hand-written ESO role,
   `infra/secrets.tf` ephemeral + write-only.
6. If the cluster is up: Argo CD UI (port-forward) → `spr-app` Synced/Healthy; `curl http://<alb>/api/hello?name=…`.
7. Close with the trade-offs table and next steps.

Screenshots to take while the cluster is up: Argo CD app tree, `kubectl get pods -n spr-app`, the ALB smoke test,
the release run's approval and summary (image digest), compare-images table, validate-chart output.
