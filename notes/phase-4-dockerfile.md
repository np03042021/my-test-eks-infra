# Phase 4: Hardened Dockerfile with before/after evidence (repo: secure-paved-road-eks)

**Built:** 2026-10-29. **AWS cost:** $0 (local Docker). Staged in the app repo together with Phase 3, not yet committed.

## Files

```
Dockerfile                          multi-stage: maven:3.10.0 (build, native platform) -> distroless java21-debian13:nonroot
.dockerignore                       allow-list: only pom.xml and src/ enter the build context
docker/Dockerfile.before            deliberately naive baseline (root, full JDK+Maven+Ubuntu, mutable tag, COPY . .)
docker/Dockerfile.before.dockerignore   near-empty, so the baseline shows what COPY . . picks up (.git!)
scripts/compare-images.sh           builds both for linux/amd64 and prints the evidence table
.mvn/wrapper/maven-wrapper.properties   comment explaining the unzip requirement (see story 1)
README.md                           Container image section with the table
```

## Base images (pinned as tag@sha256 of the multi-arch index, verified 2026-10-29)

| Stage | Image | Why |
|---|---|---|
| build | `maven:3.10.0-eclipse-temurin-21-noble@sha256:be0d4ea4…` | same Maven version mvnw pins; no apt installs; `--platform=$BUILDPLATFORM` so the Maven build runs natively on arm64 (no emulation) |
| runtime | `gcr.io/distroless/java21-debian13:nonroot@sha256:a2aeb5a7…` | JRE + CA certs only; no shell, no package manager; UID 65532 |

How to check/update: `docker buildx imagetools inspect <image>:<tag> --format '{{.Manifest.Digest}}'` (Dependabot does this from Phase 6).

## Dockerfile, line by line

- **Literal `FROM tag@digest` lines, not ARGs** — Checkov (`CKV_DOCKER_7`) and Dependabot can only read/bump literal references.
- **Build stage on `$BUILDPLATFORM`** — the jar is platform-independent, so only the runtime stage targets linux/amd64. Build took ~25 s instead of minutes under emulation.
- **`--mount=type=cache,target=/root/.m2`** — Maven cache survives between builds but is never in an image layer.
- **`-DskipTests`** — tests run in CI's `mvnw verify` job *before* the image build; the image build only packages.
- **`java -Djarmode=tools … extract --layers`** — Spring Boot 4 layer split: `dependencies` 23 MB (changes rarely) vs `application` 12 KB, so a code change only rebuilds/pushes 12 KB.
- **Files owned by root, read-only to the app user** — no `--chown`; a compromised process can't rewrite its own code.
- **`USER 65532:65532` numeric** — Kubernetes `runAsNonRoot` can only verify a numeric UID; the distroless `nonroot` name isn't enough.
- **No secrets in any layer** — `GREETING_PREFIX` arrives at runtime from the Kubernetes Secret.
- **`-XX:MaxRAMPercentage=75 -XX:+ExitOnOutOfMemoryError`** — heap sized from the container limit; OOM → clean exit → Kubernetes restarts it.
- **No `HEALTHCHECK`** — distroless has no shell/curl; Kubernetes probes on `/actuator/health/*` do this. Checkov `CKV_DOCKER_2` skipped inline with that reason. Trivy's equivalent (`DS-0026`) is a whole-file finding that inline comments can't suppress → goes in `.trivyignore.yaml` with owner + expiry in Phase 6.
- **`.dockerignore` allow-list** (`*` then `!pom.xml !src/`) — new files are excluded by default instead of leaking by default.

## Evidence (linux/amd64, `./scripts/compare-images.sh`, 2026-10-29)

| | BEFORE | AFTER |
|---|---|---|
| Pull size (compressed, what nodes download) | 327 MB | **85 MB** (3.8× smaller) |
| Unpacked size | 993 MB | **306 MB** (3.2× smaller) |
| Runs as | root (unset) | **65532:65532** |
| Shell available | yes | **no** |
| `.git` history in image | **yes** | no |
| Base pinned by digest | no | yes |
| hadolint | 0 | 0 |
| Trivy Dockerfile misconfigs | DS-0002 (root), DS-0026 | DS-0026 (by design) |
| CVEs CRITICAL / HIGH / MEDIUM / LOW | 0 / 9 / 98 / 57 | 0 / 4 / 39 / 23 |
| CVEs total | 164 | **66** |
| HIGH+CRITICAL with a fix (the CI gate) | **9** | **0** |

Where BEFORE's 9 fixable HIGH came from: **6 in Maven's own jars** (plexus-utils ×4, commons-io 2.11.0, guava) and 3 in Ubuntu (openssl/libssl3t64, libbrotli1). The build tool's vulnerabilities were shipped to production — multi-stage removes them by construction.

AFTER's 4 HIGH: all `libuuid1` (Debian 13 util-linux), status "affected", **no fix published**. All 66 AFTER CVEs are exactly the distroless base's 66 — the app and its Java dependencies add zero.

Base choice evidence (same day): distroless **debian12** = 2 CRITICAL, 15 HIGH, **10 fixable** (would fail the gate); **debian13** = 0 CRITICAL, 4 HIGH, **0 fixable**.

Scanner results on the hardened Dockerfile: Checkov 42 passed / 0 failed / 1 skipped (with reason); hadolint clean.

Runtime test, locked down like Kubernetes will run it:

```bash
docker run --rm -p 8080:8080 --read-only --tmpfs /tmp:rw,noexec,nosuid,size=64m \
  --cap-drop ALL --security-opt no-new-privileges --memory 512m \
  -e GREETING_PREFIX="Hello from the secure paved road" spr-app:after
```

→ valid name 200, XSS 400, readiness 200, `/actuator/env` 404; `docker exec … sh` fails: *"sh": executable file not found*; image arch amd64.

## Problems hit (interview stories)

1. **The Maven Wrapper's checksum check failed inside Docker — and it was right to.** The eclipse-temurin image has no `unzip`, so `mvnw` *silently* swaps the pinned `.zip` URL for the `.tar.gz`, whose SHA-256 differs → "your Maven distribution might be compromised". Investigated before changing anything (verbose run showed the tar.gz download). Pinning the tar.gz isn't allowed (mvnw only accepts `*-bin.zip`); installing unzip via apt adds an unpinned dependency. Fix: build stage uses the official `maven:3.10.0` image pinned by digest — same Maven version, no download, reproducible. Lesson: a failing integrity check is a signal to investigate, never to delete the checksum.
2. **Docker reported misleading image sizes.** With Docker 29's containerd image store, `docker image inspect .Size` is only the compressed size until the image has been *run* once — the first comparison said 326 MB vs 306 MB. Measured properly: 327→85 MB compressed, 993→306 MB unpacked. Lesson: verify your evidence before you present it.
3. **Using ARGs for base images blinded Checkov** (`CKV_DOCKER_7` failed: it couldn't see the tag) and would have blinded Dependabot. Fixed the code (literal `FROM`) instead of skipping the check.
4. **Chose the base image with data**, not habit: debian12 would have failed the CVE gate with 10 fixable HIGH/CRITICAL; debian13 has 0.

## Common errors

| Symptom | Fix |
|---|---|
| Pod CrashLoopBackOff, `exec format error` | image built for arm64; build with `--platform linux/amd64` (CI on ubuntu-latest is amd64) |
| `Failed to validate Maven distribution SHA-256` in a container | the image lacks `unzip`; use the pinned maven image (don't remove the checksum) |
| Pod rejected: `container has runAsNonRoot and image has non-numeric user` | keep `USER 65532:65532` numeric |
| Tomcat fails with read-only root FS | mount a writable `emptyDir` at `/tmp` (Helm chart, Phase 5) |
| `docker exec -it <c> sh` fails | expected — distroless has no shell; use `kubectl debug` with an ephemeral debug container |
| `ERROR: failed to solve: ... not found` for `src/` | `.dockerignore` allow-list missing the path |

## Say this in the interview

> "I measured the hardening instead of asserting it. The naive image was 327 MB to pull, ran as root, had a shell and
> even shipped the .git history; it carried 9 fixable HIGH CVEs, and six of those were in Maven's own jars — the build
> tool's vulnerabilities shipped to production. The multi-stage distroless image is 85 MB, runs as a numeric non-root
> UID with no shell, and has zero fixable HIGH or CRITICAL CVEs; the four remaining HIGH are in a Debian library with no
> fix published, which is exactly what --ignore-unfixed in the CI gate is for. I also chose Debian 13 over 12 on data:
> 12 would have failed the gate. And when the Maven Wrapper's checksum check failed in the container, I treated it as a
> real alarm, found the cause — a silent zip-to-tar.gz switch — and fixed the build without weakening the check."
