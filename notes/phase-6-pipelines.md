# Phase 6: GitHub settings, CI gates, gated release, first PR and deploy (repo: secure-paved-road-eks)

**Status (2026-10-29):** settings + ruleset + workflows done; PR #1 all 7 checks green and mergeable.
**Waiting on the user:** create the release deploy key (auto mode blocked Claude from creating a write credential),
then merge PR #1, approve the `production` deployment, Argo CD sync, ALB smoke test.

## GitHub settings applied (app repo)

| Setting | Value | How |
|---|---|---|
| Secret scanning + push protection | enabled (public-repo default, verified) | `gh api repos/…` |
| Non-provider secret patterns | **stayed disabled** — needs a paid GitHub Secret Protection licence | attempted |
| Dependabot alerts + security updates | enabled | `PUT /vulnerability-alerts`, `/automated-security-fixes` |
| Actions: require full-length SHA pins | **enabled** — a tag-pinned action now fails to run | `PUT /actions/permissions sha_pinning_required=true` |
| Default workflow token | read-only, can't approve PRs | already set |
| Delete branch on merge | enabled | |
| `production` environment | required reviewer np03042021; deployable only from `main` | `PUT /environments/production` + branch policy |
| Repo variables | `AWS_REGION`, `ECR_REPOSITORY`, `AWS_ROLE_ARN` (from up.sh output; not secrets) | `gh variable set` |
| Ruleset `main-protection` (id 26116322) | PR required (0 approvals, solo dev; squash only; threads resolved), 7 required checks (strict, GitHub Actions app only), no force-push, no deletion. **Bypass: deploy keys only** | `POST /rulesets` |

## Ruleset bypass story (interview)

First attempt: bypass for the GitHub Actions app (so release.yml's GITHUB_TOKEN could push the digest commit).
GitHub rejected it: *"Actor GitHub Actions integration must be part of the ruleset source or owner organization"* —
not possible on personal-account repos. Chosen design: one **write deploy key** whose private half exists only as a
**`production` environment secret** → usable only by the release job, only on main, only after human approval.
Ruleset bypass = DeployKey.

Consequence: deploy-key pushes (unlike GITHUB_TOKEN pushes) DO trigger workflows → loop risk
(digest commit → ci → release → digest commit …). Two guards:
1. `ci.yml` `push.paths-ignore: charts/app/values.yaml` (PRs still run everything).
2. `release.yml` skips commits whose message starts with `chore(release):`.

Bonus: the release job's `GITHUB_TOKEN` is now `contents: read` (push uses the deploy key).

## Pipelines

**ci.yml** (PR + push to main), `permissions: {}` at top, every job opts in:

| Job (= required check) | What |
|---|---|
| gitleaks | full history, gitleaks 8.30.1 pinned via `GITLEAKS_VERSION` |
| maven-verify | `./mvnw verify` (38 tests, JaCoCo 80% gate) + coverage in the job summary |
| codeql | `java-kotlin`, `build-mode: manual`, `security-extended` queries |
| trivy-fs | resolve deps with Maven first, then SARIF + gate (HIGH/CRITICAL with fix) |
| chart | helm + kubeconform (hash-pinned), `validate-chart.sh` (lint --strict, kubeconform 1.36, guardrails) |
| checkov | render chart, checkov-action v12.3135.0 with `.checkov.yaml` (dockerfile, kubernetes, github_actions), SARIF |
| image | hadolint, `trivy config` (with ignore file), amd64 build, Trivy image SARIF + gate |

**release.yml** (`workflow_run` of ci, completed, main, success, push event, not a `chore(release):` commit),
`environment: production`, `permissions: contents: read, id-token: write`, concurrency `release` (no cancel):
checkout the exact ci-tested SHA with the deploy key → install Trivy (hash-pinned) → OIDC `configure-aws-credentials`
v6.3.0 → ECR login with `get-login-password` (no extra action) → if the SHA tag already exists (IMMUTABLE ECR) reuse
its digest → else build amd64, Trivy gate, push → read digest **from ECR** → validate `^sha256:[a-f0-9]{64}$` →
if `origin/main` still == that SHA, `sed` the digest into values.yaml, commit as github-actions[bot], push to main.
If main moved on, skip (a newer release follows) so an older image is never deployed over newer code.

## Supply-chain hardening of the pipeline itself

- Actions pinned to full SHAs (now enforced by GitHub). Reused verified pins: checkout v7.0.1 `3d3c42e5…`,
  codeql-action v4.39.1 `9b325408…`, checkov-action v12.3135.0 `c3e106d5…`, gitleaks-action v3.0.0 `e0c47f4f…`.
  New: setup-java v6.1.0 `b843ebf9…`, configure-aws-credentials v6.3.0 `e1253824…`.
- "Latest release" traps again: checkov-action's latest = stale v12.1347.0; codeql-action's latest = a CodeQL
  *bundle* tag, not the action version.
- **No trivy-action.** March 2026: attackers force-pushed 75–76 of trivy-action's version tags and published
  malicious Trivy binaries (secrets stolen before the real scan ran, so pipelines looked normal).
  → `scripts/ci/install-tools.sh` installs Trivy 0.76.1, Helm 4.2.2, kubeconform 0.8.0, hadolint 2.15.1 from release
  binaries checked against **SHA-256 hashes hardcoded in the repo** (cross-checked with published checksums /
  GitHub asset digest). A release's own checksum file can be forged by whoever controls the release; a hash in a
  reviewed PR can't.
- Dependabot (maven, docker, github-actions) with **`cooldown: default-days: 7`** — most hijacked releases are
  pulled within days.
- `.trivyignore.yaml`: DS-0026 (no HEALTHCHECK) with statement, owner, `expired_at: 2027-04-30`. Unfixed OS CVEs are
  deliberately NOT ignored (they show in the Security tab; gates use `--ignore-unfixed`).
- `.checkov.yaml`: skip-path `docker/` (intentionally insecure baseline) and raw `charts/app/templates` (rendered
  output is scanned). Dockerfile inline skip now has owner + review date.
- `.pre-commit-config.yaml`: gitleaks, detect-private-key, check-yaml (Helm templates excluded),
  check-added-large-files, local hadolint.

## Problems hit (interview stories)

1. **GitHub Actions can't be a ruleset bypass on a personal repo** → deploy key scoped to the production environment
   + two loop guards (above).
2. **pre-commit's check-yaml caught a bug my own check missed**: a scripted edit left a duplicate `on:` key in
   release.yml; Python's `yaml.safe_load` silently accepts duplicate keys, ruamel (check-yaml) rejects them.
3. **First CI run: trivy-fs failed — Maven Central rate-limited the runner IP**, because Trivy resolves every
   transitive POM over the network. Fix (Trivy's own advice): `setup-java` cache + `mvnw dependency:resolve` first.
4. **Auto mode refused to create the deploy key** (a new write credential) — the user creates it; good separation:
   the AI writes the pipeline, a human mints the credential.

5. **First release failed: `Not authorized to perform sts:AssumeRoleWithWebIdentity`.** CloudTrail showed the subject
   GitHub actually sent: `repo:np03042021@94600928/secure-paved-road-eks@1436999333:environment:production`. The
   repo uses GitHub's **immutable subject claims** (owner and repo pinned by numeric ID); the trust policy expected
   the old name-only `repo:np03042021/secure-paved-road-eks:environment:production`. Fix: trust the ID-pinned
   subject (stricter, not looser — no wildcards). A deleted-and-recreated or renamed-and-squatted repo with the same
   name gets a new ID, so it can't assume the role. Bootstrap vars `github_owner_id`, `app_repo_id`, `infra_repo_id`;
   commit 78265c8 in the infra repo; `terraform plan` showed exactly 1 change (the role's trust policy).
   How to diagnose next time: `gh api repos/<o>/<r>/actions/oidc/customization/sub` and CloudTrail
   `AssumeRoleWithWebIdentity` events (the `userIdentity.userName` is the subject that was rejected).

## SAST and code quality: what's in the pipeline, and SonarQube / Fortify

**What actually runs:** SAST = **GitHub CodeQL** (`codeql` job, `security-extended` suite, results in the Security
tab, required check). SCA = Trivy fs. IaC/K8s/Dockerfile = Checkov + hadolint + Trivy config. Image = Trivy.
Test quality gate = JaCoCo 80% line coverage in `maven-verify`.

**SonarQube is NOT in this pipeline** (decided 2026-10-29: keep the demo lean; CodeQL covers SAST). Don't claim it
is — the repo is public and an interviewer can check. Talking point instead, which plays to real experience:

> "In my previous pipelines SonarQube was the code-quality and security-hotspot gate, and Fortify was the deep SAST
> release gate. Here I used CodeQL because it's free for public repos and lands in the same Security tab, but the
> paved road is tool-agnostic: adding SonarQube is one job — `SonarSource/sonarqube-scan-action` pinned by SHA after
> `mvnw verify` so it picks up the JaCoCo XML, `SONAR_TOKEN` as a secret, `sonar.qualitygate.wait=true` so the job
> fails when the quality gate fails, and that job added to the ruleset's required checks. Fortify would plug in the
> same way via OpenText's `fortify/github-action` (FoD or ScanCentral SAST), exporting SARIF into code scanning, with
> the severity threshold enforced as a gate — I'd show the licence-gated stage in the Jenkins shared library."

How it would be wired (for a whiteboard question):
1. Job `sonar` after `maven-verify` (or in it): `./mvnw verify` → `target/site/jacoco/jacoco.xml` →
   scan with `-Dsonar.coverage.jacoco.xmlReportPaths=target/site/jacoco/jacoco.xml`.
2. Quality gate: new-code coverage ≥ 80%, 0 new vulnerabilities, security hotspots reviewed, no new blocker bugs.
3. Gate enforcement: wait for the gate result in the job → job fails → required check blocks the merge.
4. False positives: mark in the Sonar UI as "won't fix / false positive" with a comment (audited), never by
   lowering the gate.
5. Fortify: licence + FoD tenant/ScanCentral controller needed — not usable here (no client/employer licences on a
   personal public repo).

## Verification so far

- Local: Checkov k8s 96/0, Dockerfile 42/0 (1 skip), workflows 48/0; Trivy config/fs/image gates pass; pre-commit 5/5.
- PR #1, second run: gitleaks, maven-verify, codeql, trivy-fs, chart, checkov, image all **pass**;
  merge state CLEAN / MERGEABLE.

## Remaining steps (fill in after deploy)

1. User creates deploy key (commands in chat / below).
2. Squash-merge PR #1 → ci on main → release waits for approval.
3. User approves `production` → image pushed, digest committed.
4. Argo CD syncs spr-app → ALB → smoke test.

```bash
# Deploy key (run by the user, from any directory)
R=np03042021/secure-paved-road-eks
K="$(mktemp -d)/release_deploy_key"
ssh-keygen -q -t ed25519 -N "" -C "release.yml digest commits" -f "$K"
gh repo deploy-key add "$K.pub" --repo "$R" --allow-write --title "release-digest-commit (production env only)"
gh secret set RELEASE_DEPLOY_KEY --env production --repo "$R" < "$K"
rm -f "$K" "$K.pub"
```
