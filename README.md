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
  group: ${{ github.workflow }}-${{ github.ref }}-${{ github.sha }}
  cancel-in-progress: false
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

## Caveats / known gaps (in progress)

- **Multi-arch:** arm64 layers are not separately Trivy-scanned (amd64 is the gated representative). Decide per-arch scanning before relying on `multi-arch: true` for security gating.
- **Self-hosted matrix + service containers:** the 4 org runners share one host/Docker daemon; concurrent test shards map the same host ports (5432/6379) and can collide. Validate multi-shard runs before relying on high shard counts (single-shard is safe).
- **Deploy tail** (deploy-staging / verify-staging / require-staging-green / verify-prod + rollback), the **frontend lane**, **DAST**, **mutation testing**, and **release automation** are planned phases, not yet in the core orchestrator.
