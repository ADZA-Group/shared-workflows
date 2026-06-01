# P4 App-Rollout — Design Spec

- **Date:** 2026-06-01
- **Status:** Approved
- **Owner:** Azad Ahmed (ADZA-Group)
- **Scope:** Migrate all 4 ADZA apps (FootballApp, RecyclageApp, Rechnungsapp, MitarbeiterApp) from their individual 305–1758-line `build.yml` pipelines to ~30-line thin callers of `reusable-ci.yml@v1`.
- **Prerequisite:** `shared-workflows@v1.2` is live, self-hosted runners (LXC-104) validated green.

---

## 1. Goal

Replace 4 independently-drifting app CI pipelines with thin callers that express only app-specific data (shards, env vars, flags). All pipeline logic lives in `shared-workflows`. One update point, zero drift.

**Success criteria:**
- All 4 apps' CI runs green on `dev` with the new thin caller
- All 4 apps merged to `main` with thin caller active
- Old `build.yml` content (300–1758 lines) completely replaced
- No regression in test coverage, security scans, or docker builds

---

## 2. Rollout Strategy

**Parallel across all 4 repos simultaneously.** Each app has its own `dev`/`main` branch pair — no cross-repo conflicts. Each migration is independent.

**Per-app sequence:**
```
1. [MitarbeiterApp only] cd frontend && npm install → commit package-lock.json
2. Replace .github/workflows/build.yml with thin caller
3. git push origin dev → CI runs on self-hosted (LXC-104)
4. CI green? → dev→main merge
5. Done
```

**Reference:** `@v1` (floating major tag) — apps auto-receive v1.x improvements without re-pinning.

---

## 3. Thin-Caller Template

Every app's `build.yml` follows this skeleton. App-specific data goes in the `with:` block only.

```yaml
# ═══════════════════════════════════════════════════════════════
# <AppName> CI/CD — Thin caller for adza-group/shared-workflows
# All pipeline logic in shared-workflows/reusable-ci.yml@v1
# ═══════════════════════════════════════════════════════════════

name: CI/CD

on:
  push:
    branches: [main, dev]
    tags: ['v*']
  pull_request:
    branches: [main, dev]

concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}-${{ github.sha }}
  cancel-in-progress: false

permissions:
  contents: read
  packages: write
  id-token: write
  attestations: write
  security-events: write
  checks: write
  issues: write          # verify-prod opens incident issues
  pull-requests: write   # pr-summary posts sticky CI comment

jobs:
  ci:
    uses: adza-group/shared-workflows/.github/workflows/reusable-ci.yml@v1
    with:
      # ← app-specific inputs here (see §4)
    secrets: inherit
```

**Why all 8 permissions:** `reusable-ci.yml` uses nested reusable workflows (docker-build, security-scan) that need elevated scopes. Per GitHub's rule, a called workflow cannot exceed the caller's grants — omitting any scope causes `startup_failure`.

---

## 4. Per-App Configurations

### 4.1 FootballApp

**Current CI:** 1358 lines, 6-shard pytest matrix (SQLite in-memory, no postgres needed), no frontend, no staging LXC.

```yaml
    with:
      app-name: footballapp
      coverage-threshold: 50
      deploy-prod: false
      staging-url: ""
      prod-url: ""
      enable-redis: false
      install-system-deps: false
      has-frontend: false
      test-env: >-
        {"FOOTBALL_TESTING":"1",
         "FOOTBALL_DISABLE_SCHEDULER":"1",
         "FOOTBALL_DATABASE_URL":"sqlite:///:memory:"}
      test-shards: >-
        [{"name":"smoke","paths":"tests/test_smoke.py tests/test_seed.py"},
         {"name":"models","paths":"tests/test_models.py tests/test_models_football.py"},
         {"name":"auth","paths":"tests/test_audit.py tests/test_security.py tests/test_routes/test_auth.py tests/test_routes/test_profile.py tests/test_routes/test_users.py"},
         {"name":"routes","paths":"tests/test_routes/test_health.py tests/test_routes/test_leagues.py"},
         {"name":"importers","paths":"tests/test_importers/"},
         {"name":"ml","paths":"tests/test_features_*.py tests/test_dixon_coles.py tests/test_asian_handicap.py tests/test_ml_predictor.py tests/test_ml_eval.py tests/test_ml_train_base.py tests/test_ml_train_calibration.py tests/test_ml_train_meta.py tests/test_llm_analyzer.py tests/test_ensemble.py tests/test_no_features_use_future_data.py tests/test_p1b_schema_migration.py tests/integration/"}]
```

**Notes:**
- Uses SQLite in-memory — `reusable-ci.yml` starts a postgres service per shard anyway (unused, ~15s overhead per shard, not breaking).
- 6 shards = same as current CI — no regression risk.
- `deploy-prod: false` + empty URLs → all Wave-5 deploy-tail jobs skip.

### 4.2 Rechnungsapp

**Current CI:** 1552 lines, 4 test jobs (backend/integration/pdf-import/migration), postgres+redis services, OCR via tesseract/poppler, `deploy-prod: false` (LXC-103 freeze).

```yaml
    with:
      app-name: rechnungsapp
      coverage-threshold: 49
      enable-redis: true
      install-system-deps: true
      deploy-prod: false
      staging-url: "https://i-rechnungsapp.adza-group.ch"
      prod-url: ""
      has-frontend: false
      test-env: >-
        {"RECHNUNG_TESTING":"1",
         "RECHNUNG_SECRET_KEY":"ci-test-secret",
         "RECHNUNG_DATABASE_URL":"postgresql://postgres:postgres@localhost:5432/test",
         "RECHNUNG_REDIS_URL":"redis://localhost:6379/0"}
      test-shards: >-
        [{"name":"backend","paths":"tests/test_models.py tests/test_auth.py tests/test_crud.py tests/test_dashboard.py tests/test_audit.py"},
         {"name":"integration","paths":"tests/integration/"},
         {"name":"pdf-import","paths":"tests/test_pdfs.py tests/test_importers.py"},
         {"name":"migration","paths":"tests/test_migrations.py tests/test_backup.py"}]
```

**Notes:**
- Current CI uses dynamic postgres port (`job.services.postgres.ports[5432]`); `reusable-ci.yml` maps `5432:5432` (fixed) → hardcoded URL works.
- `deploy-prod: false` → no prod push/verify until LXC-103 upgrade complete.
- `staging-url` set → `verify-staging` will poll staging after docker push on `dev` pushes.

### 4.3 RecyclageApp

**Current CI:** 1758 lines (largest), monolithic pytest, frontend, multi-arch, has DAST/load-test configured but requires live staging URL.

**Test split:** current single-job pytest → 4 shards by area.

```yaml
    with:
      app-name: recyclingapp
      has-frontend: true
      frontend-dir: frontend
      install-system-deps: true
      multi-arch: true
      enable-dast: false
      enable-load-test: false
      staging-url: ""
      prod-url: ""
      deploy-prod: true
      coverage-threshold: 30
      test-env: >-
        {"RECYCLING_AUTH_PASSWORD":"test123",
         "RECYCLING_PRODUCTION":"",
         "DATABASE_URL":"postgresql://postgres:postgres@localhost:5432/test"}
      test-shards: >-
        [{"name":"models","paths":"tests/test_database.py tests/test_database_slips.py tests/test_database_system_alerts.py tests/test_auth.py"},
         {"name":"routes","paths":"tests/test_auth_routes.py tests/test_companies_routes.py tests/test_closures_routes.py tests/test_credit_notes_routes.py"},
         {"name":"importers","paths":"tests/test_credit_note_parser.py tests/test_bulk.py tests/test_cross_company_duplicates.py"},
         {"name":"integration","paths":"tests/services/"}]
```

**Notes:**
- Splits the monolithic test job into 4 shards by responsibility (models/routes/importers/integration).
- `enable-dast: false` and `staging-url: ""` until staging URL is configured → DAST and load-test skip.
- `monitor.yml` (Metall-Preis-Freshness) stays bespoke in the app repo — not replaced.
- `multi-arch: true` → `linux/amd64,linux/arm64` build (existing behavior preserved).
- Frontend coverage gate uses `reusable-frontend.yml` (eslint+vitest+build).

### 4.4 MitarbeiterApp

**Current CI:** 305 lines (smallest), frontend (no committed lockfile), runner-label repo variable, staging/prod behind `*_DEPLOYED` repo-vars.

**Prerequisite (BLOCKER):** `frontend/package-lock.json` MUST be committed before the thin caller is added. Without it, `reusable-frontend.yml` will try `npm ci` (which requires a lockfile) and the entire CI will fail at startup. The lockfile commit MUST land on `dev` and CI must be green before the `build.yml` replacement commit is added.

```yaml
    with:
      app-name: mitarbeiter-app
      has-frontend: true
      frontend-dir: frontend
      coverage-threshold: 50
      deploy-prod: false
      staging-url: ""
      prod-url: ""
      runner-label: ${{ vars.RUNNER_LABEL || '["ubuntu-latest"]' }}
      test-env: '{"MITARBEITER_TESTING":"1"}'
      test-shards: '[{"name":"backend","paths":"tests/"}]'
```

**Notes:**
- **Lockfile commit is step 1** of the migration: `cd frontend && npm install` then commit `package-lock.json` (enables `npm ci` in `reusable-frontend.yml`).
- `runner-label` uses repo variable with fallback to self-hosted (preserves existing toggle behavior).
- `deploy-prod: false` + empty URLs → deploy-tail skips.
- The `vars.*_DEPLOYED` toggle from the current CI is simplified away — the thin caller handles this via `staging-url`/`prod-url` inputs (empty = skip).

---

## 5. What Stays (Not Replaced)

| File | App | Reason |
|---|---|---|
| `branch-discipline.yml` | all | Per-app enforcement, stays |
| `dependabot.yml` | all | Per-app, stays |
| `security-weekly.yml` | all | Can be thinned later to call `reusable-security-weekly.yml@v1`; not in this migration |
| `labeler.yml` | Rechnungsapp | Stays |
| `monitor.yml` | RecyclageApp | Bespoke metal-price freshness check |
| `release.yml` | RecyclageApp | Can be thinned to `reusable-release.yml@v1` later |

---

## 6. Validation Per App

1. **dev push** → CI runs on self-hosted (LXC-104) or ubuntu-latest (MitarbeiterApp fallback)
2. **Green criteria per app:**
   - FootballApp: all 6 shards pass + coverage ≥50% + docker build succeeds
   - Rechnungsapp: all 4 shards pass + coverage ≥49% + docker build succeeds
   - RecyclageApp: all 4 NEW shards pass (monolithic split into 4 — each new shard passes individually) + coverage ≥30% + docker build succeeds + frontend lane green
   - MitarbeiterApp: backend shard passes + coverage ≥50% + frontend lane green (after lockfile commit)
3. **Regression check:** compare total tests collected vs current CI. If count drops significantly, a shard path is misconfigured.
4. `dev→main` merge after green
5. Watchtower deploys new image on next poll (unchanged deployment mechanics)

**Activating staging-url/prod-url later (post-migration):** Update `build.yml` on `dev` to set the URL value, e.g. `staging-url: "https://i-app.adza-group.ch"`. This is a 1-line edit in the thin caller — no other CI changes needed.

**Coverage note:** Rechnungsapp uses `coverage-threshold: 49` (not 50) — the current CI has a slightly lower threshold from historical context.

---

## 7. Known Risks

| Risk | Mitigation |
|---|---|
| RecyclageApp test split causes coverage drop | Run with `coverage-threshold: 30` initially (matches current CI), raise later |
| FootballApp postgres service overhead | ~15s per shard, not blocking |
| MitarbeiterApp lockfile pins older packages | `npm audit` will flag — acceptable for initial migration |
| Rechnungsapp DATABASE_URL port change (dynamic→fixed) | postgres service always binds 5432:5432 in reusable-ci; should be transparent |
| RecyclageApp `vars.RUNNER_LABEL` pattern dropped | Replaced by `runner-label` input — behavior equivalent |

---

## 8. Out of Scope

- Activating `enable-dast`, `enable-load-test`, `staging-url`/`prod-url` for apps that don't have them set (post-migration task per app)
- Thinning `security-weekly.yml` to call `reusable-security-weekly.yml@v1`
- Thinning `release.yml` (RecyclageApp) to `reusable-release.yml@v1`
- FootballApp staging LXC setup
- Rechnungsapp `deploy-prod: true` (blocked by LXC-103 upgrade)
