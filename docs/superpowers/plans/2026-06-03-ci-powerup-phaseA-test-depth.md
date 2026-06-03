# CI Power-up Phase A — Test Depth (diff-coverage + flaky-handling) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans (inline) or superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`).

**Goal:** Add a diff-coverage gate (new/changed lines must be covered) + automatic flaky-test rerun to the unified CI, fleet-wide via the composites.

**Architecture:** `run-pytest-shard` gains `pytest-rerun-failures`; `coverage-gate` gains a `diff-cover` step (HEAD vs `origin/main`); `reusable-ci`'s coverage job fetches full history + passes a dual-gated diff-coverage threshold. Released as v1.5.0.

**Tech Stack:** GitHub Actions composites, `pytest-rerun-failures`, `diff-cover`.

**Spec:** `docs/superpowers/specs/2026-06-03-senior-ci-powerup-design.md` (Phase A)

---

## File Structure

- `shared-workflows/.github/actions/run-pytest-shard/action.yml` — `test-reruns` input + rerun flags.
- `shared-workflows/.github/actions/coverage-gate/action.yml` — diff-coverage inputs + `diff-cover` step.
- `shared-workflows/.github/workflows/reusable-ci.yml` — coverage job `fetch-depth: 0`, pass diff-coverage inputs (dual-gated), new `diff-coverage-threshold` input.

---

## Task A1: Flaky-test auto-rerun (`run-pytest-shard`)

**Files:** Modify `shared-workflows/.github/actions/run-pytest-shard/action.yml`

- [ ] **Step 1: Add the `test-reruns` input** after the `timeout` input (line 23-26):

```yaml
  test-reruns:
    description: "Auto-rerun failed tests N times (flaky mitigation; 0 disables)"
    required: false
    default: "1"
```

- [ ] **Step 2: Replace the pytest run block** (lines 43-52) — install the plugin + add rerun flags conditionally:

```yaml
        if [ -n "${{ inputs.markers }}" ]; then
          SELECT=(-m "${{ inputs.markers }}")
        else
          SELECT=(${{ inputs.test-paths }})
        fi
        # Flaky mitigation: rerun failed tests (pytest-rerun-failures). Reruns appear in junit.
        RERUN=()
        if [ "${{ inputs.test-reruns }}" != "0" ]; then
          pip install -q pytest-rerun-failures || echo "::warning::pytest-rerun-failures install failed — running without reruns"
          python -c "import pytest_rerunfailures" 2>/dev/null && RERUN=(--reruns "${{ inputs.test-reruns }}" --reruns-delay 1)
        fi
        pytest "${SELECT[@]}" \
          --timeout=${{ inputs.timeout }} \
          "${RERUN[@]}" \
          --cov=${{ inputs.coverage-source }} --cov-report= \
          --junitxml=junit-${{ inputs.shard-name }}.xml \
          -p no:cacheprovider
```

- [ ] **Step 3: actionlint**

Run: `cd shared-workflows && ./bin/actionlint.exe .github/actions/run-pytest-shard/action.yml` (composites: actionlint validates referencing workflows; if it doesn't lint standalone, rely on the reusable-ci lint in Task A3). Expected: no error.

- [ ] **Step 4: Commit**

```bash
cd shared-workflows
NAME=$(git log -1 --format='%an'); EMAIL=$(git log -1 --format='%ae')
git add .github/actions/run-pytest-shard/action.yml
git -c user.name="$NAME" -c user.email="$EMAIL" commit -m "feat(ci): pytest-rerun-failures auto-rerun (test-reruns input, flaky mitigation)"
```

## Task A2: Diff-coverage gate (`coverage-gate` composite)

**Files:** Modify `shared-workflows/.github/actions/coverage-gate/action.yml`

- [ ] **Step 1: Add 3 inputs** after the `blocking` input (line 11-14):

```yaml
  diff-coverage-threshold:
    description: "Min coverage % on lines changed vs compare-branch (0 disables)"
    required: false
    default: "0"
  diff-coverage-compare-branch:
    description: "Branch to diff against for changed-line coverage"
    required: false
    default: "origin/main"
  diff-coverage-blocking:
    description: "Fail when diff-coverage below threshold (false => warn)"
    required: false
    default: "false"
```

- [ ] **Step 2: Add a diff-coverage step** at the end of `runs.steps` (after the "Combine + report + gate" step, ~line 59):

```yaml
    - name: Diff coverage (new/changed lines)
      if: ${{ inputs.diff-coverage-threshold != '0' }}
      shell: bash
      run: |
        pip install -q diff-cover || { echo "::warning::diff-cover install failed — skipping diff-coverage"; exit 0; }
        BR="${{ inputs.diff-coverage-compare-branch }}"
        git fetch origin "${BR#origin/}" --depth=200 2>/dev/null || true
        echo "## 🔬 Diff coverage (changed vs ${BR})" >> "$GITHUB_STEP_SUMMARY"
        if diff-cover coverage.xml --compare-branch="$BR" \
             --fail-under="${{ inputs.diff-coverage-threshold }}" \
             --markdown-report diff-cov.md; then
          echo "✅ changed-line coverage ≥ ${{ inputs.diff-coverage-threshold }}%" >> "$GITHUB_STEP_SUMMARY"
        else
          tail -40 diff-cov.md >> "$GITHUB_STEP_SUMMARY" 2>/dev/null || true
          if [ "${{ inputs.diff-coverage-blocking }}" = "true" ]; then
            echo "::error::diff-coverage on changed lines < ${{ inputs.diff-coverage-threshold }}%"; exit 1
          else
            echo "::warning::diff-coverage on changed lines < ${{ inputs.diff-coverage-threshold }}% (advisory)"
          fi
        fi
```

> Relies on `coverage.xml` (produced by the prior step, relative paths via `relative_files=true`) + git history (Task A3 adds `fetch-depth: 0`). Default `diff-coverage-threshold: 0` keeps the composite a no-op unless a caller opts in — `reusable-ci` opts in (Task A3).

- [ ] **Step 3: Commit**

```bash
cd shared-workflows
NAME=$(git log -1 --format='%an'); EMAIL=$(git log -1 --format='%ae')
git add .github/actions/coverage-gate/action.yml
git -c user.name="$NAME" -c user.email="$EMAIL" commit -m "feat(ci): diff-coverage gate in coverage-gate composite (changed-line coverage)"
```

## Task A3: Wire into `reusable-ci` (fetch-depth + dual-gate) + input

**Files:** Modify `shared-workflows/.github/workflows/reusable-ci.yml`

- [ ] **Step 1: Add the `diff-coverage-threshold` input** to the `workflow_call.inputs` block (near `coverage-threshold`):

```yaml
      diff-coverage-threshold:
        required: false
        type: number
        default: 80
        description: "Min coverage % on changed lines (PR/dev advisory, main/tags hard); 0 disables"
```

- [ ] **Step 2: Replace the coverage job steps** (lines 438-448) — add `fetch-depth: 0` + pass diff-coverage (dual-gated):

```yaml
    steps:
      - uses: actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5  # v4
        with:
          fetch-depth: 0
      - uses: adza-group/shared-workflows/.github/actions/setup-python-deps@v1
        with:
          install-requirements: "false"
          install-coverage: "true"
          cache-key-suffix: coverage
      - uses: adza-group/shared-workflows/.github/actions/coverage-gate@v1
        with:
          threshold: ${{ inputs.coverage-threshold }}
          blocking: "true"
          diff-coverage-threshold: ${{ inputs.diff-coverage-threshold }}
          diff-coverage-compare-branch: "origin/main"
          diff-coverage-blocking: ${{ github.ref == 'refs/heads/main' || startsWith(github.ref, 'refs/tags/') }}
```

- [ ] **Step 3: actionlint**

Run: `cd shared-workflows && ./bin/actionlint.exe .github/workflows/reusable-ci.yml`
Expected: exit 0.

- [ ] **Step 4: Commit + push dev**

```bash
cd shared-workflows
NAME=$(git log -1 --format='%an'); EMAIL=$(git log -1 --format='%ae')
git add .github/workflows/reusable-ci.yml
git -c user.name="$NAME" -c user.email="$EMAIL" commit -m "feat(ci): wire diff-coverage into coverage job (fetch-depth:0 + dual-gate, default 80%)"
git push origin dev
```

## Task A4: Release v1.5.0 + validate

- [ ] **Step 1: Tag + move @v1**

```bash
cd shared-workflows
NAME=$(git log -1 --format='%an'); EMAIL=$(git log -1 --format='%ae'); DEVH=$(git rev-parse dev)
git -c user.name="$NAME" -c user.email="$EMAIL" tag -a v1.5.0 "$DEVH" -m "v1.5.0 — Phase A: diff-coverage gate + flaky auto-rerun"
git push origin v1.5.0
git tag -f v1 "$DEVH"; git push -f origin v1
git ls-remote origin refs/tags/v1 refs/tags/v1.5.0
```
Expected: both → `$DEVH`.

- [ ] **Step 2: Validate on a real app dev run** (Rechnungsapp — a code/test-touching commit so the coverage job runs):

Trigger a dev run (a small test/code touch or empty commit won't run coverage — coverage needs test-matrix success; ensure a python-path change OR rely on the next real push). Then:
```bash
RID=$(gh api "repos/ADZA-Group/rechnungsapp/actions/runs?branch=dev&per_page=5" --jq '[.workflow_runs[]|select(.name=="CI/CD")][0].id')
gh run view "$RID" -R ADZA-Group/rechnungsapp --json conclusion,jobs --jq '.conclusion, (.jobs[]|select(.name|contains("Coverage"))|.conclusion)'
gh run view --job <coverage-job-id> -R ADZA-Group/rechnungsapp --log | grep -iE "diff.cover|changed-line|reruns"
```
Expected: coverage job success; diff-coverage step ran (advisory on dev); flaky reruns visible if any test flaked.

- [ ] **Step 3:** `superpowers:verification-before-completion` before claiming Phase A done — cite the run conclusion + the diff-coverage/rerun log lines.

---

## Self-review

- **Spec coverage (Phase A):** diff-coverage → A2+A3; flaky-rerun → A1. Both covered.
- **Dual-gate:** diff-coverage-blocking set hard on main/tags, advisory else (A3 Step 2). ✓
- **No hardcoded hosted:** no new `runs-on` added (coverage job already runner-label-driven). ✓
- **Plugin availability:** both `pytest-rerun-failures` + `diff-cover` installed in-composite with graceful fallback (no app requirements change needed). ✓
- **Naming consistency:** input `test-reruns` (A1), `diff-coverage-threshold`/`-compare-branch`/`-blocking` (A2) match the reusable-ci wiring (A3). ✓
