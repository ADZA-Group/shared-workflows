# FootballApp — Thin-Caller Migration (P4) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace FootballApp's 1358-line `build.yml` with a ~30-line thin caller of `adza-group/shared-workflows/reusable-ci.yml@v1`, keeping the same 6 test shards.

**Architecture:** Single file replacement on `dev` branch. CI validates on self-hosted LXC-104. Dev→main merge after green. FootballApp uses SQLite in-memory — the postgres service started by reusable-ci is unused (harmless overhead ~15s/shard).

**Tech Stack:** GitHub Actions YAML, gh CLI, git

---

### Preflight

```bash
cd /c/Users/ADZArecaclage/Documents/Projekte/FootballApp
git checkout dev
git pull origin dev
git log --oneline -3
```

---

### Task 1: Replace build.yml with thin caller

**Files:**
- Replace: `.github/workflows/build.yml` (1358 lines → ~50 lines)

- [ ] **Step 1: Overwrite build.yml with the thin caller**

Create `.github/workflows/build.yml` with this exact content:

```yaml
# ═══════════════════════════════════════════════════════════════
# FootballApp CI/CD — Thin caller for adza-group/shared-workflows
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
  issues: write
  pull-requests: write

jobs:
  ci:
    uses: adza-group/shared-workflows/.github/workflows/reusable-ci.yml@v1
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
    secrets: inherit
```

- [ ] **Step 2: Verify the file is correct**

```bash
wc -l .github/workflows/build.yml
```
Expected: ~55 lines (was 1358).

```bash
grep "reusable-ci.yml@v1" .github/workflows/build.yml
```
Expected: one matching line.

- [ ] **Step 3: Commit**

```bash
NAME=$(git log -1 --format='%an'); EMAIL=$(git log -1 --format='%ae')
git add .github/workflows/build.yml
git -c user.name="$NAME" -c user.email="$EMAIL" commit -m "$(cat <<'EOF'
ci: migrate to shared-workflows reusable-ci.yml@v1 (P4 thin caller)

Replaces 1358-line monolithic build.yml with ~50-line thin caller.
Same 6 test shards (smoke/models/auth/routes/importers/ml), SQLite.
All CI logic now in adza-group/shared-workflows@v1.

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

- [ ] **Step 2: Watch the CI run**

```bash
sleep 10
gh run list --branch dev --limit 3 --json databaseId,name,status,workflowName
```

Find the "CI/CD" run ID, then:
```bash
gh run watch <RUN_ID> --exit-status
```

Expected runtime: ~10-20 min (6 shards in parallel on self-hosted).

**Expected green jobs:** Detect Changes, Lint (ruff), Security (gitleaks/bandit/semgrep/trivy/pip-audit/CodeQL/OPA), Test×6 shards, Coverage Gate, Test Results, Docker Build, Telemetry.

**Expected skipped jobs:** Frontend (has-frontend:false), Mutation (no Python changes vs main on initial push), Verify Staging/Prod (staging-url:""), Commit Lint (not a PR), Dependency Review (not a PR), Notify (no failures).

- [ ] **Step 3: If a shard FAILS — diagnose**

```bash
gh run view <RUN_ID> --log-failed 2>&1 | head -80
```

Common causes:
- **`ModuleNotFoundError`** → `requirements.txt` install issue; check `install-system-deps` is false (correct for FootballApp)
- **Test file not found** → path typo in `test-shards`; fix the path in `build.yml`
- **Coverage below 50%** → normal on first run if only a few shards ran; check that ALL 6 shards passed

- [ ] **Step 4: Count tests collected (regression check)**

```bash
gh run view <RUN_ID> --json jobs --jq '[.jobs[] | select(.name | contains("Test")) | {name, conclusion}]'
```

Expected: 6 test shard jobs, all `"success"`. If any show `"skipped"`, the `if:` condition on `test-matrix` didn't trigger — check that `changes.python` is `true` (it should be since `build.yml` is a `.github/**` file which triggers `ci` filter, which triggers tests).

---

### Task 3: Merge dev→main

- [ ] **Step 1: Confirm CI conclusion**

```bash
gh run list --branch dev --limit 1 --json conclusion --jq '.[0].conclusion'
```
Expected: `"success"`.

- [ ] **Step 2: Merge to main**

```bash
git checkout main
git pull origin main
NAME=$(git log -1 --format='%an'); EMAIL=$(git log -1 --format='%ae')
git -c user.name="$NAME" -c user.email="$EMAIL" merge --no-ff dev -m "$(cat <<'EOF'
chore: P4 — FootballApp migrated to shared-workflows thin caller @v1

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
git push origin main
```

- [ ] **Step 3: Verify main CI runs**

```bash
sleep 10 && gh run list --branch main --limit 2 --json databaseId,name,status
```

Expected: a new CI/CD run triggered by the main push.

- [ ] **Step 4: Return to dev**

```bash
git checkout dev
```

---

**Done. FootballApp CI is now a 50-line thin caller. Zero drift from shared-workflows.**
