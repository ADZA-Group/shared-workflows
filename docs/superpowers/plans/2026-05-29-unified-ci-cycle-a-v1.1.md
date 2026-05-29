# Unified CI — Cycle A: Orchestrator-Tail (v1.1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring `reusable-ci.yml` to the full spec DAG: full Wave-1 lint suite (hadolint/radon/vulture/todo/licenses/commit-lint), property tests, inline mutation, frontend/load-test wire-ins, deploy-tail (verify-staging/require-staging-green/verify-prod), PR summary, and failure notify.

**Architecture:** All new jobs are added to `.github/workflows/reusable-ci.yml`. `reusable-notify.yml` gets a `runner-label` input so the smoke can override it to ubuntu. No new composite actions needed — new jobs use existing composites + inline bash.

**Tech Stack:** GitHub Actions YAML, actionlint, yamllint, hadolint binary, gh CLI, git

---

### Preflight

```bash
cd /c/Users/ADZArecaclage/Documents/Projekte/shared-workflows
git checkout dev && git pull origin dev
# Confirm v1.0 is already tagged (Cycle C done):
git tag -l 'v1*'
```

---

### Task 1: Fix `reusable-notify.yml` — add `runner-label` input

**Files:**
- Modify: `.github/workflows/reusable-notify.yml`

Currently hardcodes `runs-on: [self-hosted, linux, proxmox]`. Adding a `runner-label` input lets the smoke override to `ubuntu-latest`.

- [ ] **Step 1: Add `runner-label` to workflow_call inputs**

Find the `on: workflow_call:` section. After the existing `secrets:` block (or at the end of `inputs:`), add:
```yaml
      runner-label:
        required: false
        type: string
        default: '["self-hosted", "linux", "proxmox"]'
```

- [ ] **Step 2: Change `runs-on` in the `notify` job**

Find:
```yaml
    runs-on: [self-hosted, linux, proxmox]
```
Replace with:
```yaml
    runs-on: ${{ fromJSON(inputs.runner-label) }}
```

- [ ] **Step 3: Validate**

```bash
./bin/actionlint.exe .github/workflows/reusable-notify.yml
python -m yamllint -d relaxed .github/workflows/reusable-notify.yml
```
Expected: both exit 0.

- [ ] **Step 4: Commit**

```bash
NAME=$(git log -1 --format='%an'); EMAIL=$(git log -1 --format='%ae')
git add .github/workflows/reusable-notify.yml
git -c user.name="$NAME" -c user.email="$EMAIL" commit -m "$(cat <<'EOF'
feat(notify): add runner-label input (default: self-hosted/proxmox)

Allows smoke callers to override to ubuntu-latest for validation
without affecting production callers using the default value.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Add new `workflow_call` inputs to `reusable-ci.yml`

**Files:**
- Modify: `.github/workflows/reusable-ci.yml` (`workflow_call.inputs` section)

- [ ] **Step 1: Add 10 new inputs after the existing `docker-context` input**

In the `on: workflow_call: inputs:` block, append after `docker-context`:
```yaml
      has-frontend:
        required: false
        type: boolean
        default: false
        description: "Enable frontend lane (reusable-frontend.yml)"
      frontend-dir:
        required: false
        type: string
        default: "frontend"
      enable-property-tests:
        required: false
        type: boolean
        default: true
      enable-mutation:
        required: false
        type: boolean
        default: true
      enable-load-test:
        required: false
        type: boolean
        default: false
      staging-url:
        required: false
        type: string
        default: ""
        description: "Staging health-check URL (empty = skip deploy-tail)"
      prod-url:
        required: false
        type: string
        default: ""
        description: "Prod health-check URL (empty = skip verify-prod)"
      deploy-prod:
        required: false
        type: boolean
        default: true
        description: "Master switch for prod push+verify (set false to disable)"
      enable-dast:
        required: false
        type: boolean
        default: false
        description: "Enable DAST scan after staging verify (wired in Cycle B)"
```

- [ ] **Step 2: Validate**

```bash
./bin/actionlint.exe .github/workflows/reusable-ci.yml
```
Expected: exit 0.

- [ ] **Step 3: Commit**

```bash
NAME=$(git log -1 --format='%an'); EMAIL=$(git log -1 --format='%ae')
git add .github/workflows/reusable-ci.yml
git -c user.name="$NAME" -c user.email="$EMAIL" commit -m "feat(ci): add orchestrator-tail inputs (has-frontend, deploy-tail, mutation, etc)

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>"
```

---

### Task 3: Add Wave-1 lint jobs (6 jobs)

**Files:**
- Modify: `.github/workflows/reusable-ci.yml` (add 6 jobs after `lint-python`)

Add these 6 jobs after the closing `---` of the `lint-python` job. All run in parallel with `lint-python` in Wave 1.

- [ ] **Step 1: Add `lint-dockerfile` job**

```yaml
  lint-dockerfile:
    name: "🐳 Lint Dockerfile"
    needs: changes
    if: ${{ needs.changes.outputs.docker == 'true' || needs.changes.outputs.ci == 'true' }}
    runs-on: ${{ fromJSON(inputs.runner-label) }}
    timeout-minutes: 5
    continue-on-error: ${{ !(github.ref == 'refs/heads/main' || startsWith(github.ref, 'refs/tags/')) }}
    steps:
      - uses: actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5  # v4
      - name: Install hadolint v2.12.0
        run: |
          curl -sSfL https://github.com/hadolint/hadolint/releases/download/v2.12.0/hadolint-Linux-x86_64 \
            -o /usr/local/bin/hadolint
          chmod +x /usr/local/bin/hadolint
      - name: Lint
        run: |
          [ -f "${{ inputs.dockerfile }}" ] || { echo "::notice::no Dockerfile at ${{ inputs.dockerfile }} — skipping"; exit 0; }
          hadolint "${{ inputs.dockerfile }}" --format tty
```

- [ ] **Step 2: Add `code-quality` job**

```yaml
  code-quality:
    name: "📊 Code Quality"
    needs: changes
    if: ${{ needs.changes.outputs.python == 'true' || needs.changes.outputs.ci == 'true' }}
    runs-on: ${{ fromJSON(inputs.runner-label) }}
    timeout-minutes: 10
    continue-on-error: true
    steps:
      - uses: actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5  # v4
      - uses: adza-group/shared-workflows/.github/actions/setup-python-deps@dev
        with:
          install-requirements: "false"
          extra-packages: "radon==6.*"
          cache-key-suffix: radon
      - name: Radon complexity
        run: |
          {
            echo "## 📊 Code Quality (radon)"
            echo '```'
            radon cc . -a -nb --exclude "tests,__pycache__,.venv" 2>/dev/null || echo "(no Python source found)"
            echo '```'
          } >> "$GITHUB_STEP_SUMMARY"
          radon cc . -a -nb --exclude "tests,__pycache__,.venv" 2>/dev/null || true
```

- [ ] **Step 3: Add `dead-code` job**

```yaml
  dead-code:
    name: "💀 Dead Code"
    needs: changes
    if: ${{ needs.changes.outputs.python == 'true' || needs.changes.outputs.ci == 'true' }}
    runs-on: ${{ fromJSON(inputs.runner-label) }}
    timeout-minutes: 10
    continue-on-error: true
    steps:
      - uses: actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5  # v4
      - uses: adza-group/shared-workflows/.github/actions/setup-python-deps@dev
        with:
          install-requirements: "false"
          extra-packages: "vulture==2.*"
          cache-key-suffix: vulture
      - name: Vulture scan
        run: |
          {
            echo "## 💀 Dead Code (vulture)"
            echo '```'
            vulture . --min-confidence 80 --exclude tests,__pycache__,.venv 2>/dev/null || echo "(no issues or no source)"
            echo '```'
          } >> "$GITHUB_STEP_SUMMARY"
          vulture . --min-confidence 80 --exclude tests,__pycache__,.venv 2>/dev/null || true
```

- [ ] **Step 4: Add `todo-tracker` job**

```yaml
  todo-tracker:
    name: "📌 TODOs"
    needs: changes
    if: ${{ needs.changes.outputs.python == 'true' || needs.changes.outputs.ci == 'true' }}
    runs-on: ${{ fromJSON(inputs.runner-label) }}
    timeout-minutes: 5
    steps:
      - uses: actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5  # v4
      - name: Count open TODOs
        run: |
          COUNT=$(grep -rn --include="*.py" "TODO\|FIXME\|HACK\|XXX" . 2>/dev/null | grep -v ".venv" | wc -l || echo 0)
          {
            echo "## 📌 TODO Tracker"
            echo "| Metric | Count |"
            echo "|--------|-------|"
            echo "| Open TODO/FIXME/HACK/XXX | ${COUNT} |"
          } >> "$GITHUB_STEP_SUMMARY"
          if [ "$COUNT" -gt 0 ]; then
            {
              echo ""
              echo "<details><summary>Show items</summary>"
              echo ""
              echo '```'
              grep -rn --include="*.py" "TODO\|FIXME\|HACK\|XXX" . 2>/dev/null | grep -v ".venv" | head -50
              echo '```'
              echo "</details>"
            } >> "$GITHUB_STEP_SUMMARY"
          fi
```

- [ ] **Step 5: Add `license-check` job**

```yaml
  license-check:
    name: "⚖️ Licenses"
    needs: changes
    if: ${{ needs.changes.outputs.python == 'true' || needs.changes.outputs.ci == 'true' }}
    runs-on: ${{ fromJSON(inputs.runner-label) }}
    timeout-minutes: 10
    continue-on-error: ${{ !(github.ref == 'refs/heads/main' || startsWith(github.ref, 'refs/tags/')) }}
    steps:
      - uses: actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5  # v4
      - uses: adza-group/shared-workflows/.github/actions/setup-python-deps@dev
        with:
          install-requirements: "true"
          extra-packages: "pip-licenses==4.*"
          cache-key-suffix: licenses
      - name: Check for copyleft
        run: |
          COPYLEFT="GPL-2.0-only,GPL-2.0-or-later,GPL-3.0-only,GPL-3.0-or-later,LGPL-2.1-only,LGPL-2.1-or-later,LGPL-3.0-only,LGPL-3.0-or-later,AGPL-3.0-only,AGPL-3.0-or-later"
          pip-licenses --format=markdown >> "$GITHUB_STEP_SUMMARY" 2>/dev/null || true
          pip-licenses --fail-on="$COPYLEFT" 2>&1 || {
            echo "::error::Copyleft license detected in dependencies"
            exit 1
          }
```

- [ ] **Step 6: Add `commit-lint` job (PR-only)**

```yaml
  commit-lint:
    name: "📝 Commit Lint"
    needs: changes
    if: ${{ github.event_name == 'pull_request' }}
    runs-on: ${{ fromJSON(inputs.runner-label) }}
    timeout-minutes: 5
    continue-on-error: true
    steps:
      - name: Check PR title (Conventional Commits)
        env:
          PR_TITLE: ${{ github.event.pull_request.title }}
        run: |
          PATTERN='^(feat|fix|docs|chore|ci|test|refactor|style|perf|revert)(\(.+\))?: .+'
          if ! echo "$PR_TITLE" | grep -Eq "$PATTERN"; then
            echo "::warning::PR title does not follow Conventional Commits: '$PR_TITLE'"
            echo "Expected format: <type>(scope): description"
            echo "Valid types: feat fix docs chore ci test refactor style perf revert"
          else
            echo "✅ PR title follows Conventional Commits: '$PR_TITLE'"
          fi
```

- [ ] **Step 7: Validate all 6 new jobs**

```bash
./bin/actionlint.exe .github/workflows/reusable-ci.yml
python -m yamllint -d relaxed .github/workflows/reusable-ci.yml
```
Expected: both exit 0.

- [ ] **Step 8: Commit**

```bash
NAME=$(git log -1 --format='%an'); EMAIL=$(git log -1 --format='%ae')
git add .github/workflows/reusable-ci.yml
git -c user.name="$NAME" -c user.email="$EMAIL" commit -m "$(cat <<'EOF'
feat(ci): add Wave-1 lint suite — hadolint/radon/vulture/todos/licenses/commit-lint

6 new parallel jobs in Wave 1. All advisory on PR/dev, blocking on main/tag
(except todo-tracker and commit-lint which are always advisory).

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Add Wave-2 `property-tests` + inline `mutation`

**Files:**
- Modify: `.github/workflows/reusable-ci.yml` (add 2 jobs after `test-matrix`)

- [ ] **Step 1: Add `property-tests` job (after `test-matrix`, before `coverage`)**

```yaml
  property-tests:
    name: "🔬 Property Tests"
    needs: changes
    if: ${{ inputs.enable-property-tests && (needs.changes.outputs.python == 'true' || needs.changes.outputs.ci == 'true') }}
    runs-on: ${{ fromJSON(inputs.runner-label) }}
    timeout-minutes: 15
    continue-on-error: true
    steps:
      - uses: actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5  # v4
      - uses: adza-group/shared-workflows/.github/actions/setup-python-deps@dev
        with:
          install-requirements: "true"
          extra-packages: "hypothesis==6.*"
          cache-key-suffix: hypothesis
      - name: Run Hypothesis tests
        run: |
          COUNT=$(pytest tests/ -m "hypothesis" --collect-only -q 2>/dev/null | grep -oE '[0-9]+ test' | cut -d' ' -f1 || echo 0)
          if [ "${COUNT:-0}" -eq 0 ]; then
            echo "::notice::no @hypothesis.given tests found — skipping"
            exit 0
          fi
          pytest tests/ -m "hypothesis" --hypothesis-seed=0 --timeout=60 -p no:cacheprovider
```

- [ ] **Step 2: Add `mutation` job (inline incremental, after `coverage`)**

```yaml
  mutation:
    name: "🧬 Mutation (incremental)"
    needs: [changes, test-matrix]
    if: ${{ inputs.enable-mutation && needs.test-matrix.result == 'success' && needs.changes.outputs.python == 'true' }}
    runs-on: ${{ fromJSON(inputs.runner-label) }}
    timeout-minutes: 20
    continue-on-error: true
    steps:
      - uses: actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5  # v4
        with:
          fetch-depth: 0
      - uses: adza-group/shared-workflows/.github/actions/setup-python-deps@dev
        with:
          install-requirements: "true"
          extra-packages: "mutmut==2.*"
          cache-key-suffix: mutmut
      - name: Get changed non-test Python files
        id: changed
        run: |
          FILES=$(git diff --name-only origin/main...HEAD -- '*.py' 2>/dev/null \
            | grep -v '/test' | grep -v '^tests/' | head -20 \
            | tr '\n' ' ' | xargs || echo "")
          echo "files=${FILES}" >> "$GITHUB_OUTPUT"
      - name: Run mutmut incremental
        run: |
          FILES="${{ steps.changed.outputs.files }}"
          if [ -z "${FILES}" ]; then
            echo "::notice::no non-test Python changes vs main — skipping mutation"
            exit 0
          fi
          mutmut run --paths-to-mutate "${FILES}" || true
          SURVIVED=$(mutmut results 2>/dev/null | grep -c "survived" || echo 0)
          {
            echo "## 🧬 Mutation Testing (incremental)"
            echo "| Metric | Value |"
            echo "|--------|-------|"
            echo "| Surviving mutants | ${SURVIVED} |"
            echo "| Mutated files | \`${FILES}\` |"
            echo "| Mode | incremental (non-test changes vs main) |"
          } >> "$GITHUB_STEP_SUMMARY"
```

- [ ] **Step 3: Validate**

```bash
./bin/actionlint.exe .github/workflows/reusable-ci.yml
```
Expected: exit 0.

- [ ] **Step 4: Commit**

```bash
NAME=$(git log -1 --format='%an'); EMAIL=$(git log -1 --format='%ae')
git add .github/workflows/reusable-ci.yml
git -c user.name="$NAME" -c user.email="$EMAIL" commit -m "$(cat <<'EOF'
feat(ci): add property-tests (hypothesis) + mutation (mutmut incremental)

Both advisory always. Mutation only runs on non-test Python file changes
vs main. Zero-hypothesis-test repos skip cleanly.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Wire in `reusable-frontend` (Wave 2)

**Files:**
- Modify: `.github/workflows/reusable-ci.yml` (add `frontend` job after `changes`)

- [ ] **Step 1: Add `frontend` wire-in job (after `changes`, before `lint-python`)**

```yaml
  frontend:
    name: "🎨 Frontend"
    needs: changes
    if: ${{ inputs.has-frontend && (needs.changes.outputs.frontend == 'true' || needs.changes.outputs.ci == 'true') }}
    permissions:
      contents: read
    uses: adza-group/shared-workflows/.github/workflows/reusable-frontend.yml@dev
    with:
      frontend-dir: ${{ inputs.frontend-dir }}
      runner-label: '["ubuntu-latest"]'
    secrets: inherit
```

- [ ] **Step 2: Validate**

```bash
./bin/actionlint.exe .github/workflows/reusable-ci.yml
```
Expected: exit 0.

- [ ] **Step 3: Commit**

```bash
NAME=$(git log -1 --format='%an'); EMAIL=$(git log -1 --format='%ae')
git add .github/workflows/reusable-ci.yml
git -c user.name="$NAME" -c user.email="$EMAIL" commit -m "feat(ci): wire reusable-frontend into orchestrator (has-frontend gate)

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>"
```

---

### Task 6: Add deploy-tail (Wave 5) — verify-staging + require-staging-green + verify-prod

**Files:**
- Modify: `.github/workflows/reusable-ci.yml` (add 3 jobs after `docker-build`)

All three jobs are gated behind `inputs.staging-url != ''` — when staging-url is empty (ubuntu smoke), all are skipped gracefully.

- [ ] **Step 1: Add `verify-staging` job**

```yaml
  verify-staging:
    name: "🔍 Verify Staging"
    needs: [docker-build]
    if: >-
      ${{ always() && inputs.staging-url != '' && inputs.deploy-prod &&
      needs.docker-build.result == 'success' &&
      github.event_name == 'push' }}
    runs-on: ${{ fromJSON(inputs.runner-label) }}
    timeout-minutes: 25
    steps:
      - uses: actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5  # v4
      - uses: adza-group/shared-workflows/.github/actions/health-check@dev
        with:
          url: ${{ inputs.staging-url }}
          max-retries: "40"
          retry-delay: "30"
          check-security-headers: "true"
```

- [ ] **Step 2: Add `require-staging-green` job**

```yaml
  require-staging-green:
    name: "🚦 Require Staging Green"
    needs: [verify-staging]
    if: >-
      ${{ always() && inputs.staging-url != '' &&
      github.ref == 'refs/heads/main' }}
    runs-on: ${{ fromJSON(inputs.runner-label) }}
    timeout-minutes: 5
    steps:
      - name: Gate on staging health
        run: |
          if [ "${{ needs.verify-staging.result }}" != "success" ]; then
            echo "::error::staging not green (result: ${{ needs.verify-staging.result }}) — blocking main push"
            exit 1
          fi
          echo "✅ staging verified green — prod push allowed"
```

- [ ] **Step 3: Add `verify-prod` job**

```yaml
  verify-prod:
    name: "✅ Verify Prod"
    needs: [docker-build, require-staging-green]
    if: >-
      ${{ always() && inputs.prod-url != '' && inputs.deploy-prod &&
      needs.docker-build.result == 'success' &&
      github.ref == 'refs/heads/main' }}
    runs-on: ${{ fromJSON(inputs.runner-label) }}
    timeout-minutes: 25
    permissions:
      contents: read
      issues: write
    steps:
      - uses: actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5  # v4
      - uses: adza-group/shared-workflows/.github/actions/health-check@dev
        id: prod-check
        continue-on-error: true
        with:
          url: ${{ inputs.prod-url }}
          max-retries: "40"
          retry-delay: "30"

      - name: Auto-rollback on failure
        if: steps.prod-check.outcome == 'failure'
        run: |
          IMAGE="${{ inputs.image-name != '' && inputs.image-name || format('ghcr.io/adza-group/{0}', inputs.app-name) }}"
          echo "::warning::prod unhealthy — attempting rollback :previous → :latest"
          if docker buildx imagetools inspect "${IMAGE}:previous" >/dev/null 2>&1; then
            docker buildx imagetools create --tag "${IMAGE}:latest" "${IMAGE}:previous"
            echo "::warning::rollback applied — watchtower will re-deploy :previous on next poll"
          else
            echo "::warning::no :previous tag found — rollback skipped"
          fi

      - name: Open incident issue on failure
        if: steps.prod-check.outcome == 'failure'
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          gh issue create \
            --title "🚨 Prod verify failed — ${{ inputs.app-name }} @ ${GITHUB_SHA:0:7}" \
            --body "## Prod health check failed

  App: \`${{ inputs.app-name }}\`
  URL: ${{ inputs.prod-url }}
  SHA: ${{ github.sha }}
  Run: ${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }}" \
            --label "incident,production" || true

      - name: Fail on prod unhealthy
        if: steps.prod-check.outcome == 'failure'
        run: exit 1
```

- [ ] **Step 4: Validate**

```bash
./bin/actionlint.exe .github/workflows/reusable-ci.yml
```
Expected: exit 0.

- [ ] **Step 5: Commit**

```bash
NAME=$(git log -1 --format='%an'); EMAIL=$(git log -1 --format='%ae')
git add .github/workflows/reusable-ci.yml
git -c user.name="$NAME" -c user.email="$EMAIL" commit -m "$(cat <<'EOF'
feat(ci): add deploy-tail — verify-staging/require-green/verify-prod + rollback

All behind staging-url != '' gate (empty = skip, safe for smoke/build-only callers).
verify-prod: health-check + auto-rollback :previous→:latest + auto issue on fail.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: Wire in `reusable-load-test` (Wave 5)

**Files:**
- Modify: `.github/workflows/reusable-ci.yml` (add `load-test` job after `verify-staging`)

- [ ] **Step 1: Add `load-test` wire-in**

```yaml
  load-test:
    name: "📈 Load Test"
    needs: [verify-staging]
    if: >-
      ${{ always() && inputs.enable-load-test && inputs.staging-url != '' &&
      needs.verify-staging.result == 'success' }}
    permissions:
      contents: read
    uses: adza-group/shared-workflows/.github/workflows/reusable-load-test.yml@dev
    with:
      target-url: ${{ inputs.staging-url }}
      blocking: false
      runner-label: ${{ inputs.runner-label }}
    secrets: inherit
```

- [ ] **Step 2: Validate**

```bash
./bin/actionlint.exe .github/workflows/reusable-ci.yml
```
Expected: exit 0.

- [ ] **Step 3: Commit**

```bash
NAME=$(git log -1 --format='%an'); EMAIL=$(git log -1 --format='%ae')
git add .github/workflows/reusable-ci.yml
git -c user.name="$NAME" -c user.email="$EMAIL" commit -m "feat(ci): wire reusable-load-test into orchestrator (enable-load-test + staging-url gate)

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>"
```

---

### Task 8: Add `pr-summary` + `notify` top-level jobs (Wave 6)

**Files:**
- Modify: `.github/workflows/reusable-ci.yml` (add 2 jobs after `telemetry`)

- [ ] **Step 1: Add `pr-summary` job (after `telemetry`)**

```yaml
  pr-summary:
    name: "📝 PR Summary"
    needs: [lint-python, security, test-matrix, coverage, docker-build]
    if: ${{ always() && github.event_name == 'pull_request' }}
    runs-on: ${{ fromJSON(inputs.runner-label) }}
    timeout-minutes: 5
    permissions:
      contents: read
      pull-requests: write
    steps:
      - name: Post/update sticky CI summary comment
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          PR_NUMBER: ${{ github.event.pull_request.number }}
          REPO: ${{ github.repository }}
        run: |
          BODY="## 🚀 CI Summary — \`${{ inputs.app-name }}\`
          | Job | Result |
          |-----|--------|
          | lint | ${{ needs.lint-python.result }} |
          | security | ${{ needs.security.result }} |
          | tests | ${{ needs.test-matrix.result }} |
          | coverage | ${{ needs.coverage.result }} |
          | docker | ${{ needs.docker-build.result }} |

          [View run](${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }})"
          # Update existing comment or create new one
          COMMENT_ID=$(gh api "repos/${REPO}/issues/${PR_NUMBER}/comments" \
            --jq '[.[] | select(.body | startswith("## 🚀 CI Summary"))] | .[0].id // empty' 2>/dev/null || echo "")
          if [ -n "$COMMENT_ID" ]; then
            gh api "repos/${REPO}/issues/comments/${COMMENT_ID}" -X PATCH -f body="$BODY" >/dev/null
          else
            gh api "repos/${REPO}/issues/${PR_NUMBER}/comments" -f body="$BODY" >/dev/null
          fi
```

- [ ] **Step 2: Add `notify` top-level job (after `pr-summary`)**

```yaml
  notify:
    name: "🚨 Notify"
    needs: [lint-python, security, test-matrix, coverage, docker-build, telemetry]
    if: >-
      ${{ always() && (
        needs.lint-python.result == 'failure' ||
        needs.test-matrix.result == 'failure' ||
        needs.coverage.result == 'failure' ||
        needs.docker-build.result == 'failure'
      ) }}
    permissions:
      contents: read
    uses: adza-group/shared-workflows/.github/workflows/reusable-notify.yml@dev
    with:
      app-name: ${{ inputs.app-name }}
      status: failure
      branch: ${{ github.ref_name }}
      sha: ${{ github.sha }}
      run-url: ${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }}
      runner-label: ${{ inputs.runner-label }}
    secrets: inherit
```

- [ ] **Step 3: Validate**

```bash
./bin/actionlint.exe .github/workflows/reusable-ci.yml
```
Expected: exit 0.

- [ ] **Step 4: Commit**

```bash
NAME=$(git log -1 --format='%an'); EMAIL=$(git log -1 --format='%ae')
git add .github/workflows/reusable-ci.yml
git -c user.name="$NAME" -c user.email="$EMAIL" commit -m "$(cat <<'EOF'
feat(ci): add pr-summary (sticky comment) + notify (failure alert) jobs

pr-summary: posts/updates CI result table as sticky PR comment via gh api.
notify: top-level job calling reusable-notify on lint/test/coverage/docker failure.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
```

---

### Task 9: Extend `telemetry` job needs + summary table

**Files:**
- Modify: `.github/workflows/reusable-ci.yml` (`telemetry` job)

- [ ] **Step 1: Extend `telemetry.needs` array**

Find the current telemetry `needs:` line:
```yaml
    needs: [changes, lint-python, security, test-matrix, coverage, test-results, docker-build]
```

Replace with:
```yaml
    # NOTE: jobs gated behind inputs (staging-url, has-frontend, etc.) are still always
    # DEFINED in the workflow — they just get result:'skipped' when their if: is false.
    # GHA propagates skipped status safely, so all jobs can be in needs: without error.
    needs: [changes, lint-python, lint-dockerfile, code-quality, dead-code, todo-tracker, license-check, commit-lint, security, test-matrix, property-tests, mutation, frontend, coverage, test-results, docker-build, verify-staging, require-staging-green, verify-prod, load-test, pr-summary]
```

- [ ] **Step 2: Extend the telemetry summary table in the `run:` step**

Find the `echo "| docker-build | ..."` line and add these rows after it:
```bash
            echo "| lint-dockerfile | ${{ needs.lint-dockerfile.result }} |"
            echo "| code-quality | ${{ needs.code-quality.result }} |"
            echo "| dead-code | ${{ needs.dead-code.result }} |"
            echo "| property-tests | ${{ needs.property-tests.result }} |"
            echo "| mutation | ${{ needs.mutation.result }} |"
            echo "| frontend | ${{ needs.frontend.result }} |"
            echo "| verify-staging | ${{ needs.verify-staging.result }} |"
            echo "| verify-prod | ${{ needs.verify-prod.result }} |"
```

- [ ] **Step 3: Validate**

```bash
./bin/actionlint.exe .github/workflows/reusable-ci.yml
```
Expected: exit 0.

- [ ] **Step 4: Full yaml lint**

```bash
python -m yamllint -d relaxed .github/workflows/reusable-ci.yml
```
Expected: no errors.

- [ ] **Step 5: Commit**

```bash
NAME=$(git log -1 --format='%an'); EMAIL=$(git log -1 --format='%ae')
git add .github/workflows/reusable-ci.yml
git -c user.name="$NAME" -c user.email="$EMAIL" commit -m "feat(ci): extend telemetry — all Cycle A jobs in needs + summary table

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>"
```

---

### Task 10: Extend `_smoke-ci.yml` + validate on ubuntu

**Files:**
- Modify: `.github/workflows/_smoke-ci.yml` (add new inputs with safe defaults)

- [ ] **Step 1: Add new inputs to the smoke caller's `with:` block**

Find the existing `with:` block in `_smoke-ci.yml`. After `image-name: ghcr.io/adza-group/smoke-fixture`, add:
```yaml
      has-frontend: false
      staging-url: ""
      prod-url: ""
      deploy-prod: false
      enable-property-tests: true
      enable-mutation: true
      enable-load-test: false
      enable-dast: false
```

- [ ] **Step 2: Validate smoke file**

```bash
./bin/actionlint.exe .github/workflows/_smoke-ci.yml
```
Expected: exit 0.

- [ ] **Step 3: Add temp push trigger to `_smoke-ci.yml`**

```yaml
on:
  workflow_dispatch:
  push:
    branches: [dev]
```

- [ ] **Step 4: Commit + push**

```bash
NAME=$(git log -1 --format='%an'); EMAIL=$(git log -1 --format='%ae')
git add .github/workflows/_smoke-ci.yml
git -c user.name="$NAME" -c user.email="$EMAIL" commit -m "ci(smoke): extend _smoke-ci with Cycle A inputs + temp push trigger [revert after green]

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>"
git push origin dev
```

- [ ] **Step 5: Watch the run**

```bash
gh run list --branch dev --limit 5 --json databaseId,name,status
gh run watch <RUN_ID> --exit-status
```
Expected: all jobs green (many will be `skipped` because `staging-url=""`, `has-frontend=false` — that's correct).

- [ ] **Step 6: If any job failed**

```bash
gh run view <RUN_ID> --log-failed 2>&1 | head -100
```
Fix → commit → push → re-watch.

- [ ] **Step 7: Revert temp trigger**

```yaml
on:
  workflow_dispatch:
```

```bash
NAME=$(git log -1 --format='%an'); EMAIL=$(git log -1 --format='%ae')
git add .github/workflows/_smoke-ci.yml
git -c user.name="$NAME" -c user.email="$EMAIL" commit -m "ci(smoke): revert temp push trigger — Cycle A validated green on ubuntu

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>"
git push origin dev
```

---

### Task 11: Merge dev→main + publish v1.1 tag

- [ ] **Step 1: Confirm dev CI is green**

```bash
gh run list --branch dev --limit 1 --json status,conclusion --jq '.[0]'
```
Expected: `"conclusion": "success"`.

- [ ] **Step 2: Merge to main**

```bash
git checkout main && git pull origin main
NAME=$(git log -1 --format='%an'); EMAIL=$(git log -1 --format='%ae')
git -c user.name="$NAME" -c user.email="$EMAIL" merge --no-ff dev -m "$(cat <<'EOF'
chore: Cycle A — orchestrator-tail: full lint, property-tests, mutation, deploy-tail, pr-summary, notify → v1.1

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 3: Create v1.1 tag and re-float v1**

```bash
NAME=$(git log -1 --format='%an'); EMAIL=$(git log -1 --format='%ae')
git -c user.name="$NAME" -c user.email="$EMAIL" \
  tag -a v1.1 -m "ci: v1.1 — full orchestrator DAG (lint/mutation/deploy-tail/notify)"
# Float v1 to latest:
git tag -d v1
git -c user.name="$NAME" -c user.email="$EMAIL" \
  tag -a v1 -m "chore: v1 (= v1.1)"
```

- [ ] **Step 4: Push main + tags**

```bash
git push origin main
git push origin v1.1
git push origin v1 --force
```

- [ ] **Step 5: Verify**

```bash
git ls-remote origin 'refs/tags/v1*'
```
Expected: `v1`, `v1.0`, `v1.1` all present.

- [ ] **Step 6: Return to dev**

```bash
git checkout dev
```

---

**Cycle A done. `@v1` / `@v1.1` both point to the full-DAG orchestrator.**
Next: run Cycle B plan (`2026-05-29-unified-ci-cycle-b-v1.2.md`).
