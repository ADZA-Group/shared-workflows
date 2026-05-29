# Unified CI — Phase 3a: Orchestrator Core (`reusable-ci.yml`) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Create the canonical orchestrator `reusable-ci.yml` — the "one pipeline" — wiring the validated composites + hardened sub-reusables into a single parameterized DAG. This **core** slice covers `changes → lint-python → security-scan → pytest-matrix → coverage-gate + test-results → docker-build → telemetry`.

**Architecture:** One reusable workflow. App `build.yml` calls it with ~10 inputs. Inline jobs handle triage/lint/test/coverage/telemetry; `uses:` jobs delegate security and docker-build to the hardened sub-reusables (full path `@dev`, nesting depth app→ci→sub = 3, within GitHub's limit of 4). The pytest matrix is generated dynamically from a `test-shards` JSON input; per-app test env (incl. DB URL) flows via a `test-env` JSON loaded into `$GITHUB_ENV`.

**Tech Stack:** GitHub reusable workflows (mixed `steps:` + `uses:` jobs, dynamic matrix via `fromJSON`), the Phase-1 composites + Phase-2 reusables, `dorny/paths-filter`, `EnricoMi/publish-unit-test-result-action`, postgres/redis service containers, `actionlint`, `yamllint`.

**Spec:** `docs/superpowers/specs/2026-05-28-unified-ci-design.md` §3.1 (orchestrator model), §3.3 (input contract), §4 (the wave DAG), §5.3 (orchestrator).

---

## Scope boundary (explicit)

- **IN (core):** `changes`, `lint-python`, `security` (→ reusable-security-scan), `test-matrix` (dynamic shards + postgres+redis services + composites), `coverage` (→ coverage-gate composite), `test-results` (EnricoMi), `docker-build` (→ reusable-docker-build), `telemetry`.
- **OUT (later phases — their reusables/jobs aren't built yet, so NOT referenced here):** full lint suite (dockerfile/code-quality/dead-code/todo/license), property-tests, frontend lane (`reusable-frontend`), mutation (`reusable-mutation`), DAST (`reusable-dast`), lighthouse, the deploy/verify tail (deploy-staging/verify-staging/require-staging-green/verify-prod), notify (`reusable-notify` wiring), PR-summary. These are **Phase 3b + the new-reusables phase**.
- **Redis:** the core provides **both** postgres + redis services unconditionally (cheap; avoids GitHub's no-conditional-services limitation). A truly optional redis is a later refinement.

## Critical constraints
1. **Full-path `@dev` refs** for all composites + sub-reusables (caller-resolution rule). Validation deferred (needs `dev` pushed). Local checks = `actionlint` + `yamllint` only. **This orchestrator has the most runtime wiring of anything so far (dynamic matrix, nested reusable calls, cross-job artifact flow, services, env-JSON) — actionlint validates syntax/expressions but NOT this wiring. A real-runner run is strongly advised before building further on it.**
2. **Pins (resolved 2026-05-28):** `actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5  # v4`; `dorny/paths-filter@fbd0ab8f3e69293af611ebaee6363fc25e6d187d  # v4.0.1`; `actions/download-artifact@fa0a91b85d4f404e444e00e005971372dc801d16  # v4.1.8`; `EnricoMi/publish-unit-test-result-action@c950f6fb443cb5af20a377fd0dfaa78838901040  # v2.23.0`. Composites/reusables via `adza-group/shared-workflows/...@dev`.
3. **test-shards JSON schema:** array of `{ "name": str, "paths": str, "markers"?: str, "cov"?: str }`. `markers` defaults to `''`, `cov` (→ run-pytest-shard `coverage-source`) defaults to `'.'`.

## Environment & rules
- Work from `C:\Users\ADZArecaclage\Documents\Projekte\shared-workflows`, branch `dev`.
- Linters: `./bin/actionlint.exe <file>`, `python -m yamllint -d relaxed <file>` (or the `yamllint.exe` full path). This IS a workflow → actionlint validates all expressions; must exit 0.
- Git: NO `git config`; inline identity. No push. Explicit `git add <paths>` (untracked `bin/` stays untracked).

---

### Task 1: Create `reusable-ci.yml` (orchestrator core)

**Files:**
- Create: `.github/workflows/reusable-ci.yml`

- [ ] **Step 1: Write the file** with this content (verbatim):

```yaml
# ═══════════════════════════════════════════════════════════════
# Reusable CI Orchestrator (CORE) — ADZA-Group
#
# The one canonical pipeline. Apps call this with ~10 inputs.
# CORE: changes → lint-python + security → pytest-matrix →
#       coverage + test-results → docker-build → telemetry.
# Composites + sub-reusables referenced by full path @dev (→ @v1 at release).
#
# Usage (app build.yml):
#   jobs:
#     ci:
#       uses: adza-group/shared-workflows/.github/workflows/reusable-ci.yml@v1
#       with:
#         app-name: rechnungsapp
#         coverage-threshold: 49
#         test-shards: >-
#           [{"name":"backend","paths":"tests/test_models.py tests/test_auth.py"},
#            {"name":"integration","paths":"tests/integration/"}]
#         test-env: '{"RECHNUNG_TESTING":"1","RECHNUNG_DATABASE_URL":"postgresql://postgres:postgres@localhost:5432/test"}'
#       secrets: inherit
# ═══════════════════════════════════════════════════════════════

name: "🚀 CI"

on:
  workflow_call:
    inputs:
      app-name:
        required: true
        type: string
      runner-label:
        required: false
        type: string
        default: '["self-hosted", "linux", "proxmox"]'
      python-version:
        required: false
        type: string
        default: "3.11"
      test-shards:
        required: true
        type: string
        description: 'JSON array of {name, paths, markers?, cov?}'
      test-env:
        required: false
        type: string
        default: "{}"
        description: "JSON of env vars for test jobs (include the DB URL here)"
      coverage-threshold:
        required: false
        type: number
        default: 50
      postgres-version:
        required: false
        type: string
        default: "16-alpine"
      install-system-deps:
        required: false
        type: boolean
        default: false
      image-name:
        required: false
        type: string
        default: ""
      image-size-limit-mb:
        required: false
        type: number
        default: 800
      multi-arch:
        required: false
        type: boolean
        default: false
      sign-image:
        required: false
        type: boolean
        default: true

permissions:
  contents: read

jobs:
  changes:
    name: "🔍 Detect Changes"
    runs-on: ${{ fromJSON(inputs.runner-label) }}
    timeout-minutes: 5
    outputs:
      python: ${{ steps.filter.outputs.python }}
      docker: ${{ steps.filter.outputs.docker }}
      frontend: ${{ steps.filter.outputs.frontend }}
      ci: ${{ steps.filter.outputs.ci }}
      any_code: ${{ steps.filter.outputs.python == 'true' || steps.filter.outputs.docker == 'true' || steps.filter.outputs.frontend == 'true' }}
      start_time: ${{ steps.t.outputs.epoch }}
    steps:
      - uses: actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5  # v4
      - id: t
        run: echo "epoch=$(date +%s)" >> "$GITHUB_OUTPUT"
      - id: filter
        uses: dorny/paths-filter@fbd0ab8f3e69293af611ebaee6363fc25e6d187d  # v4.0.1
        with:
          filters: |
            python:
              - '**/*.py'
              - 'requirements*.txt'
              - 'pytest.ini'
              - '.coveragerc'
            docker:
              - 'Dockerfile'
              - 'docker-compose*.yml'
            frontend:
              - 'frontend/**'
            ci:
              - '.github/**'

  lint-python:
    name: "🐍 Lint (ruff)"
    needs: changes
    if: ${{ needs.changes.outputs.python == 'true' || needs.changes.outputs.ci == 'true' }}
    runs-on: ${{ fromJSON(inputs.runner-label) }}
    timeout-minutes: 10
    steps:
      - uses: actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5  # v4
      - uses: adza-group/shared-workflows/.github/actions/setup-python-deps@dev
        with:
          install-requirements: "false"
          extra-packages: "ruff==0.*"
          cache-key-suffix: lint
      - name: Ruff
        run: |
          ruff check . --output-format=github
          ruff format --check --diff .

  security:
    name: "🔐 Security"
    needs: changes
    if: ${{ needs.changes.outputs.any_code == 'true' || needs.changes.outputs.ci == 'true' }}
    uses: adza-group/shared-workflows/.github/workflows/reusable-security-scan.yml@dev
    with:
      python-version: ${{ inputs.python-version }}
      runner-label: ${{ inputs.runner-label }}
    secrets: inherit

  test-matrix:
    name: "🧪 Test"
    needs: changes
    if: ${{ needs.changes.outputs.python == 'true' || needs.changes.outputs.ci == 'true' }}
    runs-on: ${{ fromJSON(inputs.runner-label) }}
    timeout-minutes: 20
    strategy:
      fail-fast: false
      matrix:
        shard: ${{ fromJSON(inputs.test-shards) }}
    services:
      postgres:
        image: postgres:${{ inputs.postgres-version }}
        env:
          POSTGRES_USER: postgres
          POSTGRES_PASSWORD: postgres
          POSTGRES_DB: test
        ports:
          - 5432:5432
        options: >-
          --health-cmd "pg_isready -U postgres"
          --health-interval 5s
          --health-timeout 5s
          --health-retries 10
      redis:
        image: redis:7-alpine
        ports:
          - 6379:6379
        options: >-
          --health-cmd "redis-cli ping"
          --health-interval 5s
          --health-timeout 5s
          --health-retries 10
    steps:
      - uses: actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5  # v4
      - name: Load test env
        env:
          TEST_ENV: ${{ inputs.test-env }}
        run: |
          python3 - <<'PY' >> "$GITHUB_ENV"
          import json, os
          for k, v in json.loads(os.environ.get('TEST_ENV') or '{}').items():
              print(f"{k}={v}")
          PY
      - uses: adza-group/shared-workflows/.github/actions/setup-python-deps@dev
        with:
          install-requirements: "true"
          install-system-deps: ${{ inputs.install-system-deps }}
          install-coverage: "true"
          cache-key-suffix: test-${{ matrix.shard.name }}
      - uses: adza-group/shared-workflows/.github/actions/run-pytest-shard@dev
        with:
          shard-name: ${{ matrix.shard.name }}
          test-paths: ${{ matrix.shard.paths }}
          markers: ${{ matrix.shard.markers || '' }}
          coverage-source: ${{ matrix.shard.cov || '.' }}

  coverage:
    name: "📊 Coverage Gate"
    needs: test-matrix
    if: ${{ always() && needs.test-matrix.result != 'skipped' }}
    runs-on: ${{ fromJSON(inputs.runner-label) }}
    timeout-minutes: 10
    steps:
      - uses: actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5  # v4
      - uses: adza-group/shared-workflows/.github/actions/setup-python-deps@dev
        with:
          install-requirements: "false"
          install-coverage: "true"
          cache-key-suffix: coverage
      - uses: adza-group/shared-workflows/.github/actions/coverage-gate@dev
        with:
          threshold: ${{ inputs.coverage-threshold }}
          blocking: "true"

  test-results:
    name: "📋 Test Results"
    needs: test-matrix
    if: ${{ always() && needs.test-matrix.result != 'skipped' }}
    runs-on: ${{ fromJSON(inputs.runner-label) }}
    timeout-minutes: 10
    permissions:
      contents: read
      checks: write
    steps:
      - uses: actions/download-artifact@fa0a91b85d4f404e444e00e005971372dc801d16  # v4.1.8
        with:
          pattern: junit-*
          path: junit
          merge-multiple: true
      - uses: EnricoMi/publish-unit-test-result-action@c950f6fb443cb5af20a377fd0dfaa78838901040  # v2.23.0
        continue-on-error: true
        with:
          junit_files: "junit/junit-*.xml"
          comment_mode: "off"

  docker-build:
    name: "🐳 Build"
    needs: [changes, lint-python, test-matrix]
    if: ${{ always() && needs.lint-python.result != 'failure' && needs.test-matrix.result == 'success' && (needs.changes.outputs.any_code == 'true' || needs.changes.outputs.ci == 'true') }}
    uses: adza-group/shared-workflows/.github/workflows/reusable-docker-build.yml@dev
    with:
      image-name: ${{ inputs.image-name != '' && inputs.image-name || format('ghcr.io/adza-group/{0}', inputs.app-name) }}
      push: ${{ github.event_name == 'push' }}
      sign-image: ${{ inputs.sign-image }}
      platforms: ${{ inputs.multi-arch && 'linux/amd64,linux/arm64' || 'linux/amd64' }}
      image-size-limit-mb: ${{ inputs.image-size-limit-mb }}
      runner-label: ${{ inputs.runner-label }}
    secrets: inherit

  telemetry:
    name: "📈 Telemetry"
    needs: [changes, lint-python, security, test-matrix, coverage, test-results, docker-build]
    if: ${{ always() }}
    runs-on: ${{ fromJSON(inputs.runner-label) }}
    timeout-minutes: 5
    steps:
      - name: Summary
        run: |
          START="${{ needs.changes.outputs.start_time }}"
          NOW=$(date +%s)
          DUR=$(( NOW - ${START:-NOW} ))
          {
            echo "## 🚀 CI Telemetry — ${{ inputs.app-name }}"
            echo "| Job | Result |"
            echo "|-----|--------|"
            echo "| lint-python | ${{ needs.lint-python.result }} |"
            echo "| security | ${{ needs.security.result }} |"
            echo "| test-matrix | ${{ needs.test-matrix.result }} |"
            echo "| coverage | ${{ needs.coverage.result }} |"
            echo "| test-results | ${{ needs.test-results.result }} |"
            echo "| docker-build | ${{ needs.docker-build.result }} |"
            echo "| **wall-clock** | **${DUR}s** |"
          } >> "$GITHUB_STEP_SUMMARY"
```

- [ ] **Step 2: Static-validate**

Run: `./bin/actionlint.exe .github/workflows/reusable-ci.yml && python -m yamllint -d relaxed .github/workflows/reusable-ci.yml`
Expected: actionlint exit 0 (it validates `fromJSON`, the matrix object refs `matrix.shard.*`, the `needs.*.result`/`needs.*.outputs.*` refs, the `with:` expressions on the reusable-call jobs, and shellchecks the `run:` blocks — the `<<'PY'` heredoc is literal). yamllint exit 0 (line-length warnings ok). If actionlint flags `matrix.shard.markers || ''` / `matrix.shard.cov || '.'` (unknown matrix property), that is acceptable IF actionlint still exits 0; if it errors, switch those to bracket form `matrix.shard['markers']`/`matrix.shard['cov']` and re-run. If any other expression errors, fix syntax without changing semantics; if irreconcilable, STOP and report.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/reusable-ci.yml
NAME=$(git log -1 --format='%an'); EMAIL=$(git log -1 --format='%ae')
git -c user.name="$NAME" -c user.email="$EMAIL" commit -m "feat(ci): add reusable-ci.yml orchestrator core (changes→lint→security→test→coverage→build→telemetry)"
```

---

### Validation (DEFERRED — strongly recommended next)

Not runnable locally (composite/sub-reusable `@dev` refs + the runtime wiring need GitHub + the self-hosted runner). When `dev` is pushed, validate via a **pilot app caller** (FootballApp, Phase 4) on `dev`, OR a fixture caller in shared-workflows. Confirm: dynamic matrix expands from `test-shards`; composites resolve at `@dev`; the nested `security` + `docker-build` reusable calls run; coverage artifacts flow `run-pytest-shard → coverage-gate`; telemetry renders. **Given the wiring density, do this before Phase 3b / app rollout.**

---

## Self-Review

**1. Spec coverage (§4 core waves):** Wave 0 `changes` ✓ (+ start_time); Wave 1 `lint-python` ✓; Wave 1b `security` via reusable ✓; Wave 2 `test-matrix` dynamic shards + services ✓; Wave 2b `coverage` (composite) + `test-results` (EnricoMi) ✓; Wave 3 `docker-build` via reusable (push on push-event, sign, multi-arch, default image name) ✓; Wave 6 `telemetry` ✓. Deploy tail + full lint + extras explicitly deferred (scope boundary) — no false coverage claim.

**2. Placeholder scan:** No TBD/TODO. All pins concrete. `image-name` default computed via `format()`. `test-env` defaults `{}`. The deferred validation is a real next step.

**3. Type/expression consistency:** composite input names (`install-requirements`, `extra-packages`, `cache-key-suffix`, `install-coverage`, `install-system-deps`, `shard-name`, `test-paths`, `markers`, `coverage-source`, `threshold`, `blocking`) all match the Phase-1 composite definitions. Sub-reusable inputs (`python-version`, `runner-label` for security-scan; `image-name`, `push`, `sign-image`, `platforms`, `image-size-limit-mb`, `runner-label` for docker-build) match the Phase-2 reusable contracts. `needs.changes.outputs.*` match the `changes` job outputs. `matrix.shard.{name,paths,markers,cov}` matches the documented test-shards schema. download-artifact `pattern: junit-*` matches run-pytest-shard's `junit-<shard>` artifact name; coverage-gate consumes `covdata-*` (uploaded by run-pytest-shard) — consistent. `${START:-NOW}` guards an empty start_time in telemetry.

**Risk note (carried to summary):** this is the densest runtime wiring in the project and is validated locally only by actionlint. A real-runner run is the recommended immediate next step before building Phase 3b or migrating apps.
