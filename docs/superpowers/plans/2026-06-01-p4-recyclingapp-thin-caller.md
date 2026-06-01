# RecyclageApp — Thin-Caller Migration (P4) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace RecyclageApp's 1758-line `build.yml` with a ~55-line thin caller of `adza-group/shared-workflows/reusable-ci.yml@v1`. Uses single `tests/` shard (monolithic → YAGNI, avoids path mismatches). `monitor.yml` stays bespoke.

**Architecture:** Single file replacement. Single shard covers all tests (shard splitting is Phase 2). Frontend lane enabled. `staging-url:""` keeps DAST/load-test disabled until staging LXC is configured. `multi-arch: true` preserved.

**Tech Stack:** GitHub Actions YAML, gh CLI, git

---

### Preflight

```bash
cd /c/Users/ADZArecaclage/Documents/Projekte/RecyclageApp
git checkout dev
git pull origin dev
git log --oneline -3
```

Confirm `monitor.yml` still exists (it must NOT be replaced):
```bash
ls .github/workflows/
```
Expected: `build.yml`, `monitor.yml`, `branch-discipline.yml`, and possibly others.

---

### Task 1: Replace build.yml with thin caller

**Files:**
- Replace: `.github/workflows/build.yml` (1758 lines → ~55 lines)
- Keep unchanged: `.github/workflows/monitor.yml` (bespoke metal-price freshness check)

- [ ] **Step 1: Overwrite build.yml with the thin caller**

```yaml
# ═══════════════════════════════════════════════════════════════
# RecyclageApp CI/CD — Thin caller for adza-group/shared-workflows
# All pipeline logic in shared-workflows/reusable-ci.yml@v1
# Note: monitor.yml (metal-price freshness) stays app-local.
# Note: staging-url="" disables DAST/load-test until LXC configured.
# Note: single shard tests/ — split into sub-shards in Phase 2.
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
      app-name: recyclingapp
      coverage-threshold: 30
      has-frontend: true
      frontend-dir: frontend
      install-system-deps: true
      multi-arch: true
      enable-dast: false
      enable-load-test: false
      staging-url: ""
      prod-url: ""
      deploy-prod: true
      test-env: >-
        {"RECYCLING_AUTH_PASSWORD":"test123",
         "RECYCLING_PRODUCTION":"",
         "DATABASE_URL":"postgresql://postgres:postgres@localhost:5432/test"}
      test-shards: >-
        [{"name":"backend","paths":"tests/"}]
    secrets: inherit
```

- [ ] **Step 2: Verify monitor.yml is untouched**

```bash
ls .github/workflows/monitor.yml && echo "EXISTS — good"
wc -l .github/workflows/build.yml
```
Expected: monitor.yml exists; build.yml ~55 lines.

- [ ] **Step 3: Commit**

```bash
NAME=$(git log -1 --format='%an'); EMAIL=$(git log -1 --format='%ae')
git add .github/workflows/build.yml
git -c user.name="$NAME" -c user.email="$EMAIL" commit -m "$(cat <<'EOF'
ci: migrate to shared-workflows reusable-ci.yml@v1 (P4 thin caller)

Replaces 1758-line build.yml with ~55-line thin caller.
Single shard tests/ (shard splitting = Phase 2). Frontend lane enabled.
Multi-arch preserved. monitor.yml stays bespoke. DAST/load-test deferred.

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

Expected runtime: ~20-30 min (monolithic test suite + multi-arch docker build + frontend).

**Expected green:** Test shard `backend` (all tests), Coverage Gate (≥30%), Frontend lane (eslint+vitest+build), Docker Build (multi-arch amd64+arm64), Security jobs, Telemetry.

**Expected skipped:** DAST (enable-dast:false), Load Test (enable-load-test:false), Verify Staging (staging-url:""), Dependency Review (push, not PR).

- [ ] **Step 3: If frontend lane fails**

Check if `frontend/package-lock.json` exists:
```bash
ls frontend/package-lock.json 2>/dev/null && echo "EXISTS" || echo "MISSING"
```

If MISSING: `reusable-frontend.yml` will warn but use `npm install` instead of `npm ci` (fallback is built-in). The build should still pass with a warning. If it hard-fails, add `package-lock.json`:
```bash
cd frontend && npm install && cd ..
NAME=$(git log -1 --format='%an'); EMAIL=$(git log -1 --format='%ae')
git add frontend/package-lock.json
git -c user.name="$NAME" -c user.email="$EMAIL" commit -m "ci: add frontend package-lock.json for npm ci

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>"
git push origin dev
```

- [ ] **Step 4: If test count drops significantly**

```bash
gh run view <RUN_ID> --json jobs --jq '[.jobs[] | select(.name | contains("backend")) | .steps[] | select(.name | contains("pytest") or contains("Run")) | {name, conclusion}]'
```

If tests are missing, it likely means a `conftest.py` import fails for some test areas. Check:
```bash
gh run view <RUN_ID> --log-failed 2>&1 | grep "ERROR\|ImportError\|ModuleNotFound" | head -20
```

- [ ] **Step 5: Coverage below 30% — emergency fallback**

If coverage gate fails (<30%), lower the threshold temporarily:
```yaml
coverage-threshold: 1   # temporary, raise after diagnosis
```
Commit, push, re-watch. Once tests pass, diagnose missing coverage and raise threshold.

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
chore: P4 — RecyclageApp migrated to shared-workflows thin caller @v1

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
git push origin main
git checkout dev
```

---

**Done. RecyclageApp CI is now ~55 lines. monitor.yml bespoke stays. DAST/load-test activate when staging LXC is configured.**
