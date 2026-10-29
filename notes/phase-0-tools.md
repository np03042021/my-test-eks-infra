# Phase 0: Tools, AWS login and GitHub repos

**Done:** 2026-10-28. **AWS cost:** $0.

## What was set up

- Mac: Apple Silicon (arm64), macOS 14.6.1. Homebrew builds from source on macOS 14 (Tier 3), so installs were slow.
- Homebrew: python@3.12, pipx, git, gh, jq, trivy, gitleaks, hadolint, kubeconform; Temurin JDK 21; Docker Desktop
  (Rosetta for amd64 emulation on). Terraform 1.15.4, kubectl 1.36.1, Helm 4.2.2, AWS CLI 2.34 were already present.
- pipx tools pinned to Python 3.12: pre-commit, pip-tools (pip-compile), pip-audit, checkov → `~/.local/bin`.
  - Why 3.12: `pip-compile --generate-hashes` resolves for the Python it runs on; the Lambda runtime is python3.12.
  - Why pipx: each tool in its own venv, so Checkov's big dependency tree can't break pre-commit.
- `~/.zshrc`: `JAVA_HOME` → JDK 21, Homebrew first on PATH, `AWS_PROFILE=spr`.
- VS Code: `code` CLI on PATH; extensions for Terraform, YAML, Kubernetes, Java, Spring Boot, Python, GitHub Actions,
  Trivy, Checkov, Container Tools.
- `scripts/verify-tools.sh` checks every tool and minimum version, that Docker can run linux/amd64, and that AWS is SSO.

## AWS credentials: static key → IAM Identity Center

- Found a long-term static access key in `~/.aws/credentials` (already rejected by AWS as invalid). Replaced with SSO; the backed-up key file was deleted.
- Root user: MFA on, no access keys, not used again.
- Identity Center enabled "with AWS Organizations" (an account instance can't grant AWS-account access).
  User with MFA; permission set AdministratorAccess with 8h session (DEMO ONLY — prod: scoped permission sets,
  separate deploy role and break-glass admin). Profile `spr`, login with `aws sso login`.

## Gotchas seen

- A terminal opened before `~/.zshrc` existed didn't see the pipx tools or `AWS_PROFILE` → open a new terminal.
- Architecture trap for later phases: the Mac builds arm64, the t3/t3a nodes are amd64 → `exec format error` /
  CrashLoopBackOff if an arm64 image is pushed. CI (ubuntu-latest, amd64) builds deployable images; locally use
  `docker build --platform linux/amd64`.

## Say this in the interview

> "There are no long-lived AWS keys anywhere in this project. My laptop uses IAM Identity Center with MFA and 8-hour
> sessions, and CI uses GitHub OIDC. The first thing I did was find and remove a static key from my own machine."
