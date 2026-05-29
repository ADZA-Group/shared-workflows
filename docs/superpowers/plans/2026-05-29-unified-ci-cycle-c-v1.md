# Unified CI — Cycle C: Fixes + v1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the docker-only gate bug, add dependabot.yml, validate on ubuntu, then ship the first consumable `v1` by merging dev→main.

**Architecture:** Two targeted edits (one-line `if:` fix in `reusable-ci.yml`, new `dependabot.yml`), ubuntu smoke validation via existing `_smoke-ci.yml`, then the first dev→main merge and `v1`/`v1.0` annotated tags.

**Tech Stack:** GitHub Actions YAML, actionlint (`bin/actionlint.exe`), yamllint, git, gh CLI

---

### Preflight

```bash
cd /c/Users/ADZArecaclage/Documents/Projekte/shared-workflows
git checkout dev
git pull origin dev
# Confirm starting point:
git log --oneline -3
```

---

### Task 1: Fix docker-only gate in `reusable-ci.yml`

**Files:**
- Modify: `.github/workflows/reusable-ci.yml` (`docker-build` job `if:` line)

The `docker-build` job's `if:` requires `needs.test-matrix.result == 'success'`. When only Dockerfile changes (no `.py`, no `.github`), `test-matrix` is skipped → `docker-build` is also skipped → image never rebuilt. Fix: accept both `'success'` and `'skipped'` on `test-matrix`.

- [ ] **Step 1: Locate the current condition**

```bash
grep -n "needs.test-matrix.result" .github/workflows/reusable-ci.yml
```
Expected: one line around L255 containing `== 'success'`.

- [ ] **Step 2: Replace the `if:` condition**

Find this exact block (the `docker-build` job's `if:`):
```yaml
    if: ${{ always() && needs.lint-python.result != 'failure' && needs.test-matrix.result == 'success' && (needs.changes.outputs.any_code == 'true' || needs.changes.outputs.ci == 'true') }}
```

Replace with:
```yaml
    if: >-
      ${{ always() &&
      needs.lint-python.result != 'failure' &&
      (needs.test-matrix.result == 'success' || needs.test-matrix.result == 'skipped') &&
      (needs.changes.outputs.any_code == 'true' || needs.changes.outputs.docker == 'true' || needs.changes.outputs.ci == 'true') }}
```

- [ ] **Step 3: Validate with actionlint**

```bash
./bin/actionlint.exe .github/workflows/reusable-ci.yml
```
Expected: exit 0, zero errors printed.

- [ ] **Step 4: Also run yamllint**

```bash
python -m yamllint -d relaxed .github/workflows/reusable-ci.yml
```
Expected: no errors (warnings OK).

- [ ] **Step 5: Commit**

```bash
NAME=$(git log -1 --format='%an'); EMAIL=$(git log -1 --format='%ae')
git add .github/workflows/reusable-ci.yml
git -c user.name="$NAME" -c user.email="$EMAIL" commit -m "$(cat <<'EOF'
fix(ci): accept skipped test-matrix in docker-build gate

Pure Dockerfile commits (no .py changes) caused test-matrix to skip,
which cascaded into docker-build also skipping — image never rebuilt.
Fix: accept both success and skipped on test-matrix; also add docker
to the any_code gate so pure-docker commits trigger the build.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Add `.github/dependabot.yml`

**Files:**
- Create: `.github/dependabot.yml`

Weekly SHA-pin bumps for all GitHub Actions in the repo, PRs targeting `dev`, grouped so they come as one PR.

- [ ] **Step 1: Create the file**

```yaml
# .github/dependabot.yml
version: 2
updates:
  - package-ecosystem: github-actions
    directory: /
    schedule:
      interval: weekly
      day: monday
    target-branch: dev
    labels:
      - dependencies
      - github-actions
    open-pull-requests-limit: 10
    groups:
      actions:
        patterns:
          - "*"
```

- [ ] **Step 2: Validate YAML**

```bash
python -m yamllint -d relaxed .github/dependabot.yml
```
Expected: no errors.

- [ ] **Step 3: Commit**

```bash
NAME=$(git log -1 --format='%an'); EMAIL=$(git log -1 --format='%ae')
git add .github/dependabot.yml
git -c user.name="$NAME" -c user.email="$EMAIL" commit -m "$(cat <<'EOF'
ci: add dependabot.yml — weekly SHA-pin bumps targeting dev

Central pin-bump automation for all SHA-pinned actions in this repo.
PRs land on dev (not main) and are grouped into one PR per week.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Validate on ubuntu via `_smoke-ci.yml`

- [ ] **Step 1: Add temp push trigger to `_smoke-ci.yml`**

Open `.github/workflows/_smoke-ci.yml`. Current `on:` block:
```yaml
on:
  workflow_dispatch:
```

Change to:
```yaml
on:
  workflow_dispatch:
  push:
    branches: [dev]
```

- [ ] **Step 2: Commit temp trigger**

```bash
NAME=$(git log -1 --format='%an'); EMAIL=$(git log -1 --format='%ae')
git add .github/workflows/_smoke-ci.yml
git -c user.name="$NAME" -c user.email="$EMAIL" commit -m "ci(smoke): temp push trigger for Cycle C ubuntu validation [revert after green]

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>"
```

- [ ] **Step 3: Push and watch**

```bash
git push origin dev
# Get run ID (wait ~5s for it to register):
gh run list --branch dev --limit 5 --json databaseId,name,status
```
Find the "🧪 Smoke — CI Orchestrator" run ID, then:
```bash
gh run watch <RUN_ID> --exit-status
```
Expected: all jobs green, command exits 0.

- [ ] **Step 4: If any job failed — diagnose**

```bash
gh run view <RUN_ID> --log-failed 2>&1 | head -80
```
Fix the issue, commit, push again, re-watch.

- [ ] **Step 5: Remove temp trigger (smoke is workflow_dispatch-only)**

Revert `.github/workflows/_smoke-ci.yml` `on:` back to:
```yaml
on:
  workflow_dispatch:
```

Commit:
```bash
NAME=$(git log -1 --format='%an'); EMAIL=$(git log -1 --format='%ae')
git add .github/workflows/_smoke-ci.yml
git -c user.name="$NAME" -c user.email="$EMAIL" commit -m "ci(smoke): revert temp push trigger — Cycle C validated green on ubuntu

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>"
git push origin dev
```

---

### Task 4: Merge dev→main + publish v1 / v1.0 tags

- [ ] **Step 1: Confirm dev CI is clean**

```bash
gh run list --branch dev --limit 1 --json status,conclusion --jq '.[0]'
```
Expected: `"conclusion": "success"`.

- [ ] **Step 2: Push any remaining local commits**

```bash
git push origin dev
```

- [ ] **Step 3: Merge to main**

```bash
git checkout main
git pull origin main
NAME=$(git log -1 --format='%an'); EMAIL=$(git log -1 --format='%ae')
git -c user.name="$NAME" -c user.email="$EMAIL" merge --no-ff dev -m "$(cat <<'EOF'
chore: Cycle C — docker-only gate fix + dependabot → v1

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 4: Create annotated tags**

```bash
NAME=$(git log -1 --format='%an'); EMAIL=$(git log -1 --format='%ae')
git -c user.name="$NAME" -c user.email="$EMAIL" \
  tag -a v1.0 -m "ci: v1.0 — docker-only gate fix + dependabot"
git -c user.name="$NAME" -c user.email="$EMAIL" \
  tag -a v1 -m "chore: v1 (floating, currently = v1.0) — first consumable release; will be re-tagged to v1.1/v1.2 in later cycles"
```

- [ ] **Step 5: Push main + tags**

```bash
git push origin main
git push origin v1.0 v1
```

- [ ] **Step 6: Verify tags are visible on GitHub**

```bash
git ls-remote origin 'refs/tags/v1*'
```
Expected output contains both `refs/tags/v1` and `refs/tags/v1.0`.

- [ ] **Step 7: Return to dev for next cycle**

```bash
git checkout dev
```

---

**Cycle C done. Apps can now pin `@v1`.**
Next: run Cycle A plan (`2026-05-29-unified-ci-cycle-a-v1.1.md`).
