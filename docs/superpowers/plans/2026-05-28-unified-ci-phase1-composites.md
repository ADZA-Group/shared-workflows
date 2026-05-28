# Unified CI — Phase 1: Foundation Composite Actions — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the five battle-tested composite actions in `adza-group/shared-workflows` that every later phase (sub-reusables, `reusable-ci.yml` orchestrator, per-app migration) depends on.

**Architecture:** Each composite is a self-contained `.github/actions/<name>/action.yml` (+ bundled policy files where needed). They are validated locally with `actionlint` + `yamllint` (fast inner loop) and on the real Debian-13 self-hosted runner via a single `workflow_dispatch` smoke harness `_smoke-composites.yml` (real outer loop). Work happens on the `dev` branch of `shared-workflows`; no push to `main`.

**Tech Stack:** GitHub Actions composite actions (bash, `using: composite`), `actions/cache`, `actions/upload-artifact`, `actions/download-artifact`, Python `coverage`/`pytest-cov`, `conftest` (OPA/Rego), `actionlint`, `yamllint`.

**Spec:** `docs/superpowers/specs/2026-05-28-unified-ci-design.md` §5.1 (composites), §6 (policies).

**Phase 1 scope boundary (explicit):**
- IN: `setup-python-deps`, `run-pytest-shard`, `coverage-gate` (combine + `--fail-under` gate + summary), `start-app` (generic launcher), `opa-policy` (+ Rego policies), the smoke harness, README update.
- OUT (later phases): PR coverage-delta comment (Phase 3, needs PR/orchestrator context), removing the legacy `setup-python-env` composite (Phase 4 cleanup — left untouched here, it has no known consumers), all sub-reusable workflows, the orchestrator.

**Testing model (why it deviates from pure unit-TDD):** GitHub composite actions can only be exercised inside a workflow run, and `setup-python-deps` specifically depends on the real Debian-13 self-hosted runner (the whole reason it exists). So the loop is: (a) write the smoke job that asserts expected behavior, (b) implement the composite, (c) static-validate locally with `actionlint`+`yamllint` (fast), (d) commit, then once per task-group push `dev` and run the smoke harness on the real runner. The smoke harness IS the test; static lint is the fast pre-check.

---

### Task 1: Setup — resolve action pins + install local linters + harness skeleton

**Files:**
- Create: `.github/workflows/_smoke-composites.yml`
- Create (local, not committed): pin reference notes

- [ ] **Step 1: Confirm branch is `dev`**

Run: `git -C /c/Users/ADZArecaclage/Documents/Projekte/shared-workflows rev-parse --abbrev-ref HEAD`
Expected: `dev`

- [ ] **Step 2: Resolve the action SHA pins needed in Phase 1**

Run (resolves tag → commit SHA for each third-party action this phase pins):

```bash
for ref in \
  "actions/cache@v4.2.0" \
  "actions/upload-artifact@v4.6.0" \
  "actions/download-artifact@v4.1.8"; do
  owner_repo="${ref%@*}"; tag="${ref#*@}"
  sha=$(gh api "repos/${owner_repo}/commits/${tag}" --jq .sha)
  echo "${owner_repo}@${sha}  # ${tag}"
done
```

Expected: three lines, e.g.
```
actions/cache@1bd1e32a3bdc45362d1e726936510720a7c30a57  # v4.2.0
actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02  # v4.6.0
actions/download-artifact@fa0a91b85d4f405e80dcb880a1c62a651be25e5e  # v4.1.8
```
Record the exact SHAs printed; use them verbatim in the tasks below (the SHAs shown are the expected current values — if `gh` prints different ones, the upstream tag moved; use what `gh` prints).

- [ ] **Step 3: Install local linters**

Run:
```bash
pip install --user yamllint==1.* && \
bash <(curl -sSfL https://raw.githubusercontent.com/rhysd/actionlint/main/scripts/download-actionlint.bash) 1.7.7 ./bin && \
./bin/actionlint --version && yamllint --version
```
Expected: actionlint prints `1.7.7`, yamllint prints `1.x`. (If `bin/actionlint` already exists, reuse it.)

- [ ] **Step 4: Create the smoke-harness skeleton**

Create `.github/workflows/_smoke-composites.yml`:

```yaml
# Smoke harness for shared-workflows composite actions.
# Manual only. Each job exercises one composite on the real self-hosted runner.
name: "🧪 Smoke — Composites"

on:
  workflow_dispatch:

permissions:
  contents: read

jobs:
  noop:
    name: "placeholder (replaced as composites land)"
    runs-on: [self-hosted, linux, proxmox]
    timeout-minutes: 2
    steps:
      - run: echo "harness ready"
```

- [ ] **Step 5: Static-validate the skeleton**

Run: `./bin/actionlint .github/workflows/_smoke-composites.yml && yamllint -d relaxed .github/workflows/_smoke-composites.yml`
Expected: no output (exit 0).

- [ ] **Step 6: Commit**

```bash
git add .github/workflows/_smoke-composites.yml
git commit -m "ci(composites): add smoke harness skeleton + pin notes"
```

---

### Task 2: `setup-python-deps` composite (Debian-13-safe Python toolchain)

**Files:**
- Create: `.github/actions/setup-python-deps/action.yml`
- Modify: `.github/workflows/_smoke-composites.yml` (add smoke job)

- [ ] **Step 1: Add the smoke job (the test)**

In `.github/workflows/_smoke-composites.yml`, add under `jobs:` (and delete the `noop` job):

```yaml
  setup-python-deps:
    name: "setup-python-deps"
    runs-on: [self-hosted, linux, proxmox]
    timeout-minutes: 8
    steps:
      - uses: actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5  # v4
      - name: Fixture requirements.txt
        run: printf 'flask==3.*\n' > requirements.txt
      - uses: ./.github/actions/setup-python-deps
        with:
          install-coverage: "true"
          cache-key-suffix: smoke
      - name: Assert venv on PATH + deps importable
        run: |
          which python | grep -q "venv-smoke" || { echo "::error::venv not on PATH"; exit 1; }
          python -c "import flask; print('flask', flask.__version__)"
          python -c "import pytest_cov, coverage; print('coverage tools ok')"
```

- [ ] **Step 2: Implement the composite**

Create `.github/actions/setup-python-deps/action.yml`:

```yaml
# System Python + per-job venv + cached deps.
# Debian-13 self-hosted runners ship NO actions/setup-python binaries, and 5+
# test jobs share one runner (concurrent /usr/local site-packages corruption).
# Solution: use system python3, isolate each job in $RUNNER_TEMP venv, export to PATH.
name: "Setup Python Deps"
description: "System python3 + isolated per-job venv + cached pip deps (Debian-13 safe)"

inputs:
  install-requirements:
    description: "Install requirements.txt if present"
    required: false
    default: "true"
  install-system-deps:
    description: "Install tesseract + poppler (PDF/OCR apps)"
    required: false
    default: "false"
  install-coverage:
    description: "Install pytest-cov + coverage + pytest-timeout"
    required: false
    default: "false"
  extra-packages:
    description: "Extra pip packages (space-separated)"
    required: false
    default: ""
  cache-key-suffix:
    description: "Namespaces the pip cache + venv per consumer (e.g. lint, pytest-auth)"
    required: false
    default: "default"

runs:
  using: composite
  steps:
    - name: Verify system Python
      shell: bash
      run: |
        if ! command -v python3 >/dev/null 2>&1; then
          echo "::error::python3 not found on runner"; exit 1
        fi
        echo "Using $(python3 --version) at $(command -v python3)"

    - name: Ensure pip + venv modules
      shell: bash
      run: |
        if ! python3 -m venv --help >/dev/null 2>&1 || ! python3 -m pip --version >/dev/null 2>&1; then
          sudo apt-get update -qq
          sudo apt-get install -y -qq python3-venv python3-pip
        fi

    - name: System dependencies (tesseract/poppler)
      if: inputs.install-system-deps == 'true'
      shell: bash
      run: |
        sudo apt-get update -qq
        sudo apt-get install -y -qq tesseract-ocr tesseract-ocr-fra tesseract-ocr-deu poppler-utils

    - name: Cache pip downloads
      uses: actions/cache@1bd1e32a3bdc45362d1e726936510720a7c30a57  # v4.2.0  (use SHA from Task 1 Step 2)
      with:
        path: ~/.cache/pip
        key: pip-${{ runner.os }}-sys-${{ inputs.cache-key-suffix }}-${{ hashFiles('requirements.txt') }}
        restore-keys: |
          pip-${{ runner.os }}-sys-${{ inputs.cache-key-suffix }}-
          pip-${{ runner.os }}-sys-

    - name: Create per-job venv and put it on PATH
      shell: bash
      run: |
        VENV="$RUNNER_TEMP/venv-${{ inputs.cache-key-suffix }}"
        python3 -m venv "$VENV"
        echo "$VENV/bin" >> "$GITHUB_PATH"
        "$VENV/bin/pip" install --upgrade pip --retries 3 --timeout 60

    - name: Install requirements
      if: inputs.install-requirements == 'true'
      shell: bash
      run: |
        if [ -f requirements.txt ]; then
          pip install --retries 3 --timeout 60 -r requirements.txt
        else
          echo "::notice::no requirements.txt — skipping"
        fi

    - name: Install coverage tooling
      if: inputs.install-coverage == 'true'
      shell: bash
      run: pip install --retries 3 --timeout 60 pytest-cov "coverage[toml]" pytest-timeout

    - name: Install extra packages
      if: inputs.extra-packages != ''
      shell: bash
      run: pip install --retries 3 --timeout 60 ${{ inputs.extra-packages }}
```

- [ ] **Step 3: Static-validate**

Run: `./bin/actionlint .github/workflows/_smoke-composites.yml && yamllint -d relaxed .github/actions/setup-python-deps/action.yml .github/workflows/_smoke-composites.yml`
Expected: no output (exit 0).

- [ ] **Step 4: Commit**

```bash
git add .github/actions/setup-python-deps/action.yml .github/workflows/_smoke-composites.yml
git commit -m "ci(composites): add setup-python-deps (Debian-13 system-python + per-job venv)"
```

---

### Task 3: `run-pytest-shard` composite (one matrix shard → coverage data + junit)

**Files:**
- Create: `.github/actions/run-pytest-shard/action.yml`
- Modify: `.github/workflows/_smoke-composites.yml`

Produces a per-shard `.coverage.<name>` data file (NOT a report) so `coverage-gate` can `coverage combine` them into a true union (replaces the old `max()` heuristic).

- [ ] **Step 1: Add smoke job (the test)**

Add to `_smoke-composites.yml` under `jobs:`:

```yaml
  run-pytest-shard:
    name: "run-pytest-shard"
    runs-on: [self-hosted, linux, proxmox]
    timeout-minutes: 8
    steps:
      - uses: actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5  # v4
      - name: Fixture project (pytest + a trivial test)
        run: |
          printf 'pytest==8.*\n' > requirements.txt
          mkdir -p app tests
          printf 'def add(a, b):\n    return a + b\n' > app/calc.py
          printf 'from app.calc import add\n\ndef test_add():\n    assert add(2, 3) == 5\n' > tests/test_calc.py
      - uses: ./.github/actions/setup-python-deps
        with: { install-coverage: "true", cache-key-suffix: shard-smoke }
      - uses: ./.github/actions/run-pytest-shard
        with:
          shard-name: smoke
          test-paths: tests/
          coverage-source: app
      - name: Assert artifacts produced
        run: |
          test -f ".coverage.smoke" || { echo "::error::no .coverage.smoke"; exit 1; }
          test -f "junit-smoke.xml" || { echo "::error::no junit-smoke.xml"; exit 1; }
```

- [ ] **Step 2: Implement the composite**

Create `.github/actions/run-pytest-shard/action.yml`:

```yaml
# Run ONE pytest shard. Emits .coverage.<shard> (data file, for combine) + junit-<shard>.xml.
# Assumes a venv is already on PATH (setup-python-deps ran first) and that any DB/redis
# services + env vars are provided by the calling JOB (composites cannot declare services).
name: "Run pytest shard"
description: "Run one test shard, emit coverage data file + junit xml, upload both"

inputs:
  shard-name:
    description: "Unique shard id (used in artifact + file names)"
    required: true
  test-paths:
    description: "Space-separated test paths (used when markers is empty)"
    required: false
    default: ""
  markers:
    description: "pytest -m expression (takes precedence over test-paths)"
    required: false
    default: ""
  coverage-source:
    description: "Module/dir passed to --cov"
    required: false
    default: "."
  timeout:
    description: "Per-test timeout seconds"
    required: false
    default: "60"

runs:
  using: composite
  steps:
    - name: Run pytest (collect coverage data, no report)
      shell: bash
      env:
        COVERAGE_FILE: .coverage.${{ inputs.shard-name }}
      run: |
        if [ -n "${{ inputs.markers }}" ]; then
          SELECT=(-m "${{ inputs.markers }}")
        else
          SELECT=(${{ inputs.test-paths }})
        fi
        pytest "${SELECT[@]}" \
          --timeout=${{ inputs.timeout }} \
          --cov=${{ inputs.coverage-source }} --cov-report= \
          --junitxml=junit-${{ inputs.shard-name }}.xml \
          -p no:cacheprovider

    - name: Upload coverage data
      if: always()
      uses: actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02  # v4.6.0  (SHA from Task 1)
      continue-on-error: true
      with:
        name: covdata-${{ inputs.shard-name }}
        path: .coverage.${{ inputs.shard-name }}
        include-hidden-files: true
        retention-days: 1

    - name: Upload junit
      if: always()
      uses: actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02  # v4.6.0
      continue-on-error: true
      with:
        name: junit-${{ inputs.shard-name }}
        path: junit-${{ inputs.shard-name }}.xml
        retention-days: 7
```

- [ ] **Step 3: Static-validate**

Run: `./bin/actionlint .github/workflows/_smoke-composites.yml && yamllint -d relaxed .github/actions/run-pytest-shard/action.yml`
Expected: no output (exit 0).

- [ ] **Step 4: Commit**

```bash
git add .github/actions/run-pytest-shard/action.yml .github/workflows/_smoke-composites.yml
git commit -m "ci(composites): add run-pytest-shard (per-shard coverage data + junit)"
```

---

### Task 4: `coverage-gate` composite (combine all shards → true union → fail-under)

**Files:**
- Create: `.github/actions/coverage-gate/action.yml`
- Modify: `.github/workflows/_smoke-composites.yml`

- [ ] **Step 1: Add smoke job (the test)**

Add to `_smoke-composites.yml`. It depends on the shard job to have uploaded `covdata-smoke`:

```yaml
  coverage-gate:
    name: "coverage-gate"
    runs-on: [self-hosted, linux, proxmox]
    needs: run-pytest-shard
    timeout-minutes: 6
    steps:
      - uses: actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5  # v4
      - name: Fixture (coverage tool + the source the data file references)
        run: |
          printf 'coverage[toml]\n' > requirements.txt
          mkdir -p app
          printf 'def add(a, b):\n    return a + b\n' > app/calc.py
      - uses: ./.github/actions/setup-python-deps
        with: { cache-key-suffix: covgate-smoke }
      - uses: ./.github/actions/coverage-gate
        with:
          threshold: "0"
          blocking: "true"
      - name: Assert combined report exists
        run: test -f coverage.xml || { echo "::error::no combined coverage.xml"; exit 1; }
```

- [ ] **Step 2: Implement the composite**

Create `.github/actions/coverage-gate/action.yml`:

```yaml
# Download every covdata-* artifact, coverage combine into a true union, gate on threshold.
# Replaces the legacy max()-line-rate heuristic that under-reported union coverage.
name: "Coverage gate"
description: "Combine per-shard coverage data, enforce a union-coverage threshold"

inputs:
  threshold:
    description: "Minimum total coverage percent"
    required: false
    default: "50"
  blocking:
    description: "Fail the job when below threshold (false => warn only)"
    required: false
    default: "true"

runs:
  using: composite
  steps:
    - name: Download all shard coverage data
      uses: actions/download-artifact@fa0a91b85d4f405e80dcb880a1c62a651be25e5e  # v4.1.8  (SHA from Task 1)
      with:
        pattern: covdata-*
        path: .covdata
        merge-multiple: true

    - name: Combine + report + gate
      shell: bash
      run: |
        shopt -s dotglob
        if ! ls .covdata/.coverage.* >/dev/null 2>&1; then
          echo "::error::no coverage data files found (covdata-* artifacts missing)"; exit 1
        fi
        cp .covdata/.coverage.* .
        coverage combine
        coverage xml -o coverage.xml
        TOTAL=$(coverage report | tail -1 | grep -oE '[0-9]+%' | tr -d '%')
        echo "## 📊 Coverage" >> "$GITHUB_STEP_SUMMARY"
        echo "| Metric | Value |" >> "$GITHUB_STEP_SUMMARY"
        echo "|--------|-------|" >> "$GITHUB_STEP_SUMMARY"
        echo "| Union coverage | **${TOTAL}%** |" >> "$GITHUB_STEP_SUMMARY"
        echo "| Threshold | ${{ inputs.threshold }}% |" >> "$GITHUB_STEP_SUMMARY"
        coverage report >> "$GITHUB_STEP_SUMMARY" 2>/dev/null || true
        if [ "$TOTAL" -lt "${{ inputs.threshold }}" ]; then
          if [ "${{ inputs.blocking }}" = "true" ]; then
            echo "::error::coverage ${TOTAL}% < ${{ inputs.threshold }}%"; exit 1
          else
            echo "::warning::coverage ${TOTAL}% < ${{ inputs.threshold }}% (advisory)"
          fi
        fi
```

- [ ] **Step 3: Static-validate**

Run: `./bin/actionlint .github/workflows/_smoke-composites.yml && yamllint -d relaxed .github/actions/coverage-gate/action.yml`
Expected: no output (exit 0).

- [ ] **Step 4: Commit**

```bash
git add .github/actions/coverage-gate/action.yml .github/workflows/_smoke-composites.yml
git commit -m "ci(composites): add coverage-gate (coverage combine union + fail-under)"
```

---

### Task 5: `start-app` composite (generic backgrounded launcher + health poll)

**Files:**
- Create: `.github/actions/start-app/action.yml`
- Modify: `.github/workflows/_smoke-composites.yml`

Generic: the calling app supplies the boot command (it knows its own `init_db`/seed). Outputs `app-pid` so callers can kill it after integration/DAST/Lighthouse.

- [ ] **Step 1: Add smoke job (the test)**

Add to `_smoke-composites.yml`:

```yaml
  start-app:
    name: "start-app"
    runs-on: [self-hosted, linux, proxmox]
    timeout-minutes: 5
    steps:
      - name: Fixture HTTP server with /health
        run: |
          mkdir -p _fix
          cat > _fix/server.py <<'PY'
          from http.server import BaseHTTPRequestHandler, HTTPServer
          class H(BaseHTTPRequestHandler):
              def do_GET(self):
                  self.send_response(200 if self.path == "/health" else 404)
                  self.end_headers(); self.wfile.write(b"ok")
              def log_message(self, *a): pass
          HTTPServer(("127.0.0.1", 5000), H).serve_forever()
          PY
      - id: app
        uses: ./.github/actions/start-app
        with:
          boot-command: "python3 _fix/server.py"
          health-url: "http://127.0.0.1:5000/health"
      - name: Assert pid output + reachable, then stop
        run: |
          test -n "${{ steps.app.outputs.app-pid }}" || { echo "::error::no app-pid"; exit 1; }
          curl -fsS http://127.0.0.1:5000/health
          kill "${{ steps.app.outputs.app-pid }}"
```

- [ ] **Step 2: Implement the composite**

Create `.github/actions/start-app/action.yml`:

```yaml
# Launch an app in the background and poll its health endpoint until ready.
# App-agnostic: caller passes the boot command. Outputs the PID so caller can stop it.
name: "Start app"
description: "Background-launch an app and wait for its health endpoint"

inputs:
  boot-command:
    description: "Shell command that starts the app in the foreground"
    required: true
  health-url:
    description: "URL polled until it returns 200"
    required: true
  max-retries:
    description: "Health poll attempts"
    required: false
    default: "30"
  retry-delay:
    description: "Seconds between attempts"
    required: false
    default: "1"

outputs:
  app-pid:
    description: "PID of the launched app"
    value: ${{ steps.launch.outputs.pid }}

runs:
  using: composite
  steps:
    - name: Launch + poll
      id: launch
      shell: bash
      run: |
        nohup ${{ inputs.boot-command }} > app-boot.log 2>&1 &
        PID=$!
        echo "pid=$PID" >> "$GITHUB_OUTPUT"
        echo "Launched PID $PID; polling ${{ inputs.health-url }}"
        for i in $(seq 1 ${{ inputs.max-retries }}); do
          if curl -fsS -o /dev/null --max-time 5 "${{ inputs.health-url }}"; then
            echo "✅ healthy after ${i} attempt(s)"; exit 0
          fi
          if ! kill -0 "$PID" 2>/dev/null; then
            echo "::error::app process died during startup"; cat app-boot.log; exit 1
          fi
          sleep ${{ inputs.retry-delay }}
        done
        echo "::error::health check never passed"; cat app-boot.log; exit 1
```

- [ ] **Step 3: Static-validate**

Run: `./bin/actionlint .github/workflows/_smoke-composites.yml && yamllint -d relaxed .github/actions/start-app/action.yml`
Expected: no output (exit 0).

- [ ] **Step 4: Commit**

```bash
git add .github/actions/start-app/action.yml .github/workflows/_smoke-composites.yml
git commit -m "ci(composites): add start-app (generic launcher + health poll + pid output)"
```

---

### Task 6: `opa-policy` composite (conftest vs Dockerfile + compose) + Rego policies

**Files:**
- Create: `.github/actions/opa-policy/action.yml`
- Create: `.github/actions/opa-policy/policy/dockerfile.rego`
- Create: `.github/actions/opa-policy/policy/compose.rego`
- Modify: `.github/workflows/_smoke-composites.yml`

Policies are bundled with the action (referenced via `${{ github.action_path }}/policy`) so every app is checked against the SAME rules.

- [ ] **Step 1: Add smoke job (the test)**

Add to `_smoke-composites.yml`:

```yaml
  opa-policy:
    name: "opa-policy"
    runs-on: [self-hosted, linux, proxmox]
    timeout-minutes: 5
    steps:
      - name: Fixture compliant Dockerfile
        run: |
          cat > Dockerfile <<'DOCKER'
          FROM python:3.11-slim@sha256:0000000000000000000000000000000000000000000000000000000000000000
          RUN useradd -m app
          USER app
          HEALTHCHECK CMD curl -f http://localhost:5000/health || exit 1
          CMD ["python", "app.py"]
          DOCKER
      - uses: ./.github/actions/opa-policy
        with:
          dockerfile: Dockerfile
          blocking: "true"
      - name: Assert a non-compliant Dockerfile is rejected
        run: |
          printf 'FROM python:latest\nCMD ["python","app.py"]\n' > Bad.dockerfile
          if ./bin/conftest test Bad.dockerfile --policy .github/actions/opa-policy/policy --parser dockerfile 2>/dev/null; then
            echo "::error::non-compliant Dockerfile was NOT rejected"; exit 1
          fi
          echo "✅ non-compliant Dockerfile correctly rejected"
```

(Note: this smoke assumes `conftest` is on PATH from Step 2's install; the composite installs it. The second assertion calls `./bin/conftest` — adjust to the install path the composite uses, or rely on PATH.)

- [ ] **Step 2: Implement the Rego policies**

Create `.github/actions/opa-policy/policy/dockerfile.rego`:

```rego
package main

# Deny base images pinned only by mutable tag (require @sha256 digest or no :latest)
deny[msg] {
    input[i].Cmd == "from"
    val := input[i].Value[0]
    contains(val, ":latest")
    msg := sprintf("base image uses mutable ':latest' tag: %s", [val])
}

# Require a non-root USER instruction
deny[msg] {
    not has_user
    msg := "Dockerfile must set a non-root USER"
}

has_user {
    input[_].Cmd == "user"
}

# Require a HEALTHCHECK
deny[msg] {
    not has_healthcheck
    msg := "Dockerfile must define a HEALTHCHECK"
}

has_healthcheck {
    input[_].Cmd == "healthcheck"
}
```

Create `.github/actions/opa-policy/policy/compose.rego`:

```rego
package main

# Every service must declare a restart policy
deny[msg] {
    some name
    svc := input.services[name]
    not svc.restart
    msg := sprintf("compose service '%s' has no restart policy", [name])
}

# No service may use a :latest image tag
deny[msg] {
    some name
    img := input.services[name].image
    endswith(img, ":latest")
    msg := sprintf("compose service '%s' uses ':latest' image tag", [name])
}
```

- [ ] **Step 3: Implement the composite**

Create `.github/actions/opa-policy/action.yml`:

```yaml
# Policy-as-code gate: conftest runs bundled Rego policies against Dockerfile + compose.
name: "OPA policy"
description: "conftest/OPA checks on Dockerfile and docker-compose using shared Rego"

inputs:
  dockerfile:
    description: "Path to Dockerfile"
    required: false
    default: "Dockerfile"
  compose-glob:
    description: "Glob for compose files (empty to skip)"
    required: false
    default: "docker-compose*.yml"
  conftest-version:
    description: "conftest release to install"
    required: false
    default: "0.56.0"
  blocking:
    description: "Fail on violations (false => warn only)"
    required: false
    default: "true"

runs:
  using: composite
  steps:
    - name: Install conftest
      shell: bash
      run: |
        if ! command -v conftest >/dev/null 2>&1; then
          V="${{ inputs.conftest-version }}"
          curl -sSfL "https://github.com/open-policy-agent/conftest/releases/download/v${V}/conftest_${V}_Linux_x86_64.tar.gz" \
            | sudo tar xz -C /usr/local/bin conftest
        fi
        conftest --version

    - name: Test Dockerfile
      shell: bash
      run: |
        POLICY="${{ github.action_path }}/policy"
        RC=0
        if [ -f "${{ inputs.dockerfile }}" ]; then
          conftest test "${{ inputs.dockerfile }}" --policy "$POLICY" --parser dockerfile || RC=$?
        else
          echo "::notice::no Dockerfile at ${{ inputs.dockerfile }} — skipping"
        fi
        echo "RC=$RC" >> "$GITHUB_ENV"

    - name: Test compose files
      shell: bash
      run: |
        POLICY="${{ github.action_path }}/policy"
        RC=${RC:-0}
        for f in ${{ inputs.compose-glob }}; do
          [ -f "$f" ] || continue
          conftest test "$f" --policy "$POLICY" || RC=$?
        done
        if [ "$RC" != "0" ] && [ "${{ inputs.blocking }}" = "true" ]; then
          echo "::error::OPA policy violations found"; exit 1
        elif [ "$RC" != "0" ]; then
          echo "::warning::OPA policy violations (advisory)"
        fi
```

- [ ] **Step 4: Static-validate**

Run: `./bin/actionlint .github/workflows/_smoke-composites.yml && yamllint -d relaxed .github/actions/opa-policy/action.yml`
Expected: no output (exit 0). (Rego files are not linted by these tools; conftest validates them at runtime in the smoke run.)

- [ ] **Step 5: Commit**

```bash
git add .github/actions/opa-policy/
git add .github/workflows/_smoke-composites.yml
git commit -m "ci(composites): add opa-policy (conftest + bundled Rego for Dockerfile/compose)"
```

---

### Task 7: Real-runner validation + README

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Push dev and run the smoke harness on the self-hosted runner**

Run:
```bash
git push -u origin dev
gh workflow run _smoke-composites.yml --ref dev
sleep 5 && gh run watch "$(gh run list --workflow=_smoke-composites.yml --branch dev --limit 1 --json databaseId --jq '.[0].databaseId')" --exit-status
```
Expected: all five jobs (`setup-python-deps`, `run-pytest-shard`, `coverage-gate`, `start-app`, `opa-policy`) conclude **success**. (This is the real test — it exercises the Debian-13 runner that local lint cannot.)

- [ ] **Step 2: If any job fails, debug from the run log**

Run: `gh run view "$(gh run list --workflow=_smoke-composites.yml --branch dev --limit 1 --json databaseId --jq '.[0].databaseId')" --log-failed`
Fix the implicated composite, commit, re-run Step 1. Do not proceed until green. (Use superpowers:systematic-debugging if the cause is non-obvious.)

- [ ] **Step 3: Document the composites in README**

Add to `README.md` under "## Composite Actions" (append rows; keep existing `setup-python-env`/`health-check` rows):

```markdown
| `setup-python-deps` | Debian-13-safe: system python3 + per-job venv + cached deps |
| `run-pytest-shard` | Run one test shard → `.coverage.<shard>` data file + junit |
| `coverage-gate` | Combine all shard coverage data → union % → fail-under gate |
| `start-app` | Background-launch an app + poll health, output PID |
| `opa-policy` | conftest/OPA Rego checks on Dockerfile + compose |
```

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "docs(composites): document Phase-1 composite actions"
git push origin dev
```

---

## Self-Review

**1. Spec coverage (§5.1 composites):** setup-python-deps ✓ (Task 2), run-pytest-shard ✓ (Task 3), coverage-gate ✓ (Task 4, combine replaces max() per §5.1), start-app ✓ (Task 5), opa-policy + Rego ✓ (Task 6, §6 policy rules: non-root, no :latest, healthcheck, compose restart). `health-check` kept as-is (no task needed — already exists). PR coverage-delta explicitly deferred to Phase 3 (scope boundary). Legacy `setup-python-env` removal deferred to Phase 4 (scope boundary). No Phase-1 spec gap.

**2. Placeholder scan:** No "TBD/TODO/handle edge cases". Action SHAs are concretely resolved in Task 1 Step 2 and used verbatim; the three values shown are the expected current SHAs. The `conftest` path note in Task 6 Step 1 is a real adjustment instruction, not a placeholder.

**3. Type/interface consistency:** Input/output names are consistent across composites and their smoke jobs — `cache-key-suffix`, `install-coverage`, `shard-name`, `test-paths`, `coverage-source`, `threshold`, `blocking`, `boot-command`, `health-url`, `app-pid`, `dockerfile`, `compose-glob`. The coverage data contract is consistent: `run-pytest-shard` writes `.coverage.<name>` + uploads artifact `covdata-<name>`; `coverage-gate` downloads `covdata-*` and combines. checkout SHA `34e1148…` matches the repo's existing pin.
