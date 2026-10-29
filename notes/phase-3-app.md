# Phase 3: Spring Boot app + JUnit tests (repo: secure-paved-road-eks)

**Built:** 2026-10-29. **AWS cost:** $0 (all local). Staged in the app repo, not yet committed.

## Versions (verified against Maven Central, not guessed)

| What | Version | How it was checked |
|---|---|---|
| Spring Boot (parent BOM) | **4.1.2** | Maven Central metadata; Initializr default |
| Spring Framework / spring-test | 7.0.10 | pulled in by the Boot BOM |
| Maven (via wrapper) | 3.10.0 | sha512 matched on repo.maven.apache.org **and** downloads.apache.org |
| Maven Wrapper | 3.3.4, `only-script` | scripts byte-compared with the official `maven-wrapper-distribution` zip (sha1 verified) |
| JaCoCo plugin | 0.8.16 | Maven Central metadata (not managed by the Boot BOM) |
| JDK | Temurin 21.0.13 | local |

## Files

```
pom.xml                          Boot 4.1.2 parent; webmvc, validation, actuator (+ their -test starters); JaCoCo with 80% line gate
mvnw, mvnw.cmd                   official Maven Wrapper 3.3.4 scripts (no wrapper jar binary in the repo)
.mvn/wrapper/maven-wrapper.properties   Maven 3.10.0 URL + distributionSha256Sum
.gitattributes                   LF for mvnw, CRLF for .cmd
.gitignore                       target/, IDE, .env*, *.sarif, CLAUDE.md, notes/
README.md                        endpoints, security choices, build commands
src/main/java/io/github/np03042021/spr/
  SecurePavedRoadApplication.java    @SpringBootApplication + @ConfigurationPropertiesScan
  config/GreetingProperties.java      record bound to app.greeting.prefix; @NotBlank @Size(max=100); @Validated
  hello/HelloController.java          GET /api/hello; @Size(1..40) + @Pattern allow-list on name; JSON response record
  web/ApiExceptionHandler.java        HandlerMethodValidationException -> generic RFC 9457 ProblemDetail 400
src/main/resources/application.properties   GREETING_PREFIX mapping, error hiding, graceful shutdown, Actuator lockdown
src/test/java/io/github/np03042021/spr/
  hello/HelloApiTest.java             20 tests: defaults, prefix, allow-listed names, 11 attack inputs, max length, no leaks
  ActuatorExposureTest.java           13 tests: health status-only, liveness/readiness, 10 sensitive endpoints = 404
  config/GreetingPropertiesTest.java   4 tests: valid binds; blank / missing / too-long prefix fail startup
```

## Security design, line by line

- **Allow-list, not deny-list.** `^[A-Za-z]+(?:[ '-][A-Za-z]+)*$`, 1–40 chars. Separators only *between* letters, so no leading/trailing/double separators. Rejects XSS markup, SQL shapes, CR/LF (log injection), `${jndi:...}` (Log4Shell-style), `../`, digits, non-ASCII.
  - DEMO ONLY: ASCII-only rejects "José"; prod: `\p{L}` after NFC normalisation.
- **Built-in method validation.** Spring MVC 6.1+ validates constrained `@RequestParam`s automatically (no `@Validated` on the controller) and throws `HandlerMethodValidationException`.
- **Errors don't echo input.** Generic `detail`, `application/problem+json`; tests assert the rejected value never appears in the body (no reflected XSS, no oracle).
- **Response is JSON, input isn't logged.** No HTML rendering, no log-forging surface.
- **Fail-fast config.** Missing/blank/oversized `GREETING_PREFIX` stops startup — a broken secret sync is caught by the readiness probe, not by users.
- **Actuator deny-by-default.** `management.endpoints.access.default=none` *disables* every endpoint; `management.endpoint.health.access=read-only` re-enables only health; exposure = health only; JMX exposure off; `show-details`/`show-components=never`. Liveness/readiness groups enabled explicitly (Boot only auto-enables them when it detects Kubernetes).
- **No internals in errors.** `server.error.include-message/stacktrace/binding-errors=never`, `include-exception=false`.
- **Graceful shutdown.** Finishes in-flight requests on SIGTERM (rolling updates, Spot interruption notices).
- **No auth on /api/hello** — DEMO ONLY trade-off to state; prod: Spring Security OAuth2 resource server (JWT from Cognito/Identity Center), method-level authZ.

## Verification results

| Check | Result |
|---|---|
| `./mvnw verify` | BUILD SUCCESS, **37 tests, 0 failures** |
| JaCoCo | **84.6% line** (11/13), 89.4% instruction; gate 80% met; only `main()` uncovered |
| Jar smoke test (`GREETING_PREFIX` set) | valid name 200; default 200; XSS 400; CRLF 400; readiness 200; `/actuator/env` 404; `/actuator/heapdump` 404; unknown path 404 without stack trace |
| Graceful shutdown | "Commencing graceful shutdown … complete" on SIGTERM |
| gitleaks on staged files | no leaks |
| Jar size | 23 MB (fat jar; Phase 4 compares image sizes) |

## Problems hit (interview stories)

1. **Spring Initializr generated a parent version that doesn't exist.** It wrote `4.1.2.RELEASE`; Maven Central only has `4.1.2` (the `.RELEASE` suffix was dropped years ago; the URL returned 404). Caught by checking the artifact URL before the first build. Lesson: generators and AI tools are both "suggestions" — verify coordinates against the registry.
2. **A test I wrote was wrong about Spring, and the test run proved it.** I expected `?name=` (empty) to be a 400, but `@RequestParam(defaultValue=...)` treats empty the same as missing, so it returns the safe default. Kept the behaviour (default is a fixed, valid value) and changed the test to document it. Lesson: tests verify the framework's real semantics, not my assumptions.
3. **Spring Boot 4 moved things.** The `web` starter is now `webmvc`; test starters are per-module (`*-test`); `@WebMvcTest`/`@AutoConfigureMockMvc` moved to `org.springframework.boot.webmvc.test.autoconfigure`; `ValidationAutoConfiguration` to `org.springframework.boot.validation.autoconfigure`. Found by listing the actual jar contents instead of guessing imports.
4. **Wrapper supply chain.** The wrapper scripts were compared byte-for-byte with Apache's official release (only `mvnw.cmd` line endings differed), and the Maven download is pinned by SHA-256 — `./mvnw` refuses a tampered Maven.

## Commands

```bash
cd ~/code/secure-paved-road-eks
export JAVA_HOME="$(/usr/libexec/java_home -v 21)"
./mvnw verify
open target/site/jacoco/index.html
GREETING_PREFIX="Hello from the secure paved road" java -jar target/secure-paved-road-app-0.1.0-SNAPSHOT.jar
curl 'localhost:8080/api/hello?name=Alice'
curl -i 'localhost:8080/api/hello?name=%3Cscript%3E'      # 400 problem+json, input not echoed
curl -i localhost:8080/actuator/env                        # 404
```

## Common errors

| Symptom | Fix |
|---|---|
| `./mvnw: Permission denied` | `chmod +x mvnw` (and commit the exec bit: `git update-index --chmod=+x mvnw`) |
| `Could not find artifact ...:spring-boot-starter-parent:pom:4.1.2.RELEASE` | use `4.1.2` |
| `Unsupported class file major version` / wrong Java | `export JAVA_HOME="$(/usr/libexec/java_home -v 21)"` |
| `package org.springframework.boot.test.autoconfigure.web.servlet does not exist` | Boot 4 path: `org.springframework.boot.webmvc.test.autoconfigure` |
| `Coverage checks have not been met` | add tests; don't lower `coverage.line.minimum` without a reason |
| wrapper: `Error: Failed to validate Maven distribution SHA-256` | download was tampered/corrupted, or the URL changed without updating the checksum — investigate, don't delete the line |

## Say this in the interview

> "The app is deliberately small so every line is defensible. Input validation is an allow-list enforced by Spring's
> built-in method validation, and the 400 never echoes the input, so there's no reflected XSS or log forging. Actuator is
> deny-by-default — not just unexposed but disabled — and I have tests that prove /env and /heapdump return 404 while
> the Kubernetes probes work. Config is validated at startup, so a broken secret sync fails the readiness probe instead
> of serving garbage. And I verified the toolchain: the Maven Wrapper matches Apache's release byte-for-byte and pins
> Maven by SHA-256. Spring Initializr even generated a parent version that doesn't exist — I check generated output
> against the registry, the same way I review AI-generated code."
