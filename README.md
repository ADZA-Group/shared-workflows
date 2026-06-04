# ADZA-Group Shared Workflows

Reusable CI/CD workflows and composite actions for all ADZA-Group repositories.
The goal: every app's `.github/workflows/build.yml` is a ~25-line caller of
`reusable-ci.yml` — one canonical pipeline, zero drift.

> **Versioning:** during build-out these are referenced `@dev`; pin app callers to a
> release tag (`@v1`) once cut. Note that `uses: ./` does NOT work across repos — sibling
> composites/reusables are referenced by full path `adza-group/shared-workflows/...@<ref>`.

## Reusable Workflows

| Workflow | Purpose |
|----------|---------|
| `reusable-ci.yml` | **Orchestrator** — the one pipeline: changes → lint → security → test-matrix → coverage → docker build → telemetry |
| `reusable-security-scan.yml` | gitleaks · Bandit · Semgrep · Trivy fs/IaC · pip-audit · CodeQL (py+js) · dependency-review · OPA. Dual-gate (advisory on PR/dev, blocking on main/tags) |
| `reusable-docker-build.yml` | buildx + size gate + Trivy image gate + SBOM + smoke; optional GHCR push + cosign keyless + SLSA provenance + multi-arch + `:previous` backup |
| `reusable-load-test.yml` | k6 with enforced p95 + error-rate budgets (advisory/blocking toggle) |
| `reusable-notify.yml` | Discord / Slack / Telegram alerts |
| `reusable-monitoring-dashboard.yml` | scheduled app + pipeline health dashboard |
| `reusable-pipeline-analytics.yml` | scheduled CI success-rate / duration analytics |
| `reusable-weekly-cleanup.yml` | scheduled run/artifact retention cleanup |
| `reusable-config-ci.yml` | infra/config-only repos (compose only): yamllint + `docker compose config` + gitleaks + OPA/conftest on the compose; dual-gate, runner-label-driven |
| `reusable-frontend.yml` | node lane: eslint + tsc + vitest + vite build + bundle-size gate + Lighthouse CI + **pa11y-ci accessibility gate** (dual-gate) |
| `reusable-api-contract.yml` | boots the app (`start-app` composite) + runs **schemathesis** property-based fuzzing against its OpenAPI spec; opt-in, skips when no `openapi-spec` (dual-gate) |

## Composite Actions

| Action | Purpose |
|--------|---------|
| `setup-python-deps` | **Debian-13 safe** — system `python3` + per-job venv + cached deps (replaces `setup-python-env`) |
| `run-pytest-shard` | run one test shard → `.coverage.<shard>` data + junit; uploads both |
| `coverage-gate` | `coverage combine` across shards (true union) → fail-under gate |
| `start-app` | background-launch an app + poll health, output PID |
| `opa-policy` | conftest/OPA Rego checks on Dockerfile + compose |
| `health-check` | endpoint polling + security-header validation |
| `setup-python-env` | *(legacy — uses `actions/setup-python`, breaks on Debian-13 self-hosted; prefer `setup-python-deps`)* |

## Consuming `reusable-ci.yml`

An app's entire `build.yml`:

```yaml
name: CI/CD
on:
  push:         { branches: [main, dev], tags: ['v*'] }
  pull_request: { branches: [main, dev] }
concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}
permissions:               # ⚠️ REQUIRED — see note below
  contents: read
  packages: write
  id-token: write
  attestations: write
  security-events: write
  checks: write
  issues: write         # verify-prod opens incident issues on failure
  pull-requests: write  # pr-summary posts sticky CI comment on PRs
jobs:
  ci:
    uses: adza-group/shared-workflows/.github/workflows/reusable-ci.yml@v1
    with:
      app-name: rechnungsapp
      coverage-threshold: 49
      test-shards: >-
        [{"name":"backend","paths":"tests/test_models.py tests/test_auth.py"},
         {"name":"integration","paths":"tests/integration/"}]
      test-env: '{"RECHNUNG_TESTING":"1","RECHNUNG_DATABASE_URL":"postgresql://postgres:postgres@localhost:5432/test"}'
      install-system-deps: true     # tesseract/poppler for PDF/OCR apps
      multi-arch: false
    secrets: inherit
```

### ⚠️ Required caller permissions

A **called** reusable workflow's `GITHUB_TOKEN` can only be **equal to or more restrictive
than the caller's** — if the callee requests more, GitHub fails the run at **`startup_failure`**
("workflow file issue"). `reusable-ci` delegates to nested jobs that need elevated scopes
(`docker-build` → `packages`/`id-token`/`attestations: write`; `security` → `security-events: write`;
`test-results` → `checks: write`; `verify-prod` → `issues: write` for incident issues; `pr-summary` → `pull-requests: write` for sticky PR comments). Therefore the **caller MUST grant the `permissions:` block above**
(workflow-level or on the `ci` job). Omitting it is the #1 adoption pitfall.

### Key inputs (`reusable-ci.yml`)

| Input | Default | Notes |
|-------|---------|-------|
| `app-name` | *(required)* | image name defaults to `ghcr.io/adza-group/<app-name>` |
| `test-shards` | *(required)* | JSON `[{name, paths, markers?, cov?}]` → dynamic test matrix |
| `test-env` | `{}` | JSON env for test jobs (put the DB URL here; postgres+redis services are provided) |
| `coverage-threshold` | `50` | union-coverage gate (blocking) |
| `install-system-deps` | `false` | tesseract/poppler |
| `multi-arch` | `false` | amd64+arm64 (arm64 currently scanned via the amd64 representative — see CAVEATS) |
| `enable-push` | `true` | GHCR push on `push` events (false for build-only) |
| `deploy-*` / verify | *(Phase 3b)* | deploy/verify tail not yet wired in the core orchestrator |

## Config-only repos (paperless, cloudflare)

Repos that contain only a `docker-compose.yml` (no app code/tests/Dockerfile) use the
lightweight `reusable-config-ci.yml` instead of the full `reusable-ci.yml`:

```yaml
name: CI
on:
  push:         { branches: [main, dev] }
  pull_request: { branches: [main] }
  workflow_dispatch:
permissions:
  contents: read
jobs:
  config:
    uses: adza-group/shared-workflows/.github/workflows/reusable-config-ci.yml@v1
    with:
      runner-label: ${{ vars.RUNNER_LABEL || '["ubuntu-latest"]' }}
    secrets: inherit
```

Gates: yamllint (relaxed) · `docker compose config` · gitleaks · OPA/conftest on the compose.
gitleaks is always hard; the rest dual-gate (advisory on PR/dev, blocking on main/tags).

## Frontend accessibility & performance

`reusable-frontend.yml` runs a **pa11y-ci accessibility gate** after build (dual-gate,
advisory on PR/dev, blocking on main/tags):

| Input | Default | Notes |
|-------|---------|-------|
| `a11y-enabled` | `true` | run pa11y-ci |
| `a11y-url` | `""` | base URL to scan; empty = serve the build output locally |
| `a11y-paths` | `"/"` | space-separated paths (e.g. `"/ /login /about"`) |
| `a11y-threshold` | `0` | max pa11y errors per page |
| `lighthouse-url` | `""` | Lighthouse CI target (empty = skip) |
| `lighthouse-config` | `""` | path to a `lighthouserc.json` budget (empty = recommended preset) |

A budget template lives at `tests/fixtures/frontend/lighthouserc.json` (perf ≥ 0.8,
a11y ≥ 0.9). For server-rendered apps (Jinja/HTMX), point `a11y-url` at a deployed
staging URL; for SPAs, leave it empty to scan the local build.

## Image signing & verification

Every image pushed by `reusable-ci.yml` (and `reusable-docker-build.yml` when `push: true`)
is signed by default via **cosign keyless** (Fulcio OIDC, `sigstore/cosign-installer@v4.1.2`)
and gets a **SLSA build provenance attestation** (`actions/attest-build-provenance@v2`).
Both steps run `continue-on-error: true` — they are best-effort: a Sigstore/Rekor outage,
a paid-only org limit, or a missing scope will produce an advisory red step but never block
the push.

### Opt-out

Set `sign-image: false` in your caller `with:` block only if you have a specific reason
(e.g. you call `reusable-docker-build` from a context without `id-token: write`). The
default is `true` for all ADZA-Group apps.

### Verifying a signed image externally

```bash
# 1. Cosign signature (Fulcio keyless, Rekor transparency log)
cosign verify \
  --certificate-identity-regexp '^https://github.com/ADZA-Group/<app>/' \
  --certificate-oidc-issuer 'https://token.actions.githubusercontent.com' \
  ghcr.io/adza-group/<app>:<tag>

# 2. SLSA build provenance attestation (GitHub-issued)
gh attestation verify oci://ghcr.io/adza-group/<app>:<tag> \
  --repo ADZA-Group/<app>
```

For an app under a user namespace (e.g. `azad-ahmed/mitarbeiter-app`), adjust the
`certificate-identity-regexp` and `--repo` accordingly.

### Optional hard-gate

The verify-side `require-signed-images` repo variable (consumed by `verify-prod`) is
**opt-in** and stays opt-in in Phase B — flip it per-repo only after a few green signing
runs are observed in the docker-build job log.

## Deploy environments (opt-in)

`reusable-ci.yml` accepts `prod-environment` / `staging-environment` (default `""` = none).
Setting `prod-environment: production` attaches the `verify-prod` job to a GitHub
Environment — giving a **Deployments tab + history** for free.

**Required-reviewer approval is a paid feature on private repos** (`gh api` returns
`422 "billing plan supports the required reviewers protection rule"`). On the free
private org, the environment exists for tracking but cannot enforce approval. To enable
approval: upgrade to GitHub Team/Pro, then
`gh api -X PUT repos/<r>/environments/production -f 'reviewers[][type]=User' -F 'reviewers[][id]=<id>'`.

**Note on the watchtower deploy model:** deploys are watchtower pull-based (no gate-able
deploy job). An environment on `verify-prod` gates the health-check; for true *pre-deploy*
approval you would gate the `:latest` push in `docker-build` (separate change, not wired).

## API contract testing (opt-in)

`reusable-ci.yml` accepts `openapi-spec` (+ `api-boot-command`, `api-health-url`,
`api-base-url`, `api-requirements`). When set, the `api-contract` job boots the app and
runs **schemathesis** (property-based fuzzing) against the spec; when empty (the default)
the job is **skipped**. Dual-gate.

**Prerequisite (app-code, not CI):** the ADZA Flask apps expose no OpenAPI spec yet. To
adopt: emit one (`flask-smorest`/`apispec` or a static `openapi.yaml`) and set
`openapi-spec: "http://localhost:<port>/openapi.json"` + `api-boot-command` on the caller.

## Caveats / known gaps (in progress)

- **Multi-arch:** arm64 layers are not separately Trivy-scanned (amd64 is the gated representative). Decide per-arch scanning before relying on `multi-arch: true` for security gating.
- **Self-hosted matrix + service containers:** the 4 org runners share one host/Docker daemon; concurrent test shards map the same host ports (5432/6379) and can collide. Validate multi-shard runs before relying on high shard counts (single-shard is safe).
- **Deploy tail** (deploy-staging / verify-staging / require-staging-green / verify-prod + rollback), the **frontend lane**, **DAST**, **mutation testing**, and **release automation** are planned phases, not yet in the core orchestrator.
