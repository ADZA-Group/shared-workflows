# Senior-Level CI Power-up — Umbrella Design (shared-workflows → v1.5.0)

- **Date:** 2026-06-03
- **Scope:** `shared-workflows` reusables + composites + per-app callers + 2 config-repo callers + per-repo GitHub config. Released incrementally; floating `@v1` advanced per phase.
- **Status:** approved design (brainstorming). **Decomposed into 6 independently spec→plan→impl-able phases.** Implementation recommended phase-by-phase in fresh sessions (this umbrella spec is the contract).

## 1. Goal

Bring the already-comprehensive ADZA unified CI to **world-class "cover everything" level** by closing the *genuine* remaining gaps — fleet-wide, free, self-hosted-capable — without paid (GHAS) dependencies. Success = a senior reviewer finds no obvious missing quality/security/deploy gate that is feasible on a free/self-hosted GitHub org.

## 2. Current state (baseline — already strong)

All 3 real ADZA-Group apps (`rechnungsapp`, `footballapp`, `recyclage-app`) + `azad-ahmed/MitarbeiterApp` consume `adza-group/shared-workflows/.github/workflows/reusable-ci.yml@v1` (= v1.4.2). The orchestrator runs **25 jobs**: changes · lint-python · lint-dockerfile · code-quality · dead-code · todo-tracker · license-check · commit-lint · security (codeql · bandit · semgrep · trivy-fs · pip-audit · gitleaks · dep-review · opa) · test-matrix · coverage · test-results · property-tests · mutation · frontend · load-test · dast · docker-build (+SBOM · cosign · SLSA · trivy-image · size-gate) · verify-staging · require-staging-green · verify-prod (+auto-rollback) · prune-ghcr · telemetry · pr-summary · notify. Plus 13 standalone reusables (release, security-weekly, monitoring-dashboard, pipeline-analytics, weekly-cleanup, notify, …). All runner-label-driven (self-hosted-capable, validated). `paperless` + `cloudflare` are **config-only repos** (only `docker-compose.yml` — no app code/tests).

## 3. The 6 phases

Each phase is independently shippable (own tag bump, own validation). Cross-cutting rules (§4) apply to all.

### Phase A — Test depth (diff-coverage + flaky-handling)
**Files:** `.github/actions/run-pytest-shard/action.yml`, `.github/actions/coverage-gate/action.yml`, `.github/workflows/reusable-ci.yml`.
- **Diff-coverage gate:** the `coverage` job gains a step that installs `diff-cover` and runs `diff-cover coverage.xml --compare-branch=origin/${{ github.base_ref || 'main' }} --fail-under=<diff-coverage-threshold>`. New input `diff-coverage-threshold` (default `80`). Requires `fetch-depth: 0` on the coverage job's checkout (add it). Dual-gate (`continue-on-error` advisory on PR/dev, hard on main/tags). Catches "new code untested" even when absolute coverage passes.
- **Flaky-handling:** `run-pytest-shard` adds `pytest-rerun-failures` to its pip install and `--reruns ${{ inputs.test-reruns }} --reruns-delay 1` to the pytest invocation. New input `test-reruns` (default `1`; `0` disables). Reruns surface in the JUnit/test-results output. Note in summary how many tests needed a rerun (flaky signal).

### Phase B — Supply-chain enforced (cosign signing fleet-wide)
**Files:** `.github/workflows/reusable-docker-build.yml`, `.github/workflows/reusable-ci.yml` (input default), `FootballApp/.github/workflows/build.yml` (drop `sign-image: false`).
- Cosign keyless signing + SLSA attest already exist in `reusable-docker-build` (continue-on-error, gated by `sign-image`). **Flip `sign-image` default `false`→`true`** in `reusable-ci` + `reusable-docker-build` inputs; remove `sign-image: false` from FootballApp caller. Keyless OIDC via Fulcio = **free** (needs `id-token: write` — already granted on the docker-build job). Signing/attest stay `continue-on-error` (Sigstore outages must not block the build). The **verify** gate (`require-signed-images` repo-var) stays opt-in.
- Document external verification: `cosign verify --certificate-identity-regexp '^https://github.com/ADZA-Group/<app>/' --certificate-oidc-issuer 'https://token.actions.githubusercontent.com' <image>` + `gh attestation verify oci://<image> --repo ADZA-Group/<app>`.

### Phase C — Frontend quality (a11y + Lighthouse perf-budget)
**Files:** `.github/workflows/reusable-frontend.yml` (+ a `lighthouserc.json` budget template).
- After `vite build`, start a preview server (`npm run preview` or `npx vite preview --port 4173`), then:
  - **a11y:** run `pa11y-ci` (or `@axe-core/cli`) against the key routes; new input `a11y-enabled` (default `true`), dual-gate.
  - **Lighthouse-CI:** `npx @lhci/cli autorun` with a budget (`lighthouserc.json`: assertions for performance/accessibility/best-practices, e.g., perf ≥ 0.8). New input `lighthouse-enabled` (default `true`) + overridable budget path. Dual-gate.
- `actions/setup-node` already used → node available on self-hosted (downloads node, validated). Preview server runs on the runner; checks hit `localhost`.

### Phase D — API contract testing (schemathesis) — BIGGEST EFFORT
**Files:** new `.github/workflows/reusable-api-contract.yml`; reusable-ci wiring (input `openapi-spec`); **per-app prerequisite work.**
- New reusable starts the app (reuse `start-app` composite) and runs `schemathesis run <openapi-spec>` (property-based API fuzzing against the contract). New input `openapi-spec` (path or URL, e.g. `http://localhost:5000/openapi.json`). Dual-gate.
- **⚠️ Honest prerequisite:** the Flask apps currently expose **no OpenAPI spec**. This phase therefore includes per-app code work to emit one (`flask-smorest`/`apispec`, or a static `openapi.yaml`). If an app has no spec, the api-contract job **skips** (input empty → advisory no-op). This is the largest, app-by-app effort and may itself be a sub-initiative per app.

### Phase E — Deploy quality (environments + approval + PR-concurrency)
**Files:** `.github/workflows/reusable-ci.yml` (verify-prod/deploy `environment:`); per-repo `gh api` setup; per-app caller `concurrency`.
- **GitHub Environments:** add `environment: ${{ inputs.prod-environment }}` (new input, default `''` → no environment unless set) to the prod-deploy/verify job. Create a `production` environment per repo with a **required reviewer** (approval gate before prod) via `gh api -X PUT repos/<r>/environments/production -f 'reviewers[...]'`.
  - **⚠️ Caveat:** Environment *protection rules* (required reviewers) on **private** repos historically need GitHub Pro/Team (free-private has limited environments — same class as the branch-protection limitation hit in Sprint 1Q-A). **Validate first**; if free-private blocks it, fall back to a manual `workflow_dispatch` approval step or document the limitation. Public repos (shared-workflows) are unaffected.
- **PR-concurrency:** change each caller's `concurrency.cancel-in-progress` to `${{ github.event_name == 'pull_request' }}` (cancel superseded PR runs to save self-hosted runners; keep `false` for push/main so deploys aren't interrupted).

### Phase F — Config-CI for infra repos (paperless + cloudflare)
**Files:** new `.github/workflows/reusable-config-ci.yml`; thin callers `paperless/.github/workflows/ci.yml` + `cloudflare/.github/workflows/ci.yml`.
- Lightweight reusable (runner-label-driven) with jobs: `yamllint` (relaxed), `docker compose config` validation (syntax + interpolation), `gitleaks` (secret scan), and `opa`/`conftest` on the compose file (reuse the existing `opa-policy` composite + compose.rego). NO python/test/docker-build/frontend jobs (these repos have no code). Dual-gate. Each repo gets a ~15-line thin caller.

## 4. Cross-cutting rules (all phases)

- **Dual-gate:** advisory on PR/dev, hard on main/tags (`continue-on-error: ${{ !(github.ref == 'refs/heads/main' || startsWith(github.ref, 'refs/tags/')) }}`), except where a gate is inherently advisory.
- **Runner-label-driven:** every new job uses `runs-on: ${{ fromJSON(inputs.runner-label) }}`; nested reusables get `runner-label` forwarded (lesson from v1.4.2 — never hardcode `ubuntu-latest`).
- **SHA-pinned** third-party actions (first-party `actions/*` + `github/codeql-action/*` may stay major-tag).
- **Release discipline:** build on `dev`, `actionlint` clean, validate on a real app dev run (self-hosted), tag `v1.5.x`, move floating `@v1`, verify `git ls-remote`.
- **Internal refs float `@v1`** (lesson from the orchestrator-drift incident — never pin internal refs to an exact stale tag).

## 5. Decomposition & recommended order

1. **Phase A** (diff-coverage + flaky) — quick, high value, pure reusable/composite edits.
2. **Phase B** (cosign signing on) — quick, high value, flip a default.
3. **Phase F** (config-CI for paperless/cloudflare) — quick, self-contained, completes "all org repos covered".
4. **Phase C** (frontend a11y + Lighthouse) — medium, reusable-frontend only.
5. **Phase E** (environments + approval + PR-concurrency) — medium, needs per-repo setup + the free-private caveat validation.
6. **Phase D** (API contract) — largest; per-app OpenAPI prerequisite; likely its own sub-initiative per app.

Each phase: its own `writing-plans` → `executing-plans`/`subagent-driven-development` cycle, validated dev-first, released as a `v1.5.x` bump.

## 6. Risks / explicit validation points

1. **Phase D OpenAPI** — apps lack specs; emitting them is real app-code work per app (biggest unknown). Until present, api-contract is advisory-skip.
2. **Phase E Environments on free-private** — required-reviewer protection may be paid-gated (like branch-protection). Validate on one repo first; fall back to manual-approval job if blocked.
3. **Phase C on self-hosted** — preview server + headless Chrome (Lighthouse/axe) on the 4 GB LXC-104 runner: monitor RAM; Lighthouse/Chrome can be heavy. May need `--no-sandbox` + memory care, or run frontend-quality on hosted when minutes available (runner-label already supports the hybrid).
4. **Self-hosted load** — more jobs per pipeline on 3×4 GB runners → queue/OOM pressure. Stagger or cap parallelism; the decide-runner hybrid uses hosted when free minutes are available.

## 7. Non-goals (YAGNI / paid)

- CodeQL → Security-tab upload, SLSA-verify as a **hard** gate, Dependency-Graph/dependency-review enforcement — all need **GitHub Advanced Security (paid)**. Kept advisory.
- Renovate — Dependabot already covers dependency updates.
- Visual-regression (Percy/Chromatic) — paid SaaS; deferred.
- Multi-arch images — dropped (amd64-only; prod LXCs are amd64).

### Phase G — e2e (Playwright, pre-merge) [NACHGETRAGEN 2026-06-09]

Beim Original-Audit übersehen: RecyclageApp hatte vor der P4-Migration eine Playwright-Suite
(commit `0af76c9`), die beim Umstieg auf den thin caller (`b176c29`) verloren ging. Phase G stellt
sie als opt-in Unified-Job wieder her: `reusable-e2e.yml` (Playwright-Container + `start-app`-Boot,
postgres/redis, dual-gate). Aktivierung per-App via `enable-e2e` + `e2e-boot-command` + Playwright-Specs.
Design: `docs/superpowers/specs/2026-06-09-ci-deploy-gate-c2-e2e-design.md`. Empirisch validiert
2026-06-09 (`_smoke-e2e` grün auf ubuntu; Full-Orchestrator-Smoke `_smoke-ci` grün, docker-build läuft
durch die neuen Gates).
