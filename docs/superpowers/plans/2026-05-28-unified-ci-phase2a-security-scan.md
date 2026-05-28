# Unified CI — Phase 2a: Harden `reusable-security-scan` — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the existing immature `reusable-security-scan.yml` into a senior-grade, dual-gated security workflow that actually runs on the Debian-13 self-hosted runners.

**Architecture:** Rewrite the reusable workflow to (1) replace the Debian-13-breaking `actions/setup-python` with the `setup-python-deps` composite (referenced by full path `adza-group/shared-workflows/.github/actions/setup-python-deps@dev`), (2) add CodeQL (py+js, on ubuntu for RAM), dependency-review (PR-only), and OPA/conftest jobs, (3) apply the dual-gate (advisory on PR/dev, blocking on main/tags) uniformly, and (4) pin the unpinned `trivy-action@master`.

**Tech Stack:** GitHub reusable workflows, `setup-python-deps`/`opa-policy` composites (Phase 1), gitleaks, Bandit, Semgrep, Trivy, pip-audit, CodeQL, dependency-review-action, `actionlint`, `yamllint`.

**Spec:** `docs/superpowers/specs/2026-05-28-unified-ci-design.md` §2.2 (security-scan is immature), §5.2 (extend security-scan), §6 (dual-gate + pinning).

---

## Critical constraints (read before implementing)

1. **Local-action resolution:** `uses: ./...` inside a reusable workflow resolves against the **caller's** repo, not shared-workflows. Therefore sibling composites MUST be referenced by full path with a **literal** ref: `adza-group/shared-workflows/.github/actions/setup-python-deps@dev` (no `${{ }}` in a `uses:` ref). We use `@dev` during build-out; Phase 4 bumps these (and app callers) to `@v1`.
2. **Validation is deferred (user decision):** everything is built locally on `dev` and **not pushed**. The reusable cannot be runtime-validated until `dev` is on GitHub (the `@dev` composite refs must resolve remotely). Local validation in this plan = `actionlint` + `yamllint` only. The real run is a deferred task (Task 3), to be done when the stack is pushed.
3. **Dual-gate expression** (used verbatim throughout): a job/step is blocking only on main or a tag. As a `continue-on-error` value: `${{ !(github.ref == 'refs/heads/main' || startsWith(github.ref, 'refs/tags/')) }}`. As a Trivy `exit-code`: `${{ (github.ref == 'refs/heads/main' || startsWith(github.ref, 'refs/tags/')) && '1' || '0' }}`. `github.ref` inside a reusable workflow reflects the **caller's** ref, which is what we want.
4. **Pins (resolved):** `aquasecurity/trivy-action@ed142fd0673e97e23eac54620cfb913e5ce36c25  # v0.36.0`; `actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5  # v4`. First-party `github/codeql-action@v3` and `actions/dependency-review-action@v4` stay on major tags per the pinning policy.

## Environment & rules
- Work from `C:\Users\ADZArecaclage\Documents\Projekte\shared-workflows`, branch `dev` (already checked out).
- Linters: `./bin/actionlint.exe <file>` (`.github/actionlint.yaml` declares `proxmox`/`linux`); `python -m yamllint -d relaxed <file>`.
- Git identity quirk: NO git user; do NOT run `git config`. Commit inline: `NAME=$(git log -1 --format='%an'); EMAIL=$(git log -1 --format='%ae'); git -c user.name="$NAME" -c user.email="$EMAIL" commit -m "..."`.
- Do NOT push. Explicit `git add <paths>` only (untracked `bin/` must stay untracked). Conventional Commits.

---

### Task 1: Rewrite `reusable-security-scan.yml` to senior grade

**Files:**
- Overwrite: `.github/workflows/reusable-security-scan.yml`

- [ ] **Step 1: Replace the entire file** with this content (verbatim):

```yaml
# ═══════════════════════════════════════════════════════════════
# Reusable Security Scanning Workflow — ADZA-Group (senior-grade)
#
# Jobs: gitleaks (hard) · Bandit · Semgrep · Trivy FS+IaC · pip-audit
#       · CodeQL (py+js) · dependency-review (PR) · OPA/conftest
# Dual-gate: advisory on PR/dev, BLOCKING on main + tags.
# Debian-13 self-hosted safe: uses setup-python-deps composite (NOT actions/setup-python).
#
# Usage:
#   uses: adza-group/shared-workflows/.github/workflows/reusable-security-scan.yml@v1
#   secrets: inherit
# ═══════════════════════════════════════════════════════════════

name: "🔐 Security Scan"

on:
  workflow_call:
    inputs:
      python-version:
        required: false
        type: string
        default: "3.11"
      runner-label:
        required: false
        type: string
        default: '["self-hosted", "linux", "proxmox"]'
      run-gitleaks:
        required: false
        type: boolean
        default: true
      run-bandit:
        required: false
        type: boolean
        default: true
      run-semgrep:
        required: false
        type: boolean
        default: true
      run-trivy:
        required: false
        type: boolean
        default: true
      run-pip-audit:
        required: false
        type: boolean
        default: true
      run-codeql:
        required: false
        type: boolean
        default: true
      run-dependency-review:
        required: false
        type: boolean
        default: true
      run-opa:
        required: false
        type: boolean
        default: true
      bandit-exclude:
        required: false
        type: string
        default: "./tests,./.venv"
      semgrep-configs:
        required: false
        type: string
        default: "p/python p/flask p/security-audit p/secrets"
      codeql-languages:
        required: false
        type: string
        default: '["python", "javascript-typescript"]'

permissions:
  contents: read

jobs:
  # ── Secret Detection (HARD FAIL on every branch) ──────────────
  gitleaks:
    name: "🔑 Secrets"
    if: ${{ inputs.run-gitleaks }}
    runs-on: ${{ fromJSON(inputs.runner-label) }}
    timeout-minutes: 10
    steps:
      - uses: actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5  # v4
        with:
          fetch-depth: 0
      - name: Gitleaks
        run: |
          curl -sSfL https://github.com/gitleaks/gitleaks/releases/download/v8.21.2/gitleaks_8.21.2_linux_x64.tar.gz \
            | tar xz -C /usr/local/bin gitleaks
          gitleaks detect --source=. --no-banner --redact -v

  # ── SAST: Bandit (dual-gate) ──────────────────────────────────
  bandit:
    name: "🛡️ SAST Bandit"
    if: ${{ inputs.run-bandit }}
    runs-on: ${{ fromJSON(inputs.runner-label) }}
    timeout-minutes: 15
    steps:
      - uses: actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5  # v4
      - uses: adza-group/shared-workflows/.github/actions/setup-python-deps@dev
        with:
          install-requirements: "false"
          extra-packages: "bandit[toml]==1.*"
          cache-key-suffix: bandit
      - name: Bandit scan
        continue-on-error: ${{ !(github.ref == 'refs/heads/main' || startsWith(github.ref, 'refs/tags/')) }}
        run: |
          bandit -r . --exclude ${{ inputs.bandit-exclude }} \
            --skip B101,B104,B105,B106,B311,B603,B607 \
            -ll -f json -o /tmp/bandit.json || true
          bandit -r . --exclude ${{ inputs.bandit-exclude }} \
            --skip B101,B104,B105,B106,B311,B603,B607 -ll
      - name: Summary
        if: always()
        run: |
          echo "## 🛡️ SAST — Bandit" >> "$GITHUB_STEP_SUMMARY"
          python3 -c "
          import json, pathlib
          data = json.loads(pathlib.Path('/tmp/bandit.json').read_text())
          r = data.get('results', [])
          h = sum(1 for x in r if x['issue_severity']=='HIGH')
          m = sum(1 for x in r if x['issue_severity']=='MEDIUM')
          print(f'| Severity | Count |\n|---|---|\n| HIGH | {h} |\n| MEDIUM | {m} |')
          " >> "$GITHUB_STEP_SUMMARY" 2>/dev/null || true

  # ── SAST: Semgrep (dual-gate) ─────────────────────────────────
  semgrep:
    name: "🛡️ SAST Semgrep"
    if: ${{ inputs.run-semgrep }}
    runs-on: ${{ fromJSON(inputs.runner-label) }}
    timeout-minutes: 15
    steps:
      - uses: actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5  # v4
      - uses: adza-group/shared-workflows/.github/actions/setup-python-deps@dev
        with:
          install-requirements: "false"
          extra-packages: "semgrep==1.*"
          cache-key-suffix: semgrep
      - name: Semgrep scan
        continue-on-error: ${{ !(github.ref == 'refs/heads/main' || startsWith(github.ref, 'refs/tags/')) }}
        run: |
          CONFIGS=""
          for cfg in ${{ inputs.semgrep-configs }}; do
            CONFIGS="$CONFIGS --config $cfg"
          done
          semgrep scan $CONFIGS \
            --severity ERROR --severity WARNING \
            --exclude tests --exclude .venv --metrics off --error

  # ── Trivy filesystem + IaC (dual-gate via exit-code) ──────────
  trivy:
    name: "🔍 Trivy FS"
    if: ${{ inputs.run-trivy }}
    runs-on: ${{ fromJSON(inputs.runner-label) }}
    timeout-minutes: 15
    steps:
      - uses: actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5  # v4
      - name: Filesystem scan
        uses: aquasecurity/trivy-action@ed142fd0673e97e23eac54620cfb913e5ce36c25  # v0.36.0
        with:
          scan-type: fs
          scan-ref: .
          format: table
          severity: CRITICAL,HIGH
          exit-code: ${{ (github.ref == 'refs/heads/main' || startsWith(github.ref, 'refs/tags/')) && '1' || '0' }}
      - name: Config / IaC scan
        uses: aquasecurity/trivy-action@ed142fd0673e97e23eac54620cfb913e5ce36c25  # v0.36.0
        with:
          scan-type: config
          scan-ref: .
          format: table
          severity: CRITICAL,HIGH,MEDIUM
          exit-code: ${{ (github.ref == 'refs/heads/main' || startsWith(github.ref, 'refs/tags/')) && '1' || '0' }}

  # ── SCA: pip-audit (dual-gate) ────────────────────────────────
  pip-audit:
    name: "📦 Dep Audit"
    if: ${{ inputs.run-pip-audit }}
    runs-on: ${{ fromJSON(inputs.runner-label) }}
    timeout-minutes: 10
    steps:
      - uses: actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5  # v4
      - uses: adza-group/shared-workflows/.github/actions/setup-python-deps@dev
        with:
          install-requirements: "false"
          extra-packages: "pip-audit==2.*"
          cache-key-suffix: pip-audit
      - name: pip-audit
        continue-on-error: ${{ !(github.ref == 'refs/heads/main' || startsWith(github.ref, 'refs/tags/')) }}
        run: |
          pip-audit -r requirements.txt --desc | tee /tmp/audit.txt
          {
            echo "## 📦 SCA — Dependency Audit"
            echo '```'
            cat /tmp/audit.txt
            echo '```'
          } >> "$GITHUB_STEP_SUMMARY"

  # ── CodeQL (py+js) — ubuntu (RAM); dual-gate ──────────────────
  codeql:
    name: "🔬 CodeQL"
    if: ${{ inputs.run-codeql }}
    runs-on: ubuntu-latest
    timeout-minutes: 20
    permissions:
      contents: read
      security-events: write
    continue-on-error: ${{ !(github.ref == 'refs/heads/main' || startsWith(github.ref, 'refs/tags/')) }}
    strategy:
      fail-fast: false
      matrix:
        language: ${{ fromJSON(inputs.codeql-languages) }}
    steps:
      - uses: actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5  # v4
      - uses: github/codeql-action/init@v3
        with:
          languages: ${{ matrix.language }}
          queries: security-extended
      - uses: github/codeql-action/autobuild@v3
      - uses: github/codeql-action/analyze@v3
        with:
          category: "/language:${{ matrix.language }}"

  # ── Dependency Review (PR-only) ───────────────────────────────
  dependency-review:
    name: "📜 Dependency Review"
    if: ${{ inputs.run-dependency-review && github.event_name == 'pull_request' }}
    runs-on: ubuntu-latest
    timeout-minutes: 10
    steps:
      - uses: actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5  # v4
      - uses: actions/dependency-review-action@v4
        with:
          fail-on-severity: ${{ github.base_ref == 'main' && 'high' || 'critical' }}

  # ── OPA / conftest policy (dual-gate via composite input) ─────
  opa:
    name: "📋 OPA Policy"
    if: ${{ inputs.run-opa }}
    runs-on: ${{ fromJSON(inputs.runner-label) }}
    timeout-minutes: 10
    steps:
      - uses: actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5  # v4
      - uses: adza-group/shared-workflows/.github/actions/opa-policy@dev
        with:
          blocking: ${{ (github.ref == 'refs/heads/main' || startsWith(github.ref, 'refs/tags/')) && 'true' || 'false' }}
```

- [ ] **Step 2: Static-validate**

Run: `./bin/actionlint.exe .github/workflows/reusable-security-scan.yml && python -m yamllint -d relaxed .github/workflows/reusable-security-scan.yml`
Expected: actionlint exit 0; yamllint exit 0 (line-length warnings only). If actionlint flags an expression error (e.g. in a `continue-on-error`/`exit-code` ternary), fix the expression syntax and re-run — do not change the gating logic.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/reusable-security-scan.yml
NAME=$(git log -1 --format='%an'); EMAIL=$(git log -1 --format='%ae')
git -c user.name="$NAME" -c user.email="$EMAIL" commit -m "feat(security-scan): harden to senior grade — setup-python-deps, CodeQL, dep-review, OPA, dual-gate, pin trivy"
```

---

### Task 2: Add a smoke caller for deferred validation

**Files:**
- Create: `.github/workflows/_smoke-security-scan.yml`

This is a same-repo caller used to validate the reusable once `dev` is pushed (it cannot run locally — the `@dev` composite refs resolve only on GitHub). `dependency-review` is disabled here because it requires a real PR event.

- [ ] **Step 1: Create the file**

```yaml
# Manual smoke for reusable-security-scan. Runnable only AFTER dev is pushed
# (the reusable references composites at adza-group/shared-workflows/...@dev,
# which must resolve remotely). Validates wiring + composite resolution, not
# deep app findings (use a real app caller in Phase 4 for that).
name: "🧪 Smoke — Security Scan"

on:
  workflow_dispatch:

permissions:
  contents: read
  security-events: write

jobs:
  security:
    uses: ./.github/workflows/reusable-security-scan.yml
    with:
      run-dependency-review: false   # needs a pull_request event
      run-pip-audit: false           # shared-workflows has no requirements.txt
      codeql-languages: '["javascript-typescript"]'  # no python app here
    secrets: inherit
```

- [ ] **Step 2: Static-validate**

Run: `./bin/actionlint.exe .github/workflows/_smoke-security-scan.yml && python -m yamllint -d relaxed .github/workflows/_smoke-security-scan.yml`
Expected: exit 0 both (line-length warnings ok).

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/_smoke-security-scan.yml
NAME=$(git log -1 --format='%an'); EMAIL=$(git log -1 --format='%ae')
git -c user.name="$NAME" -c user.email="$EMAIL" commit -m "ci(security-scan): add deferred smoke caller (_smoke-security-scan.yml)"
```

---

### Task 3 (DEFERRED — requires push, per the local-only decision)

**Do NOT run now.** When `dev` is pushed to GitHub (together with the Phase 1 composites, so the `@dev` refs resolve), validate:

- [ ] Push `dev`, then `gh workflow run _smoke-security-scan.yml --ref dev` and `gh run watch <id> --exit-status`.
- [ ] Confirm: `gitleaks`, `bandit`, `semgrep`, `trivy`, `codeql (javascript-typescript)`, `opa` jobs run; the `setup-python-deps@dev` and `opa-policy@dev` composite refs resolve (no "action not found"); jobs are non-blocking on `dev` (advisory) and the workflow concludes green.
- [ ] Deep functional validation happens when a pilot app (FootballApp, Phase 4) calls the reusable on `dev`.

---

## Self-Review

**1. Spec coverage (§5.2 "extend security-scan"):** setup-python swap → setup-python-deps ✓ (bandit/semgrep/pip-audit jobs); CodeQL py+js on ubuntu ✓; dependency-review PR-only ✓; OPA ✓; dual-gate on bandit/semgrep/trivy/pip-audit/codeql/opa ✓; trivy `@master` pinned to `@ed142fd0…` ✓; gitleaks stays hard ✓. `run-*` toggles added for every job ✓. Matches §6 dual-gate + pinning policy.

**2. Placeholder scan:** No TBD/TODO. trivy SHA is concrete (`ed142fd0673e97e23eac54620cfb913e5ce36c25`). Composite refs are concrete (`@dev`). The deferred Task 3 is explicitly a post-push step, not a placeholder in the current build.

**3. Type/expression consistency:** The dual-gate expression is identical everywhere (`!(github.ref == 'refs/heads/main' || startsWith(github.ref, 'refs/tags/'))` for continue-on-error; the `&& '1' || '0'` / `&& 'true' || 'false'` ternaries for trivy exit-code and opa blocking). `runner-label` is consumed via `fromJSON` in every self-hosted job; `codeql-languages` via `fromJSON` in the matrix. Composite input names (`install-requirements`, `extra-packages`, `cache-key-suffix`, `blocking`) match the Phase 1 composite definitions. checkout SHA matches the repo's existing pin.

**Note:** CodeQL/Trivy/Semgrep/Bandit/pip-audit being advisory on `dev` means the smoke run (on `dev`) will be green even if findings exist — that is intended; blocking only kicks in on `main`/tags.
