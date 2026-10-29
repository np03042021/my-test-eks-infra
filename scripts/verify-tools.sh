#!/usr/bin/env bash
# Paved-road workstation check: every required tool is present and meets its minimum version.
set -uo pipefail
fail=0

check() {  # usage: check <label> <command...>
  local label=$1; shift
  local out rc
  out=$("$@" 2>&1); rc=$?
  if [[ $rc -eq 0 ]]; then printf "OK    %-12s %s\n" "$label" "$(head -1 <<<"$out")"
  else printf "FAIL  %-12s %s\n" "$label" "$(head -1 <<<"$out")"; fail=1; fi
}

check git          git --version
check code         code --version
check java         java -version
check javac        javac -version
check python3.12   python3.12 --version
check docker       docker version --format '{{.Server.Version}}'   # fails if Docker Desktop isn't running
check buildx       docker buildx version
check aws          aws --version
check terraform    terraform version
check kubectl      kubectl version --client
check helm         helm version --short
check pre-commit   pre-commit --version
check pip-compile  pip-compile --version
check pip-audit    pip-audit --version
check checkov      checkov --version
check trivy        trivy --version
check gitleaks     gitleaks version
check hadolint     hadolint --version
check kubeconform  kubeconform -v
check gh           gh --version
check jq           jq --version

# Minimum versions
jv=$(java -version 2>&1 | awk -F'"' '/version/{print $2}' | cut -d. -f1)
[[ "$jv" == "21" ]] && echo "OK    java major = 21" || { echo "FAIL  java major is '$jv', need 21"; fail=1; }

tfv=$(terraform version -json | jq -r .terraform_version)
python3.12 -c 'import sys; v=tuple(map(int,sys.argv[1].split(".")[:2])); sys.exit(v < (1,10))' "$tfv" \
  && echo "OK    terraform $tfv >= 1.10 (needed for S3 use_lockfile)" \
  || { echo "FAIL  terraform $tfv < 1.10"; fail=1; }

# Images deployed to EKS are amd64; an Apple Silicon laptop must be able to emulate it
[[ "$(docker run --rm --platform linux/amd64 busybox uname -m 2>/dev/null)" == "x86_64" ]] \
  && echo "OK    docker can run linux/amd64" || { echo "FAIL  amd64 emulation (enable Rosetta in Docker Desktop)"; fail=1; }

# Credentials must be short-lived SSO, never static keys
arn=$(aws sts get-caller-identity --query Arn --output text 2>&1)
[[ "$arn" == *AWSReservedSSO* ]] && echo "OK    AWS identity is SSO: $arn" \
  || { echo "FAIL  AWS identity not SSO (got: $arn) -> run: aws sso login --profile spr"; fail=1; }
if grep -qs aws_access_key_id ~/.aws/credentials*; then
  echo "FAIL  static AWS keys still on disk: $(grep -ls aws_access_key_id ~/.aws/credentials*)"; fail=1
else
  echo "OK    no static AWS keys on disk"
fi

gh auth status 2>&1 | grep -q workflow && echo "OK    gh token has 'workflow' scope" \
  || { echo "FAIL  gh missing 'workflow' scope -> gh auth refresh -s workflow"; fail=1; }

exit $fail
