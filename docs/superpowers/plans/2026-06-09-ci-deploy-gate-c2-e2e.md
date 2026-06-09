# Deploy-Gate-Härtung + C2 + e2e Phase G — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Audit-getriebene Härtung der Unified-CI: harte Gates real in den Deploy-Pfad hängen (C1-It.1), Opt-in-Version-Assert (C2), Flaky-Rerun-Fix (B1), neuer hermetischer e2e-Job (Phase G), Doc-Korrektur.

**Architecture:** Edits an `reusable-ci.yml` (Gating + Wiring), `run-pytest-shard` (B1) und `health-check` (C2); ein neues Reusable `reusable-e2e.yml` (Playwright-Container + `start-app`-Boot, opt-in, dual-gate) + Smoke + Fixture. Default-off ⇒ kein Verhaltenswechsel für nicht-opt-in Apps. Spec→`v1.6.0`→`@v1`-force-move; dev→main user-gated.

**Tech Stack:** GitHub Actions (reusable workflows + composite actions), bash, Python/pytest, Playwright (`mcr.microsoft.com/playwright`), conftest/actionlint/yamllint.

**Validierungs-Konvention (statt klassischem TDD):** „Test" = `./bin/actionlint.exe <wf>` (exit 0) + `python -m yamllint -d relaxed <wf>` lokal, dann Ubuntu-Smoke via temporärem `push:[dev]`-Trigger + `gh run watch <id> --exit-status`, Trigger danach zurücknehmen (Repo-CLAUDE.md §„Wie man ein Stück auf ubuntu validiert"). Commits mit Log-Identität (Gotcha #8): `NAME=$(git log -1 --format='%an'); EMAIL=$(git log -1 --format='%ae'); git -c user.name="$NAME" -c user.email="$EMAIL" commit …`.

---

## File Structure

| Datei | Art | Verantwortung |
|---|---|---|
| `.github/actions/run-pytest-shard/action.yml` | modify | B1: korrektes Paket `pytest-rerunfailures` + sichtbarer Warn |
| `.github/actions/health-check/action.yml` | modify | C2: `expected-version`/`version-url`-Inputs + Assert-Step (env-basiert, kein `${{ }}` in `run:`) |
| `.github/workflows/reusable-ci.yml` | modify | C1: coverage dual + `docker-build.needs`/Guard; C2: durchreichen; Phase G: `e2e`-Job + Inputs + telemetry |
| `.github/workflows/reusable-e2e.yml` | **create** | Phase G Reusable (Playwright-Container, Postgres/Redis, start-app, dual-gate) |
| `.github/workflows/_smoke-e2e.yml` | **create** | Ubuntu-Smoke gegen Fixture |
| `tests/fixtures/e2e/app.py` | **create** | Mini-Flask mit `/health` (inkl. SHA für C2) + 1 Seite |
| `tests/fixtures/e2e/requirements.txt` | **create** | flask + gunicorn |
| `tests/fixtures/e2e/package.json` | **create** | `@playwright/test` (Version = Image-Pin) |
| `tests/fixtures/e2e/playwright.config.ts` | **create** | baseURL localhost, retries 2 |
| `tests/fixtures/e2e/e2e/smoke.spec.ts` | **create** | 1 trivialer Test |
| `docs/superpowers/specs/2026-06-03-senior-ci-powerup-design.md` | modify | Phase G ergänzen |
| `CLAUDE.md` | modify | A–F verifiziert; Phase G + C1-It.2 + C2-Contract als Resume-Punkte |
| `README.md` | modify | C2-App-Contract + e2e-Caller-Inputs + PR-only-to-main-Pflicht |

**Pin-Konstante (an einer Stelle entscheiden, überall gleich):** `PLAYWRIGHT_IMAGE = mcr.microsoft.com/playwright:v1.49.1-jammy` und `@playwright/test@1.49.1`. Vor Task 4 mit `docker manifest inspect mcr.microsoft.com/playwright:v1.49.1-jammy` Existenz bestätigen; bei Drift neueste `vX.Y.Z-jammy` nehmen und beide Stellen identisch setzen.

---

## Task 1: B1 — Flaky-Rerun-Paketname

**Files:**
- Modify: `.github/actions/run-pytest-shard/action.yml:52-57`

- [ ] **Step 1: Edit — Paketname korrigieren + sichtbarer Warn**

Ersetze den Rerun-Block (aktuell Z. 52-57):

```yaml
        # Flaky mitigation: rerun failed tests (pytest-rerunfailures). Reruns appear in junit.
        RERUN=()
        if [ "${{ inputs.test-reruns }}" != "0" ]; then
          pip install -q pytest-rerunfailures || echo "::warning::pytest-rerunfailures install failed — flaky reruns disabled"
          if python -c "import pytest_rerunfailures" 2>/dev/null; then
            RERUN=(--reruns "${{ inputs.test-reruns }}" --reruns-delay 1)
          else
            echo "::warning::pytest_rerunfailures not importable — running WITHOUT --reruns"
          fi
        fi
```

(Einzige inhaltliche Änderung ggü. heute: `pytest-rerun-failures` → `pytest-rerunfailures`; plus den stillen Pfad in eine sichtbare `::warning::` umgewandelt.)

- [ ] **Step 2: Lint**

Run: `python -m yamllint -d relaxed .github/actions/run-pytest-shard/action.yml`
Expected: keine Errors (Warnings ok).

- [ ] **Step 3: Commit**

```bash
git add .github/actions/run-pytest-shard/action.yml
git -c user.name="$(git log -1 --format='%an')" -c user.email="$(git log -1 --format='%ae')" \
  commit -m "fix(ci): correct flaky-rerun package to pytest-rerunfailures (B1)

pytest-rerun-failures (hyphen) does not exist on PyPI (404); canonical is
pytest-rerunfailures. The silent '|| echo warning' masked the failed install
so --reruns was never applied. Fixes the no-op flaky-mitigation from v1.5.0."
```

> Funktionale Verifikation erfolgt in Task 6 (Smoke-Shard mit absichtlich flaky Test → Junit zeigt Reruns).

---

## Task 2: C2 — Version-Assert im health-check

**Files:**
- Modify: `.github/actions/health-check/action.yml` (Inputs + neuer Step nach „Security headers")

- [ ] **Step 1: Zwei Inputs ergänzen** (unter `expected-status`, vor `outputs:`)

```yaml
  expected-version:
    description: "If set (e.g. github.sha), assert the running app reports this version/sha. Empty = skip (legacy 200-only)."
    required: false
    default: ""
  version-url:
    description: "URL that returns the running version (JSON .sha/.version or X-App-Version header). Empty = use 'url'."
    required: false
    default: ""
```

- [ ] **Step 2: Assert-Step anhängen** (als letzter Step unter `runs.steps`, env-basiert — kein `${{ }}` direkt im Script, Defense-in-Depth gegen Script-Injection):

```yaml
    - name: Version assert (running image == built image)
      if: inputs.expected-version != ''
      shell: bash
      env:
        EXPECTED: ${{ inputs.expected-version }}
        VURL: ${{ inputs.version-url != '' && inputs.version-url || inputs.url }}
      run: |
        BODY=$(curl -s --max-time 10 "$VURL" 2>/dev/null || echo "")
        HDR=$(curl -sI --max-time 10 "$VURL" 2>/dev/null | tr -d '\r' \
              | awk -F': ' 'tolower($1)=="x-app-version"{print $2}')
        GOT=$(printf '%s' "$BODY" | python3 -c \
          "import sys,json
try:
    d=json.load(sys.stdin); print(d.get('sha') or d.get('version') or '')
except Exception:
    print('')" 2>/dev/null || true)
        [ -z "$GOT" ] && GOT="$HDR"
        if [ -z "$GOT" ]; then
          echo "::error::version-assert: no sha/version at $VURL (expected ${EXPECTED:0:7}). App must expose it — see README 'Version App-Contract'."
          exit 1
        fi
        if [ "${GOT:0:7}" != "${EXPECTED:0:7}" ]; then
          echo "::error::Watchtower has not deployed the new image: running ${GOT:0:7}, expected ${EXPECTED:0:7}"
          exit 1
        fi
        echo "✅ running version ${GOT:0:7} matches expected ${EXPECTED:0:7}"
```

- [ ] **Step 3: Lint**

Run: `python -m yamllint -d relaxed .github/actions/health-check/action.yml`
Expected: keine Errors.

- [ ] **Step 4: Commit**

```bash
git add .github/actions/health-check/action.yml
git -c user.name="$(git log -1 --format='%an')" -c user.email="$(git log -1 --format='%ae')" \
  commit -m "feat(ci): opt-in version-assert in health-check (C2)

verify only asserted HTTP 200 -> green against the OLD image when Watchtower
had not pulled yet. New expected-version/version-url inputs assert running
sha == github.sha when set; empty = legacy 200-only (inert until apps expose
the version). Closes the Watchtower-403 false-green gap."
```

---

## Task 3: C1 (Iteration 1) — harte Gates in den Deploy-Pfad

**Files:**
- Modify: `.github/workflows/reusable-ci.yml` (coverage-Job ~Z.482-503; docker-build-Job ~Z.623-648)

- [ ] **Step 1: Total-Coverage-Gate dual machen**

Im `coverage`-Job den `coverage-gate`-Aufruf ändern — `blocking` von `"true"` auf dual:

```yaml
      - uses: adza-group/shared-workflows/.github/actions/coverage-gate@v1
        with:
          threshold: ${{ inputs.coverage-threshold }}
          blocking: ${{ github.ref == 'refs/heads/main' || startsWith(github.ref, 'refs/tags/') }}
          diff-coverage-threshold: ${{ inputs.diff-coverage-threshold }}
          diff-coverage-compare-branch: "origin/main"
          diff-coverage-blocking: ${{ github.ref == 'refs/heads/main' || startsWith(github.ref, 'refs/tags/') }}
```

(`coverage-gate` akzeptiert `blocking` als String; GHA serialisiert den Bool-Ausdruck zu `"true"`/`"false"` — die Composite vergleicht `= "true"`, passt.)

- [ ] **Step 2: docker-build — needs + Guard erweitern**

`needs` ergänzen:

```yaml
    needs: [changes, lint-python, test-matrix, security, coverage, e2e]
```

`if`-Guard erweitern (security hart-dual via Job-Result, coverage/e2e erlauben skipped):

```yaml
    if: >-
      ${{ always() &&
      needs.lint-python.result != 'failure' &&
      needs.security.result == 'success' &&
      needs.coverage.result != 'failure' &&
      needs.e2e.result != 'failure' &&
      (needs.test-matrix.result == 'success' || needs.test-matrix.result == 'skipped') &&
      (needs.changes.outputs.any_code == 'true' || needs.changes.outputs.docker == 'true' || needs.changes.outputs.ci == 'true') }}
```

> Begründung der Operatoren: `security.result == 'success'` blockt bei gitleaks (immer) + bandit-HIGH (nur main; Rest `continue-on-error` ⇒ Job grün). `security` läuft immer wenn docker-build läuft (beide auf `any_code||…`), skippt also nicht. `coverage`/`e2e` `!= 'failure'` lassen `skipped` (Nicht-Python-Diff bzw. `enable-e2e:false`) durch und blocken nur echten Fail. R1-Smoke (Task 6) prüft alle Change-Pfade.

- [ ] **Step 3: Lint**

Run: `./bin/actionlint.exe .github/workflows/reusable-ci.yml`
Expected: exit 0 (der `e2e`-Job wird in Task 5 hinzugefügt; bis dahin meldet actionlint „needs 'e2e' not defined" — **diesen Commit erst nach Task 5 zusammen lint-clean machen**, siehe Step 4).

- [ ] **Step 4: Commit (zusammen mit Task 5)**

> C1-Step-2 referenziert den `e2e`-Job, der erst in Task 5 entsteht. Reihenfolge: Task 3 Step 1 (coverage dual) separat committen; Task 3 Step 2 (docker-build needs/guard) **gemeinsam** mit Task 5 committen, damit der Tree nie auf eine undefinierte `needs`-Referenz zeigt.

Commit nur für Step 1:
```bash
git add .github/workflows/reusable-ci.yml
git -c user.name="$(git log -1 --format='%an')" -c user.email="$(git log -1 --format='%ae')" \
  commit -m "feat(ci): make total-coverage gate dual (advisory dev, hard main) (C1)"
```

---

## Task 4: Phase G — reusable-e2e.yml

**Files:**
- Create: `.github/workflows/reusable-e2e.yml`

- [ ] **Step 1: Image-Pin bestätigen**

Run: `docker manifest inspect mcr.microsoft.com/playwright:v1.49.1-jammy >/dev/null && echo OK`
Expected: `OK`. Bei Fehler: neueste `vX.Y.Z-jammy` ermitteln und in diesem File **und** `tests/fixtures/e2e/package.json` (Task 6) identisch setzen.

- [ ] **Step 2: Datei anlegen**

```yaml
# ═══════════════════════════════════════════════════════════════
# Reusable e2e (Playwright) — ADZA-Group
# Pre-merge, hermetic: postgres+redis services → start-app boot → Playwright vs localhost.
# Runs INSIDE the Playwright container (browsers + deps preinstalled). In a container job,
# services are reachable at <label>:<port> (postgres:5432 / redis:6379), per-job network
# (no cross-shard collision). Dual-gate: advisory PR/dev, hard main/tags.
#
# Usage:
#   uses: adza-group/shared-workflows/.github/workflows/reusable-e2e.yml@v1
#   with: { boot-command: "...", health-url: "http://localhost:8000/health" }
#   secrets: inherit
# ═══════════════════════════════════════════════════════════════
name: "🎭 E2E"

on:
  workflow_call:
    inputs:
      runner-label:
        required: false
        type: string
        default: '["self-hosted", "linux", "proxmox"]'
      python-version:
        required: false
        type: string
        default: "3.11"
      postgres-version:
        required: false
        type: string
        default: "16-alpine"
      playwright-image:
        required: false
        type: string
        default: "mcr.microsoft.com/playwright:v1.49.1-jammy"
      boot-command:
        required: true
        type: string
        description: "Foreground command starting the app (uses the venv on PATH)"
      health-url:
        required: true
        type: string
        description: "Health URL polled before tests (localhost:<port>)"
      e2e-dir:
        required: false
        type: string
        default: "e2e"
        description: "Directory holding package.json + Playwright config/specs"
      e2e-command:
        required: false
        type: string
        default: "npx playwright test"
      test-env:
        required: false
        type: string
        default: "{}"
      install-system-deps:
        required: false
        type: boolean
        default: false

permissions:
  contents: read

jobs:
  e2e:
    name: "🎭 Playwright"
    runs-on: ${{ fromJSON(inputs.runner-label) }}
    timeout-minutes: 25
    container:
      image: ${{ inputs.playwright-image }}
    services:
      postgres:
        image: postgres:${{ inputs.postgres-version }}
        env:
          POSTGRES_USER: postgres
          POSTGRES_PASSWORD: postgres
          POSTGRES_DB: test
        options: >-
          --health-cmd "pg_isready -U postgres"
          --health-interval 5s --health-timeout 5s --health-retries 10
      redis:
        image: redis:7-alpine
        options: >-
          --health-cmd "redis-cli ping"
          --health-interval 5s --health-timeout 5s --health-retries 10
    steps:
      - name: Provision container (git + python)
        run: |
          apt-get update -qq
          DEBS="git python3-venv python3-pip"
          if [ "${{ inputs.install-system-deps }}" = "true" ]; then
            DEBS="$DEBS tesseract-ocr tesseract-ocr-deu tesseract-ocr-fra poppler-utils"
          fi
          apt-get install -y -qq --no-install-recommends $DEBS

      - uses: actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5  # v4

      - name: Load test env (container networking: localhost -> service host)
        env:
          TEST_ENV: ${{ inputs.test-env }}
        run: |
          # In a container job services resolve by label hostname on their container port.
          python3 - <<'PY' >> "$GITHUB_ENV"
          import json, os
          for k, v in json.loads(os.environ.get('TEST_ENV') or '{}').items():
              if isinstance(v, str):
                  v = (v.replace('localhost:5432', 'postgres:5432')
                        .replace('127.0.0.1:5432', 'postgres:5432')
                        .replace('localhost:6379', 'redis:6379')
                        .replace('127.0.0.1:6379', 'redis:6379'))
              print(f"{k}={v}")
          PY

      - name: Python venv + requirements
        run: |
          python3 -m venv /tmp/e2e-venv
          echo "/tmp/e2e-venv/bin" >> "$GITHUB_PATH"
          /tmp/e2e-venv/bin/pip install --upgrade pip --retries 3 --timeout 60
          if [ -f requirements.txt ]; then
            /tmp/e2e-venv/bin/pip install --retries 3 --timeout 60 -r requirements.txt
          fi

      - uses: adza-group/shared-workflows/.github/actions/start-app@v1
        with:
          boot-command: ${{ inputs.boot-command }}
          health-url: ${{ inputs.health-url }}
          max-retries: "60"
          retry-delay: "2"

      - name: Install Playwright test deps (browsers preinstalled in image)
        working-directory: ${{ inputs.e2e-dir }}
        run: |
          if [ -f package-lock.json ]; then npm ci; else npm install; fi

      - name: Run Playwright (dual-gate)
        working-directory: ${{ inputs.e2e-dir }}
        continue-on-error: ${{ !(github.ref == 'refs/heads/main' || startsWith(github.ref, 'refs/tags/')) }}
        env:
          E2E_CMD: ${{ inputs.e2e-command }}
        run: |
          eval "$E2E_CMD --retries=2"

      - name: Upload Playwright report
        if: always()
        uses: actions/upload-artifact@65c4c4a1ddee5b72f698fdd19549f0f0fb45cf08  # v4.6.0
        continue-on-error: true
        with:
          name: playwright-report
          path: ${{ inputs.e2e-dir }}/playwright-report
          retention-days: 7
```

- [ ] **Step 3: Lint**

Run: `./bin/actionlint.exe .github/workflows/reusable-e2e.yml`
Expected: exit 0.

> Commit erfolgt zusammen mit Task 5 (Orchestrator-Wiring), damit der `e2e`-Job-Verweis in docker-build/telemetry und das Reusable im selben Commit landen.

---

## Task 5: Phase G — Orchestrator-Wiring + finaler C1-Commit

**Files:**
- Modify: `.github/workflows/reusable-ci.yml` (Inputs; neuer `e2e`-Job; telemetry.needs + Summary)

- [ ] **Step 1: e2e-Inputs ergänzen** (im `workflow_call.inputs`-Block, bei den anderen enable-*-Inputs)

```yaml
      enable-e2e:
        required: false
        type: boolean
        default: false
        description: "Enable the pre-merge Playwright e2e job (opt-in; needs e2e-boot-command + e2e-health-url)"
      e2e-boot-command:
        required: false
        type: string
        default: ""
        description: "Foreground command to start the app for e2e (uses the venv on PATH)"
      e2e-health-url:
        required: false
        type: string
        default: ""
        description: "Health URL polled before e2e (localhost:<port>)"
      e2e-dir:
        required: false
        type: string
        default: "e2e"
      e2e-command:
        required: false
        type: string
        default: "npx playwright test"
      staging-version-url:
        required: false
        type: string
        default: ""
        description: "C2: URL reporting running version on staging (empty = 200-only verify)"
      prod-version-url:
        required: false
        type: string
        default: ""
        description: "C2: URL reporting running version on prod (empty = 200-only verify)"
```

- [ ] **Step 2: e2e-Job hinzufügen** (nach dem `api-contract`-Job)

```yaml
  e2e:
    name: "🎭 E2E"
    needs: [changes, test-matrix]
    if: >-
      ${{ inputs.enable-e2e && inputs.e2e-boot-command != '' &&
      needs.test-matrix.result == 'success' &&
      (needs.changes.outputs.python == 'true' || needs.changes.outputs.frontend == 'true' || needs.changes.outputs.ci == 'true') }}
    permissions:
      contents: read
    uses: adza-group/shared-workflows/.github/workflows/reusable-e2e.yml@v1
    with:
      runner-label: ${{ inputs.runner-label }}
      python-version: ${{ inputs.python-version }}
      postgres-version: ${{ inputs.postgres-version }}
      boot-command: ${{ inputs.e2e-boot-command }}
      health-url: ${{ inputs.e2e-health-url }}
      e2e-dir: ${{ inputs.e2e-dir }}
      e2e-command: ${{ inputs.e2e-command }}
      test-env: ${{ inputs.test-env }}
      install-system-deps: ${{ inputs.install-system-deps }}
    secrets: inherit
```

- [ ] **Step 3: C2 in verify-staging/verify-prod durchreichen**

Im `verify-staging`-Job den `health-check`-Aufruf um die zwei Inputs erweitern:

```yaml
      - uses: adza-group/shared-workflows/.github/actions/health-check@v1
        id: staging-check
        continue-on-error: true
        with:
          url: ${{ inputs.staging-url }}
          max-retries: "40"
          retry-delay: "30"
          check-security-headers: "true"
          version-url: ${{ inputs.staging-version-url }}
          expected-version: ${{ inputs.staging-version-url != '' && github.sha || '' }}
```

Im `verify-prod`-Job analog (mit `prod-version-url`):

```yaml
      - uses: adza-group/shared-workflows/.github/actions/health-check@v1
        id: prod-check
        continue-on-error: true
        with:
          url: ${{ inputs.prod-url }}
          max-retries: "40"
          retry-delay: "30"
          version-url: ${{ inputs.prod-version-url }}
          expected-version: ${{ inputs.prod-version-url != '' && github.sha || '' }}
```

- [ ] **Step 4: telemetry — e2e in needs + Summary**

In `telemetry.needs` `e2e` ergänzen (in die große Liste) und eine Summary-Zeile hinzufügen:

```yaml
            echo "| e2e | ${{ needs.e2e.result }} |"
```

- [ ] **Step 5: Lint (jetzt vollständig)**

Run: `./bin/actionlint.exe .github/workflows/reusable-ci.yml .github/workflows/reusable-e2e.yml`
Expected: exit 0 (kein „needs 'e2e' not defined" mehr).
Run: `python -m yamllint -d relaxed .github/workflows/reusable-ci.yml .github/workflows/reusable-e2e.yml`
Expected: keine Errors.

- [ ] **Step 6: Commit (Task 3-Step-2 + Task 4 + Task 5 gemeinsam)**

```bash
git add .github/workflows/reusable-ci.yml .github/workflows/reusable-e2e.yml
git -c user.name="$(git log -1 --format='%an')" -c user.email="$(git log -1 --format='%ae')" \
  commit -m "feat(ci): pre-merge Playwright e2e (Phase G) + wire hard gates into deploy (C1)

- new reusable-e2e.yml: Playwright container + postgres/redis + start-app boot,
  dual-gate (advisory dev, hard main), opt-in via enable-e2e
- reusable-ci.yml: e2e job + inputs + telemetry; docker-build now needs
  security+coverage+e2e (push blocked unless hard gates green); C2 version-url
  passthrough to verify-staging/prod"
```

---

## Task 6: Phase G — Fixture + Smoke + Ubuntu-Validierung

**Files:**
- Create: `tests/fixtures/e2e/{app.py,requirements.txt,package.json,playwright.config.ts,e2e/smoke.spec.ts}`
- Create: `.github/workflows/_smoke-e2e.yml`

- [ ] **Step 1: Fixture-App** — `tests/fixtures/e2e/app.py`

```python
import os
from flask import Flask, jsonify

app = Flask(__name__)
APP_SHA = os.environ.get("APP_SHA", "deadbeefcafe")


@app.get("/health")
def health():
    # C2 contract: expose the running git sha
    return jsonify(status="ok", sha=APP_SHA)


@app.get("/")
def index():
    return "<h1 id='title'>ADZA e2e fixture</h1>", 200
```

- [ ] **Step 2: Fixture deps** — `tests/fixtures/e2e/requirements.txt`

```
flask==3.*
gunicorn==23.*
```

- [ ] **Step 3: package.json** — `tests/fixtures/e2e/package.json` (Version == Image-Pin aus Task 4)

```json
{
  "name": "adza-e2e-fixture",
  "private": true,
  "devDependencies": {
    "@playwright/test": "1.49.1"
  }
}
```

- [ ] **Step 4: Playwright config** — `tests/fixtures/e2e/playwright.config.ts`

```typescript
import { defineConfig } from "@playwright/test";

export default defineConfig({
  testDir: "./e2e",
  retries: 2,
  use: { baseURL: process.env.E2E_BASE_URL || "http://localhost:8000" },
});
```

- [ ] **Step 5: Spec** — `tests/fixtures/e2e/e2e/smoke.spec.ts`

```typescript
import { test, expect } from "@playwright/test";

test("home page renders title", async ({ page }) => {
  await page.goto("/");
  await expect(page.locator("#title")).toHaveText("ADZA e2e fixture");
});

test("health reports sha", async ({ request }) => {
  const res = await request.get("/health");
  expect(res.ok()).toBeTruthy();
  const body = await res.json();
  expect(body.sha).toBeTruthy();
});
```

- [ ] **Step 6: Smoke-Workflow** — `.github/workflows/_smoke-e2e.yml`

```yaml
name: "🔥 smoke: e2e"
on:
  workflow_dispatch: {}
  # TEMP for validation (remove after green):
  push: { branches: [dev], paths: [".github/workflows/reusable-e2e.yml", ".github/workflows/_smoke-e2e.yml", "tests/fixtures/e2e/**"] }

permissions:
  contents: read

jobs:
  e2e:
    uses: ./.github/workflows/reusable-e2e.yml
    with:
      runner-label: '["ubuntu-latest"]'
      boot-command: "gunicorn -w 1 -b 127.0.0.1:8000 app:app --chdir tests/fixtures/e2e"
      health-url: "http://localhost:8000/health"
      e2e-dir: "tests/fixtures/e2e"
    secrets: inherit
```

> Hinweis: `uses: ./…` ist hier korrekt, weil der Smoke im SELBEN Repo (shared-workflows) liegt — Gotcha #1 betrifft nur Reusables, die von fremden Caller-Repos genutzt werden.

- [ ] **Step 7: Lint**

Run: `./bin/actionlint.exe .github/workflows/_smoke-e2e.yml`
Expected: exit 0.

- [ ] **Step 8: Commit + Push (Smoke feuert)**

```bash
git add tests/fixtures/e2e .github/workflows/_smoke-e2e.yml
git -c user.name="$(git log -1 --format='%an')" -c user.email="$(git log -1 --format='%ae')" \
  commit -m "test(ci): e2e smoke fixture + _smoke-e2e (ubuntu validation)"
git push origin dev
```

- [ ] **Step 9: Watch Smoke**

Run: `gh run watch "$(gh run list --workflow=_smoke-e2e.yml --branch dev --limit 1 --json databaseId --jq '.[0].databaseId')" --exit-status`
Expected: success — Playwright-Step grün, beide Tests pass, Report-Artefakt hochgeladen.
Bei Fehler: `gh run view <id> --log-failed` → fix (häufig: Image-Pin-Mismatch package.json↔container, oder git fehlt im Image → Step-1-apt-get prüfen) → re-push.

- [ ] **Step 10: B1- + Coverage-Re-Validierung (bestehende Smokes)**

Run: `gh workflow run _smoke-ci.yml --ref dev` (falls vorhanden) → `gh run watch <id> --exit-status`.
Expected: alle Change-Pfade (python-only / docker-only / frontend-only / ci-only) → docker-build verhält sich korrekt (R1): bei python-only laufen security+coverage+(e2e disabled→skipped) und docker-build baut; bei docker-only test-matrix/coverage skipped, security läuft, docker-build baut.
> Falls `_smoke-ci.yml` nicht alle Pfade abdeckt: manuell je ein Dummy-Commit pro Pfad auf dev, oder im Smoke-Caller `enable-e2e:true` + dummy-boot setzen, um den e2e-Gate-Pfad zu prüfen.

- [ ] **Step 11: Temp-Trigger zurücknehmen**

`_smoke-e2e.yml`: den `push:`-Block entfernen (nur `workflow_dispatch` lassen).
```bash
git add .github/workflows/_smoke-e2e.yml
git -c user.name="$(git log -1 --format='%an')" -c user.email="$(git log -1 --format='%ae')" \
  commit -m "ci: revert temp push trigger on _smoke-e2e (dispatch-only)"
```

---

## Task 7: Doc-Korrektur

**Files:**
- Modify: `docs/superpowers/specs/2026-06-03-senior-ci-powerup-design.md`
- Modify: `CLAUDE.md`
- Modify: `README.md`

- [ ] **Step 1: Power-up-Spec — Phase G ergänzen**

In die Phasen-Liste der Power-up-Spec aufnehmen (am Ende der Phasen-Aufzählung):

```markdown
### Phase G — e2e (Playwright, pre-merge) [NACHGETRAGEN 2026-06-09]

Beim Original-Audit übersehen: RecyclageApp hatte vor der P4-Migration eine Playwright-Suite
(commit 0af76c9), die beim Umstieg auf den thin caller (b176c29) verloren ging. Phase G stellt
sie als opt-in Unified-Job wieder her: `reusable-e2e.yml` (Playwright-Container + start-app-Boot,
postgres/redis, dual-gate). Aktivierung per-App via `enable-e2e` + `e2e-boot-command` + Playwright-Specs.
Design: docs/superpowers/specs/2026-06-09-ci-deploy-gate-c2-e2e-design.md.
```

- [ ] **Step 2: CLAUDE.md — Stand korrigieren**

Im Kopf-Handoff ergänzen (nach der „CI-POWER-UP KOMPLETT (A–F)"-Zeile):

```markdown
> **✅ 2026-06-09 VERIFIZIERT (Audit + git):** A–F sind real released — `git tag` zeigt v1.5.0–v1.5.7,
> `v1`→v1.5.7. api-contract (Phase D) ist gebaut + verdrahtet (skippt nur mangels App-OpenAPI-Spec).
> **NEU auf dev (Audit-Härtung, Spec 2026-06-09-ci-deploy-gate-c2-e2e):** B1 (pytest-rerunfailures-Fix),
> C1-It.1 (security+coverage+e2e in docker-build.needs, coverage dual), C2 (opt-in version-assert),
> Phase G (reusable-e2e.yml, opt-in). **OFFEN (Resume):** C1-It.2 = Candidate-Tag-Promotion (echtes
> Staging→Prod-Gate; :latest wird noch im build-Job gepusht); C2/e2e App-Aktivierung pro Repo
> (/health-SHA bzw. Playwright-Specs); PR-only-to-main als Branch-Protection-Pflicht durchsetzen.
```

- [ ] **Step 3: README.md — Caller-Contract erweitern**

Unter „Consuming reusable-ci.yml" / CAVEATS ergänzen:

```markdown
### Version App-Contract (C2, opt-in)
Damit `verify-staging`/`verify-prod` prüfen, dass das NEUE Image läuft (nicht nur HTTP 200), muss die App
ihre Git-SHA ausgeben: `GET /health → {"status":"ok","sha":"<GIT_SHA>"}` (oder Header `X-App-Version`).
SHA via Docker-Build-Arg/ENV ins Image. Dann im Caller `staging-version-url`/`prod-version-url` setzen —
ohne diese Inputs bleibt das Verhalten 200-only (inert).

### e2e (Phase G, opt-in)
`enable-e2e: true` + `e2e-boot-command` + `e2e-health-url` + Playwright-Specs unter `e2e/` (package.json
pinnt @playwright/test passend zum Container-Image). Läuft pre-merge hermetisch (postgres/redis + start-app),
dual-gate (advisory dev, hart main).

### Branch-Pflicht (C1)
`main` NUR per PR befüllen (kein `git push` direkt). Branch-Protection-Required-Checks müssen
`gitleaks`, `bandit`, `coverage`, `test-matrix` listen — die Workflow-DAG gatet den GHCR-Push erst seit
C1-It.1 mit, der vollständige Staging→Prod-Gate kommt mit C1-It.2 (Candidate-Promotion).
```

- [ ] **Step 4: Lint Markdown (optional) + Commit**

```bash
git add docs/superpowers/specs/2026-06-03-senior-ci-powerup-design.md CLAUDE.md README.md
git -c user.name="$(git log -1 --format='%an')" -c user.email="$(git log -1 --format='%ae')" \
  commit -m "docs(ci): track Phase G; mark A-F verified; C2/e2e/branch contracts"
```

---

## Task 8: Rollout (USER-GATED)

**Files:** keine (Tags + Push)

- [ ] **Step 1: Vorbedingung — alle Smokes grün**

Bestätige: `_smoke-e2e` grün, `_smoke-ci`/coverage/docker-build re-validiert (Task 6 Step 9-10).

- [ ] **Step 2: Push dev**

```bash
git push origin dev
```

- [ ] **Step 3: Verlust-Check vor @v1-Move**

```bash
git fetch origin --tags
git ls-remote origin refs/tags/v1
git log v1 --not dev --oneline   # Expected: leer (nichts auf v1, das nicht auf dev ist)
```

- [ ] **Step 4: Tag v1.6.0 + @v1 force-move** (nur wenn Step 3 leer)

```bash
git tag -a v1.6.0 -m "v1.6.0: deploy-gate C1-it.1 + C2 version-assert + B1 + e2e Phase G"
git push origin v1.6.0
git tag -f v1 v1.6.0
git push -f origin v1
git ls-remote origin refs/tags/v1   # verify points to v1.6.0 sha
```

- [ ] **Step 5: dev→main + Fleet-Aktivierung — DEM USER VORLEGEN**

> Default-off ⇒ kein Verhaltenswechsel für nicht-opt-in Apps. dev→main-Merge des shared-workflows-Repos
> und per-App-Opt-in (`enable-e2e`, `staging-version-url`) sind **User-Entscheidungen** — hier stoppen
> und vorlegen, NICHT autonom mergen (globale Branch-Workflow-Regel).

---

## Self-Review (gegen Spec)

**Spec-Coverage:** B1→T1 ✓ · C1-It.1 (coverage dual + needs/guard)→T3+T5 ✓ · C2→T2+T5-Step3 ✓ · Phase G (reusable+wiring+smoke+fixture)→T4+T5+T6 ✓ · Doc (spec+CLAUDE.md+README)→T7 ✓ · Rollout (v1.6.0+@v1, user-gated)→T8 ✓ · DEFERRED C1-It.2 + paid-gated → in Spec/Doc als offen markiert ✓.

**Placeholder-Scan:** Kein TBD/TODO; aller Code ausgeschrieben. Einzige bewusste Variable = Image/npm-Pin (`v1.49.1`), in T4-Step-1 mit konkretem Verifikations-Command + „bei Drift beide Stellen identisch setzen" geerdet.

**Typ-/Namens-Konsistenz:** Input-Namen identisch über Caller↔Reusable: `boot-command`/`health-url`/`e2e-dir`/`e2e-command`/`test-env`/`install-system-deps` (reusable-e2e) und `e2e-boot-command`/`e2e-health-url`/`enable-e2e`/`staging-version-url`/`prod-version-url` (orchestrator). `expected-version`/`version-url` konsistent health-check↔Caller. `docker-build.needs` und der `e2e`-Job-Name (`e2e`) stimmen überein. Commit-Reihenfolge verhindert undefinierte `needs`-Referenz (T3-Step2 + T4 + T5 gemeinsam).
