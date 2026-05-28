# Unified CI — Phase 2c: Enforce `reusable-load-test` budgets — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Make `reusable-load-test.yml` actually enforce its `threshold-p95-ms` budget (currently declared but only printed), plus an error-rate budget, with an advisory-by-default `blocking` toggle.

**Architecture:** Run k6 with `--summary-export`, then a separate step parses the JSON and gates on p95 + error-rate. We gate explicitly on the exported metrics (not k6's own threshold exit) so the budget is enforced regardless of what the k6 script defines. Advisory (warn) by default; `blocking: true` (e.g. on main/nightly-vs-prod) fails the job on breach.

**Tech Stack:** GitHub reusable workflow, k6, Python (stdlib json), `actionlint`, `yamllint`.

**Spec:** `docs/superpowers/specs/2026-05-28-unified-ci-design.md` §2.2 (load-test gate not enforced), §5.2 (complete load-test).

## Environment & rules
- Work from `C:\Users\ADZArecaclage\Documents\Projekte\shared-workflows`, branch `dev`.
- Linters: `./bin/actionlint.exe <file>`, `python -m yamllint -d relaxed <file>` (or the `yamllint.exe` path if the module form fails). actionlint must exit 0.
- Git: NO `git config`; inline identity. No push. Explicit `git add <paths>` (untracked `bin/` stays untracked).
- k6 is assumed present on the self-hosted runner (as today). The `<<'PY'` heredoc is single-quoted so the shell does not expand it and shellcheck treats it as literal data (the Python reads values from `env:`).

---

### Task 1: Rewrite `reusable-load-test.yml` with budget enforcement

**Files:**
- Overwrite: `.github/workflows/reusable-load-test.yml`

- [ ] **Step 1: Replace the entire file** with this content (verbatim):

```yaml
# ═══════════════════════════════════════════════════════════════
# Reusable Load Test Workflow — ADZA-Group (senior-grade)
#
# Runs k6 against target-url, then ENFORCES p95 + error-rate budgets
# parsed from k6's summary JSON. Advisory by default; set blocking=true
# (e.g. on main / nightly-vs-prod) to fail the job on a breach.
#
# Usage:
#   uses: adza-group/shared-workflows/.github/workflows/reusable-load-test.yml@v1
#   with:
#     target-url: "https://i-app.adza-group.ch"
#     blocking: false
# ═══════════════════════════════════════════════════════════════

name: "📈 Load Test"

on:
  workflow_call:
    inputs:
      target-url:
        required: true
        type: string
        description: "URL to load test"
      test-script:
        required: false
        type: string
        default: "tests/load/baseline.js"
      threshold-p95-ms:
        required: false
        type: number
        default: 500
      threshold-error-rate:
        required: false
        type: number
        default: 0.01
      blocking:
        required: false
        type: boolean
        default: false
        description: "Fail the job on a budget breach (false => warn only)"
      runner-label:
        required: false
        type: string
        default: '["self-hosted", "linux", "proxmox"]'

permissions:
  contents: read

jobs:
  load-test:
    name: "📈 k6 Load Test"
    runs-on: ${{ fromJSON(inputs.runner-label) }}
    timeout-minutes: 10
    steps:
      - uses: actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5  # v4

      - name: "📈 Run k6 baseline"
        run: |
          k6 run \
            --env TARGET_URL=${{ inputs.target-url }} \
            --summary-trend-stats="avg,min,med,max,p(90),p(95),p(99)" \
            --summary-export=/tmp/k6-summary.json \
            ${{ inputs.test-script }} || true

      - name: "📈 Enforce budgets"
        env:
          THR_P95: ${{ inputs.threshold-p95-ms }}
          THR_ERR: ${{ inputs.threshold-error-rate }}
          BLOCKING: ${{ inputs.blocking }}
          TARGET: ${{ inputs.target-url }}
        run: |
          python3 - <<'PY'
          import json, os, sys
          try:
              d = json.load(open('/tmp/k6-summary.json'))
          except Exception as e:
              print(f"::error::could not read k6 summary: {e}")
              sys.exit(1)
          m = d.get('metrics', {})
          dur = m.get('http_req_duration', {})
          p95 = dur.get('p(95)') or dur.get('p95') or 0.0
          err = (m.get('http_req_failed') or {}).get('value', 0.0)
          thr_p95 = float(os.environ['THR_P95'])
          thr_err = float(os.environ['THR_ERR'])
          blocking = os.environ['BLOCKING'] == 'true'
          with open(os.environ['GITHUB_STEP_SUMMARY'], 'a') as f:
              f.write("## 📈 Load Test\n")
              f.write(f"Target: `{os.environ['TARGET']}`\n\n")
              f.write("| Metric | Value | Budget |\n|---|---|---|\n")
              f.write(f"| p95 | {p95:.0f} ms | {thr_p95:.0f} ms |\n")
              f.write(f"| error-rate | {err:.2%} | {thr_err:.2%} |\n")
          breaches = []
          if p95 > thr_p95:
              breaches.append(f"p95 {p95:.0f}ms > {thr_p95:.0f}ms")
          if err > thr_err:
              breaches.append(f"error-rate {err:.2%} > {thr_err:.2%}")
          if breaches:
              msg = "; ".join(breaches)
              if blocking:
                  print(f"::error::load-test budget breach: {msg}")
                  sys.exit(1)
              print(f"::warning::load-test budget breach (advisory): {msg}")
          else:
              print("✅ load-test within budget")
          PY
```

- [ ] **Step 2: Static-validate**

Run: `./bin/actionlint.exe .github/workflows/reusable-load-test.yml && python -m yamllint -d relaxed .github/workflows/reusable-load-test.yml`
Expected: actionlint exit 0 (it will shellcheck the `run:` blocks; the quoted `<<'PY'` heredoc is treated as literal data, not shell); yamllint exit 0 (line-length warnings ok). If actionlint flags the `fromJSON` runs-on or an expression, fix syntax without changing semantics.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/reusable-load-test.yml
NAME=$(git log -1 --format='%an'); EMAIL=$(git log -1 --format='%ae')
git -c user.name="$NAME" -c user.email="$EMAIL" commit -m "feat(load-test): enforce p95 + error-rate budgets from k6 summary (advisory/blocking toggle)"
```

---

### Validation (DEFERRED — requires push + a live target + k6 on runner)

Not runnable locally. Real validation happens when an app calls this reusable post-deploy against its staging URL (Phase 4), or via a nightly-vs-prod run. The gate logic is exercised then.

---

## Self-Review

**1. Spec coverage (§5.2 "complete load-test"):** `threshold-p95-ms` now enforced ✓ (parsed from `--summary-export` JSON); added `threshold-error-rate` ✓; advisory/blocking toggle ✓; summary table shows actual-vs-budget ✓. k6's own exit is bypassed (`|| true`) so the explicit gate is authoritative ✓.

**2. Placeholder scan:** No TBD/TODO. Concrete checkout pin. The deferred validation is a real post-push step, not a placeholder.

**3. Type/expression consistency:** `fromJSON(inputs.runner-label)` matches the other reusables. Inputs `threshold-p95-ms`/`threshold-error-rate`/`blocking` are read via `env:` into the Python gate (numbers/bools render as strings in env, parsed with `float()`/`== 'true'`). The p95 key handles both `p(95)` (k6 summary-export format) and `p95` defensively. Single-quoted heredoc prevents shell/`${{ }}` interference (values flow only through `env:`).
