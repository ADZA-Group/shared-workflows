# MitarbeiterApp — Thin-Caller Migration (P4) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace MitarbeiterApp's 305-line `build.yml` with a ~50-line thin caller of `adza-group/shared-workflows/reusable-ci.yml@v1`. BLOCKER: `frontend/package-lock.json` must be committed first (Task 1) or `npm ci` fails.

**Architecture:** Two commits: (1) lockfile, (2) thin caller. Frontend lane enabled. Runner-label via repo variable with ubuntu-latest fallback (preserves existing toggle). Single backend shard.

**Tech Stack:** GitHub Actions YAML, npm, gh CLI, git

---

### Preflight

```bash
cd /c/Users/ADZArecaclage/Documents/Projekte/MitarbeiterApp
git checkout dev
git pull origin dev
git log --oneline -3

# Verify Node is available:
node --version && npm --version
```

---

### Task 1: Generate + commit frontend/package-lock.json (BLOCKER)

**Files:**
- Create: `frontend/package-lock.json`

This is a hard prerequisite. Without it, `reusable-frontend.yml` will use `npm ci` which requires a lockfile and will fail.

- [ ] **Step 1: Generate lockfile**

```bash
cd frontend
npm install
cd ..
```

Expected: `frontend/package-lock.json` created (typically 10k–100k lines).

- [ ] **Step 2: Verify lockfile exists**

```bash
ls -lh frontend/package-lock.json
head -5 frontend/package-lock.json
```
Expected: file exists, starts with `{"name":...`.

- [ ] **Step 3: Commit lockfile**

```bash
NAME=$(git log -1 --format='%an'); EMAIL=$(git log -1 --format='%ae')
git add frontend/package-lock.json
git -c user.name="$NAME" -c user.email="$EMAIL" commit -m "$(cat <<'EOF'
build(frontend): add package-lock.json for reproducible npm ci installs

Required for reusable-frontend.yml (npm ci requires committed lockfile).

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 4: Push lockfile and verify no CI failures**

```bash
git push origin dev
sleep 10
gh run list --branch dev --limit 2 --json databaseId,name,status
```

The lockfile push will trigger the CURRENT (old) CI. If the old CI runs and passes — good, proceed to Task 2. If it fails for unrelated reasons, investigate before continuing.

---

### Task 2: Replace build.yml with thin caller

**Files:**
- Replace: `.github/workflows/build.yml` (305 lines → ~50 lines)

- [ ] **Step 1: Overwrite build.yml with the thin caller**

```yaml
# ═══════════════════════════════════════════════════════════════
# MitarbeiterApp CI/CD — Thin caller for adza-group/shared-workflows
# All pipeline logic in shared-workflows/reusable-ci.yml@v1
# Runner: set RUNNER_LABEL repo var to '["self-hosted","linux","proxmox"]'
#         for self-hosted; defaults to ubuntu-latest when unset.
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
      app-name: mitarbeiter-app
      coverage-threshold: 50
      has-frontend: true
      frontend-dir: frontend
      deploy-prod: false
      staging-url: ""
      prod-url: ""
      runner-label: ${{ vars.RUNNER_LABEL || '["ubuntu-latest"]' }}
      test-env: '{"MITARBEITER_TESTING":"1"}'
      test-shards: '[{"name":"backend","paths":"tests/"}]'
    secrets: inherit
```

- [ ] **Step 2: Verify**

```bash
wc -l .github/workflows/build.yml
grep "reusable-ci.yml@v1" .github/workflows/build.yml
```
Expected: ~50 lines; one match.

- [ ] **Step 3: Commit**

```bash
NAME=$(git log -1 --format='%an'); EMAIL=$(git log -1 --format='%ae')
git add .github/workflows/build.yml
git -c user.name="$NAME" -c user.email="$EMAIL" commit -m "$(cat <<'EOF'
ci: migrate to shared-workflows reusable-ci.yml@v1 (P4 thin caller)

Replaces 305-line build.yml with ~50-line thin caller.
Frontend lane enabled with committed package-lock.json.
Runner via RUNNER_LABEL repo var (default: ubuntu-latest).

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Push + validate CI

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

Expected runtime: ~10-15 min (ubuntu-latest by default, single backend shard + frontend).

**Expected green:** Test shard `backend`, Coverage Gate (≥50%), Frontend lane (eslint+vitest+build), Docker Build, Security jobs, Telemetry.

**Expected skipped:** Verify Staging (staging-url:""), DAST (enable-dast:false), Mutation (no Python changes vs main), Commit Lint (push not PR).

- [ ] **Step 3: If `MITARBEITER_TESTING` env var not recognized**

If tests fail because the app doesn't check `MITARBEITER_TESTING`:

```bash
gh run view <RUN_ID> --log-failed 2>&1 | grep -i "testing\|config\|env" | head -10
```

The unused env var is harmless — tests should still pass. If the app uses a different env var (e.g. `FLASK_TESTING`, `APP_TESTING`), add it to `test-env` in `build.yml`:
```yaml
      test-env: '{"MITARBEITER_TESTING":"1","FLASK_TESTING":"1"}'
```

- [ ] **Step 4: If frontend fails with missing `typecheck` script**

`reusable-frontend.yml` runs `npm run typecheck` by default. If MitarbeiterApp's `package.json` doesn't have a `typecheck` script:

```bash
grep "typecheck\|tsc" frontend/package.json
```

If missing, set `run-typecheck: false` in the thin caller:
```yaml
      # Add under "with:":
      # run-typecheck: false
```
But first check — the existing CI likely had `tsc -b --noEmit` so the script should exist.

---

### Task 4: Merge dev→main

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
chore: P4 — MitarbeiterApp migrated to shared-workflows thin caller @v1

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
git push origin main
git checkout dev
```

---

**Done. MitarbeiterApp CI is now ~50 lines with committed lockfile. Set `RUNNER_LABEL` repo var to switch to self-hosted anytime.**
