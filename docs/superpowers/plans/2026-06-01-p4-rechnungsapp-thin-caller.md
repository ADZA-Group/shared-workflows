# Rechnungsapp — Thin-Caller Migration (P4) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Rechnungsapp's 1552-line `build.yml` with a ~55-line thin caller of `adza-group/shared-workflows/reusable-ci.yml@v1`, preserving 4 test shards, Redis, OCR deps, and `deploy-prod: false` (LXC-103 freeze).

**Architecture:** Single file replacement on `dev`. Uses Postgres (fixed port 5432:5432 in reusable-ci, was dynamic in old CI — same port, different URL format). Redis service enabled. Tesseract/poppler via `install-system-deps`. `deploy-prod: false` keeps prod unchanged.

**Tech Stack:** GitHub Actions YAML, gh CLI, git

---

### Preflight

```bash
cd /c/Users/ADZArecaclage/Documents/Projekte/Rechnungsapp
git checkout dev
git pull origin dev
git log --oneline -3
```

---

### Task 1: Replace build.yml with thin caller

**Files:**
- Replace: `.github/workflows/build.yml` (1552 lines → ~60 lines)

- [ ] **Step 1: Overwrite build.yml with the thin caller**

```yaml
# ═══════════════════════════════════════════════════════════════
# Rechnungsapp CI/CD — Thin caller for adza-group/shared-workflows
# All pipeline logic in shared-workflows/reusable-ci.yml@v1
# Note: deploy-prod: false — LXC-103 prod freeze until Sprint 1R
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
  issues: write
  pull-requests: write

jobs:
  ci:
    uses: adza-group/shared-workflows/.github/workflows/reusable-ci.yml@v1
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
    secrets: inherit
```

- [ ] **Step 2: Verify**

```bash
wc -l .github/workflows/build.yml
grep "reusable-ci.yml@v1" .github/workflows/build.yml
```
Expected: ~60 lines; one match.

- [ ] **Step 3: Commit**

```bash
NAME=$(git log -1 --format='%an'); EMAIL=$(git log -1 --format='%ae')
git add .github/workflows/build.yml
git -c user.name="$NAME" -c user.email="$EMAIL" commit -m "$(cat <<'EOF'
ci: migrate to shared-workflows reusable-ci.yml@v1 (P4 thin caller)

Replaces 1552-line build.yml with ~60-line thin caller.
4 shards: backend/integration/pdf-import/migration.
Postgres (fixed 5432) + Redis + tesseract/poppler. deploy-prod: false.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Push + validate CI on self-hosted

- [ ] **Step 1: Push to dev**

```bash
git push origin dev
```

- [ ] **Step 2: Watch CI run**

```bash
sleep 10
gh run list --branch dev --limit 3 --json databaseId,name,status,workflowName
gh run watch <RUN_ID> --exit-status
```

Expected runtime: ~15-25 min (4 shards + docker build with OCR layers).

**Expected green:** All 4 test shards, Coverage Gate (≥49%), Docker Build, Security jobs, Telemetry.

**Expected skipped:** Frontend (has-frontend:false), Verify Staging (deploy-prod:false → no push event triggers staging verify on dev), Commit Lint (push not PR).

Wait — `staging-url` is set but `deploy-prod: false`. This means the `verify-staging` job has `if: inputs.staging-url != '' && inputs.deploy-prod`. Since `deploy-prod: false`, `verify-staging` will be skipped. Correct.

- [ ] **Step 3: If `pdf-import` shard fails — diagnose**

The pdf-import shard needs `tesseract` and `poppler` which are installed via `install-system-deps: true`. If the shard fails with `tesseract not found`:

```bash
gh run view <RUN_ID> --log-failed 2>&1 | grep -A 5 "pdf-import"
```

If tesseract install failed (network issue on self-hosted), re-push to retry. The `apt-get install` step runs on each shard that uses `setup-python-deps`.

- [ ] **Step 4: If DATABASE_URL-related test fails**

The old CI used dynamic ports (`job.services.postgres.ports[5432]`), new CI uses fixed `5432:5432`. The `RECHNUNG_DATABASE_URL` in `test-env` already points to `localhost:5432`. If any test fails with a connection error, check:

```bash
gh run view <RUN_ID> --log-failed 2>&1 | grep -E "connection|RECHNUNG_DATABASE_URL" | head -10
```

The service always binds `5432:5432` in `reusable-ci.yml` — this should be transparent.

---

### Task 3: Merge dev→main

- [ ] **Step 1: Confirm green**

```bash
gh run list --branch dev --limit 1 --json conclusion --jq '.[0].conclusion'
```
Expected: `"success"`.

- [ ] **Step 2: Merge to main**

```bash
git checkout main && git pull origin main
NAME=$(git log -1 --format='%an'); EMAIL=$(git log -1 --format='%ae')
git -c user.name="$NAME" -c user.email="$EMAIL" merge --no-ff dev -m "$(cat <<'EOF'
chore: P4 — Rechnungsapp migrated to shared-workflows thin caller @v1

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
git push origin main
git checkout dev
```

---

**Done. Rechnungsapp CI is now ~60 lines. deploy-prod stays false until LXC-103 upgrade.**
