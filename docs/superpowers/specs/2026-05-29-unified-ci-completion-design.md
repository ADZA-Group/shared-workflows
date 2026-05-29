# Unified CI Completion — Design Spec

- **Date:** 2026-05-29
- **Status:** Approved
- **Owner:** Azad Ahmed (ADZA-Group)
- **Home repo:** `adza-group/shared-workflows`
- **Extends:** `2026-05-28-unified-ci-design.md` (original spec — locked decisions stand)
- **Scope:** Complete the CI to feature-parity with the original spec's full DAG, ship as `v1` + `v1.1` + `v1.2` via three inkrementelle dev→main cycles. No app rollout (P4 = separate milestone).

---

## 1. Delivery Strategy

Three sequential cycles on `dev`, each ubuntu-validated before merging to `main` and re-tagging:

| Cycle | Tag | Contents | Deliverable |
|---|---|---|---|
| **C** | `v1` | 2 fixes + `dependabot.yml` + merge | First **consumable** release — apps can pin `@v1` |
| **A** | `v1.1` | Orchestrator-Tail: full lint wave, property/mutation hooks, deploy-tail, wire-ins, pr-summary, notify | Complete pipeline DAG |
| **B** | `v1.2` | 5 new reusables + wire-ins + Lighthouse in frontend | Feature-complete spec §5.2 |

Each cycle follows the ADZA branch-discipline: `dev` → ubuntu-smoke-green → `git push origin dev` → `dev`→`main` merge → annotated tag.

Versioning note: `@v1` is a **moving major tag** (force-updated on each `v1.x` release so existing callers auto-pick up improvements without re-pinning). Callers wanting a frozen pin use `@v1.0`, `@v1.1`, etc.

---

## 2. Cycle C — Fixes + v1

### 2.1 Fix: Docker-only gate in `reusable-ci.yml`

**Problem:** `docker-build` job condition requires `test-matrix.result == 'success'`. A pure Dockerfile change (no `.py`, no `.github`) causes `test-matrix` to be *skipped*, so `docker-build` is also skipped → image never rebuilt for Dockerfile-only commits.

**Fix:** Accept both `'success'` and `'skipped'` on `test-matrix`, while also adding `changes.docker` to the overall any-code check.

```yaml
# .github/workflows/reusable-ci.yml — docker-build.if
if: >-
  always() &&
  needs.lint-python.result != 'failure' &&
  (needs.test-matrix.result == 'success' || needs.test-matrix.result == 'skipped') &&
  (needs.changes.outputs.any_code == 'true' || needs.changes.outputs.docker == 'true' || needs.changes.outputs.ci == 'true')
```

Also extend `changes` job outputs to surface `docker` explicitly (already output but not used in any-code):
```yaml
any_code: ${{ steps.filter.outputs.python == 'true' || steps.filter.outputs.docker == 'true' || steps.filter.outputs.frontend == 'true' }}
```
(This is already the case in the current impl — the fix is purely the `if:` condition.)

### 2.2 Add `.github/dependabot.yml`

Central pin-bump automation for all SHA-pinned actions in the repo. One update point for all ADZA apps once they migrate to `@v1` callers.

```yaml
version: 2
updates:
  - package-ecosystem: github-actions
    directory: /
    schedule: { interval: weekly, day: monday }
    target-branch: dev
    labels: [dependencies, github-actions]
    open-pull-requests-limit: 10
    groups:
      actions:
        patterns: ["*"]
```

### 2.3 v1 release

After Cycle C on ubuntu:
```bash
git checkout main && git merge --no-ff dev
git tag -a v1 -m "chore: v1 — first consumable release"
git tag -a v1.0 -m "chore: v1.0 — fixes + dependabot"
git push origin main --tags
```

---

## 3. Cycle A — Orchestrator-Tail (v1.1)

All changes in `reusable-ci.yml` unless noted. New inputs added to `workflow_call.inputs`.

### 3.1 New inputs

```yaml
has-frontend:
  type: boolean, default: false
frontend-dir:
  type: string, default: "frontend"
enable-property-tests:
  type: boolean, default: true
enable-mutation:
  type: boolean, default: true
enable-load-test:
  type: boolean, default: false
staging-url:
  type: string, default: ""
prod-url:
  type: string, default: ""
deploy-prod:
  type: boolean, default: true
enable-dast:
  type: boolean, default: false   # wired in Cycle B; declared here for forward-compat
```

### 3.2 Wave 1 — Full Lint Suite

All new lint jobs run in parallel with existing `lint-python`. All gate via `if: changes.python == 'true' || changes.docker == 'true' || changes.ci == 'true'` as appropriate.

| Job | Tool | Install | Gate |
|---|---|---|---|
| `lint-dockerfile` | `hadolint/hadolint-action@v3` (SHA-pinned) | no setup | advisory on PR/dev, blocking on main — `continue-on-error: ${{ !(github.ref == 'refs/heads/main' || ...) }}` |
| `code-quality` | `radon cc . -a -nb` | setup-python-deps, extra: `radon==6.*` | advisory always (`continue-on-error: true`) |
| `dead-code` | `vulture . --min-confidence 80 --exclude tests,.venv` | extra: `vulture==2.*` | advisory always |
| `todo-tracker` | `grep -rn "TODO\|FIXME\|HACK\|XXX" --include="*.py" .` → summary only | none | info (never fails) |
| `license-check` | `pip-licenses --fail-on=GPL-2.0-only,GPL-3.0-only,LGPL-2.1-only,LGPL-3.0-only` | extra: `pip-licenses==4.*` | advisory on PR/dev, blocking on main |
| `commit-lint` | check PR title matches `^(feat\|fix\|docs\|chore\|ci\|test\|refactor\|style\|perf)(\(.+\))?: .+` via bash regex | none | advisory, PR-only (`if: github.event_name == 'pull_request'`) |

### 3.3 Wave 2 — Property Tests (optional)

```yaml
property-tests:
  name: "🔬 Property Tests"
  needs: changes
  if: inputs.enable-property-tests && (changes.python || changes.ci)
  runs-on: fromJSON(inputs.runner-label)
  timeout-minutes: 15
  continue-on-error: true   # always advisory
  steps:
    - checkout
    - setup-python-deps (install-requirements: true, extra: "hypothesis==6.*")
    - run: pytest tests/ -m "hypothesis" --hypothesis-seed=0 --timeout=60 -p no:cacheprovider
```

If no `@hypothesis.given` tests exist in the app, pytest collects 0 tests → passes cleanly.

### 3.4 Wave 2b — Mutation Tests (optional, incremental)

```yaml
mutation:
  name: "🧬 Mutation (incremental)"
  needs: [changes, test-matrix]
  if: inputs.enable-mutation && needs.test-matrix.result == 'success' && changes.python
  runs-on: fromJSON(inputs.runner-label)
  timeout-minutes: 20
  continue-on-error: true   # always advisory
  steps:
    - checkout (fetch-depth: 0)
    - setup-python-deps (install-requirements: true, extra: "mutmut==2.*")
    - name: Get changed Python files
      run: |
        CHANGED=$(git diff --name-only origin/main...HEAD -- '*.py' | grep -v test | head -20 || true)
        echo "files=${CHANGED//$'\n'/ }" >> $GITHUB_OUTPUT
    - name: Run mutmut incremental
      run: |
        if [ -z "${{ steps.changed.outputs.files }}" ]; then
          echo "No non-test Python changes — skipping mutation"; exit 0
        fi
        mutmut run --paths-to-mutate "${{ steps.changed.outputs.files }}" || true
        SURVIVED=$(mutmut results 2>/dev/null | grep -c "survived" || echo 0)
        echo "## 🧬 Mutation Testing" >> $GITHUB_STEP_SUMMARY
        echo "| Metric | Value |" >> $GITHUB_STEP_SUMMARY
        echo "|--------|-------|" >> $GITHUB_STEP_SUMMARY
        echo "| Surviving mutants | ${SURVIVED} |" >> $GITHUB_STEP_SUMMARY
        echo "| Mode | incremental (changed modules only) |" >> $GITHUB_STEP_SUMMARY
```

### 3.5 Wire-in: reusable-frontend (Wave 2)

```yaml
frontend:
  name: "🎨 Frontend"
  needs: changes
  if: inputs.has-frontend && (changes.frontend == 'true' || changes.ci == 'true')
  permissions: { contents: read }
  uses: adza-group/shared-workflows/.github/workflows/reusable-frontend.yml@dev
  with:
    frontend-dir: ${{ inputs.frontend-dir }}
    runner-label: '["ubuntu-latest"]'   # FE always ubuntu (Node toolchain)
  secrets: inherit
```

### 3.6 Wire-in: reusable-load-test (Wave 5, concurrent with verify-staging)

```yaml
load-test:
  name: "📈 Load Test"
  needs: [verify-staging]
  if: >-
    always() && inputs.enable-load-test && inputs.staging-url != '' &&
    needs.verify-staging.result == 'success'
  permissions: { contents: read }
  uses: adza-group/shared-workflows/.github/workflows/reusable-load-test.yml@dev
  with:
    target-url: ${{ inputs.staging-url }}
    blocking: false
    runner-label: ${{ inputs.runner-label }}
  secrets: inherit
```

### 3.7 Deploy-Tail (Wave 5)

ADZA's deploy is Watchtower pull-based — no explicit deploy step needed. Wave 5 = **verification only** after docker-build has pushed to GHCR and Watchtower has polled. Jobs are gated behind `inputs.staging-url != ''`.

Wait time before verify: 90s (Watchtower default poll interval is 5 min, but Rechnungsapp/FootballApp use `--interval 300`). To keep the job fast without a 5-min sleep, `health-check` polls with a long timeout (max-retries: 40, retry-delay: 30s = up to 20 min). This is acceptable for dev pushes; callers can tune via input.

```yaml
verify-staging:
  name: "🔍 Verify Staging"
  needs: docker-build
  if: >-
    always() && inputs.staging-url != '' && inputs.deploy-prod &&
    needs.docker-build.result == 'success' &&
    github.event_name == 'push'
  runs-on: ${{ fromJSON(inputs.runner-label) }}
  timeout-minutes: 25
  steps:
    - uses: actions/checkout@... # v4
    - uses: adza-group/shared-workflows/.github/actions/health-check@dev
      with:
        url: ${{ inputs.staging-url }}
        max-retries: 40
        retry-delay: 30
        check-security-headers: true

require-staging-green:
  name: "🚦 Require Staging Green"
  needs: verify-staging
  if: >-
    always() && inputs.staging-url != '' &&
    github.ref == 'refs/heads/main'
  runs-on: ${{ fromJSON(inputs.runner-label) }}
  timeout-minutes: 5
  steps:
    - name: Gate
      run: |
        if [ "${{ needs.verify-staging.result }}" != "success" ]; then
          echo "::error::staging not green — blocking main push"; exit 1
        fi

verify-prod:
  name: "✅ Verify Prod"
  needs: [docker-build, require-staging-green]
  if: >-
    always() && inputs.prod-url != '' && inputs.deploy-prod &&
    needs.docker-build.result == 'success' &&
    github.ref == 'refs/heads/main'
  runs-on: ${{ fromJSON(inputs.runner-label) }}
  timeout-minutes: 25
  steps:
    - uses: actions/checkout@...
    - uses: adza-group/shared-workflows/.github/actions/health-check@dev
      id: prod-check
      continue-on-error: true
      with:
        url: ${{ inputs.prod-url }}
        max-retries: 40
        retry-delay: 30

    - name: Auto-rollback on failure
      if: steps.prod-check.outcome == 'failure'
      run: |
        IMAGE=${{ inputs.image-name || format('ghcr.io/adza-group/{0}', inputs.app-name) }}
        echo "::warning::prod unhealthy — rolling back :latest to :previous"
        docker buildx imagetools create --tag "${IMAGE}:latest" "${IMAGE}:previous" || \
          echo "::warning::rollback failed (no :previous tag?)"

    - name: Open issue on prod failure
      if: steps.prod-check.outcome == 'failure'
      env:
        GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
      run: |
        gh issue create \
          --title "🚨 Prod health check failed — ${{ inputs.app-name }} @ ${{ github.sha }}" \
          --body "Run: ${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }}" \
          --label "incident,production" || true

    - name: Fail if prod unhealthy
      if: steps.prod-check.outcome == 'failure'
      run: exit 1
```

### 3.8 Wave 6 — PR Summary + Notify

**PR Summary (sticky comment):**
```yaml
pr-summary:
  name: "📝 PR Summary"
  needs: [lint-python, security, test-matrix, coverage, docker-build]
  if: always() && github.event_name == 'pull_request'
  runs-on: ${{ fromJSON(inputs.runner-label) }}
  timeout-minutes: 5
  permissions: { contents: read, pull-requests: write }
  steps:
    - uses: marocchino/sticky-pull-request-comment@...  # SHA-pinned
      with:
        header: ci-summary
        message: |
          ## CI Summary — `${{ inputs.app-name }}`
          | Job | Result |
          |-----|--------|
          | lint | ${{ needs.lint-python.result }} |
          | security | ${{ needs.security.result }} |
          | tests | ${{ needs.test-matrix.result }} |
          | coverage | ${{ needs.coverage.result }} |
          | docker | ${{ needs.docker-build.result }} |
          [View run](${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }})
```

**Notify wire-in (separate top-level job — reusable workflows cannot be called as steps):**
```yaml
# NEW top-level job in reusable-ci.yml (NOT a step inside telemetry):
notify:
  name: "🚨 Notify"
  needs: [lint-python, security, test-matrix, coverage, docker-build, telemetry]
  if: >-
    always() && (
      needs.lint-python.result == 'failure' ||
      needs.test-matrix.result == 'failure' ||
      needs.coverage.result == 'failure' ||
      needs.docker-build.result == 'failure'
    )
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

**Note:** `reusable-notify.yml` currently hardcodes `runs-on: [self-hosted, linux, proxmox]`. Add a `runner-label` input (default that value) so it can run ubuntu in smoke tests.

### 3.9 Telemetry — extend for new jobs

Add `lint-dockerfile`, `code-quality`, `dead-code`, `frontend`, `property-tests`, `mutation` to the `needs` array unconditionally (they are always defined, just skipped when gates don't match). For `verify-staging` and `verify-prod`, do NOT add them to `telemetry.needs` — they are conditionally defined jobs (only created when `staging-url != ''`), and adding an undefined job to `needs` causes a GitHub Actions parse error. Instead, surface their status via Step Summary conditionally using `needs.verify-staging.result` only in the `notify` job (which already lists them in its failure-check condition).

### 3.10 v1.1 release

After Cycle A ubuntu-smoke green:
```bash
git merge --no-ff dev
git tag -a v1.1 -m "ci: v1.1 — orchestrator tail, full lint suite, deploy-tail, wire-ins"
git tag -f v1 -m "chore: move v1 to v1.1"  # float major tag
git push origin main --tags --force-with-lease
```

---

## 4. Cycle B — New Reusables (v1.2)

### 4.1 `reusable-dast.yml`

OWASP ZAP baseline scan against a live URL. Always ubuntu-latest (requires Docker). Dual-gate.

```yaml
name: "🔓 DAST"
on:
  workflow_call:
    inputs:
      target-url: { required: true, type: string }
      scan-type: { required: false, type: string, default: "baseline" }  # baseline | full
      blocking: { required: false, type: boolean, default: false }
      runner-label: { required: false, type: string, default: '["ubuntu-latest"]' }
```

Steps:
1. `zaproxy/action-baseline@v0.14.0` (SHA-pinned) — runs ZAP in docker against `target-url`
2. Parse report XML: count FAIL-level alerts → if >0 and `blocking`, fail
3. Upload report artifact (retention: 30d)
4. Step summary with alert counts by risk level

### 4.2 `reusable-mutation.yml`

Standalone reusable for nightly full sweeps (incremental version lives in orchestrator).

```yaml
name: "🧬 Mutation"
on:
  workflow_call:
    inputs:
      mode: { required: false, type: string, default: "incremental" }  # incremental | full
      base-ref: { required: false, type: string, default: "main" }
      runner-label: { required: false, type: string, default: '["self-hosted","linux","proxmox"]' }
```

Steps:
1. `setup-python-deps@dev` + `mutmut==2.*`
2. If `mode=incremental`: `git diff origin/base-ref...HEAD --name-only '*.py'` → `mutmut run --paths-to-mutate <files>`
3. If `mode=full`: `mutmut run`
4. `mutmut results` → parse surviving count → Step Summary
5. Always `continue-on-error: true` (advisory only)

### 4.3 `reusable-release.yml`

```yaml
name: "🚀 Release"
on:
  workflow_call:
    inputs:
      release-type: { required: false, type: string, default: "simple" }
      runner-label: { required: false, type: string, default: '["ubuntu-latest"]' }
    secrets:
      RELEASE_TOKEN: { required: false }  # PAT with contents:write if needed
```

Steps:
1. `googleapis/release-please-action@v4` (SHA-pinned)
   - `release-type: simple`
   - `token: ${{ secrets.RELEASE_TOKEN || secrets.GITHUB_TOKEN }}`
   - `include-v-in-tag: true`
2. On release-created: `softprops/action-gh-release@v2` (SHA-pinned) — publish CHANGELOG

Namespace fix: uses `GITHUB_REPOSITORY` (= `adza-group/...`) which auto-resolves correctly. No more hardcoded `azad-ahmed`.

### 4.4 `reusable-security-weekly.yml`

Comprehensive weekly sweep — more thorough than the inline `reusable-security-scan.yml` (which runs per-PR). Typically called on a schedule by each app.

```yaml
name: "🔐 Security Weekly"
on:
  workflow_call:
    inputs:
      image-name: { required: false, type: string, default: "" }
      prod-url: { required: false, type: string, default: "" }
      runner-label: ...
```

Jobs (all advisory, all `continue-on-error: true`):
| Job | Tool | Notes |
|---|---|---|
| `pip-audit-weekly` | `pip-audit -r requirements.txt --desc` | Full CVE report |
| `trivy-weekly` | Trivy fs + image (if `image-name` set) | ALL severities |
| `osv-scanner` | `google/osv-scanner-action@v2` | OSV database |
| `grype` | `anchore/scan-action@v3` | Syft SBOM → Grype |
| `trufflehog` | `trufflesecurity/trufflehog@v3` | Entropy + rule scan, full history |
| `nuclei` | `projectdiscovery/nuclei` docker vs `prod-url`; job has `if: inputs.prod-url != ''` | CVES/Tech templates only |

All results uploaded as artifacts + step summary.

### 4.5 Lighthouse in `reusable-frontend.yml`

Add optional Lighthouse CI step (Cycle B, not Cycle A, because it needs a live staging URL):

```yaml
# new inputs:
lighthouse-url:
  required: false
  type: string
  default: ""
lighthouse-budget-performance:
  required: false
  type: number
  default: 80

# new job step (after build, if lighthouse-url set):
- name: Lighthouse CI
  if: inputs.lighthouse-url != ''
  uses: treosh/lighthouse-ci-action@...  # SHA-pinned
  with:
    urls: ${{ inputs.lighthouse-url }}
    uploadArtifacts: true
    temporaryPublicStorage: false
    budgetPath: .lighthouserc.json
  continue-on-error: ${{ !(github.ref == 'refs/heads/main' || startsWith(github.ref, 'refs/tags/')) }}
```

### 4.6 Wire DAST + Mutation into `reusable-ci.yml`

```yaml
# Wave 5b — DAST (behind enable-dast + staging-url):
dast:
  needs: [verify-staging]
  if: inputs.enable-dast && inputs.staging-url != '' && needs.verify-staging.result == 'success'
  uses: adza-group/shared-workflows/.github/workflows/reusable-dast.yml@dev
  with:
    target-url: ${{ inputs.staging-url }}
    blocking: false
    runner-label: '["ubuntu-latest"]'
  secrets: inherit

# Wave 2b — mutation now via reusable (replaces inline, keeps incremental):
mutation:
  needs: [changes, test-matrix]
  if: inputs.enable-mutation && needs.test-matrix.result == 'success' && changes.python
  uses: adza-group/shared-workflows/.github/workflows/reusable-mutation.yml@dev
  with:
    mode: incremental
    runner-label: ${{ inputs.runner-label }}
  secrets: inherit
```

### 4.7 v1.2 release

```bash
git merge --no-ff dev
git tag -a v1.2 -m "ci: v1.2 — dast, mutation, release, security-weekly, lighthouse"
git tag -f v1 -m "chore: move v1 to v1.2"
git push origin main --tags --force-with-lease
```

---

## 5. Validation Strategy (per Cycle)

Each cycle uses the existing ubuntu-smoke pattern from `CLAUDE.md §Wie man validiert`:

**Cycle C:** Modify `_smoke-ci.yml` to add a pure-docker-change test fixture (no `.py` changes → test-matrix should skip, docker-build should still run). Validate `docker-build.result == 'success'`.

**Cycle A:** Extend `_smoke-ci.yml` smoke caller with new inputs (`has-frontend: false, staging-url: "", enable-property-tests: true, enable-mutation: true`). Add temp `push:[dev]` trigger, push, watch. Remove trigger after green.
- `lint-dockerfile`: smoke Dockerfile fixture (currently passes hadolint).
- `property-tests`: smoke fixture has no hypothesis tests → collects 0 → passes.
- `mutation`: smoke fixture has minimal Python → may find no changed files → skips cleanly.
- Deploy-tail: `staging-url: ""` → all Wave 5 jobs skipped.
- PR-summary: only fires on PR event → not testable in push smoke (acceptable).

**Cycle B:** Each new reusable gets its own `_smoke-*.yml`. All ubuntu-hosted.
- `_smoke-dast.yml`: test against `https://example.com` (always 200, no FAIL alerts).
- `_smoke-mutation.yml`: standalone smoke of `reusable-mutation.yml` on the in-repo smoke fixture (`tests/fixtures/app`) — mode=full on 3 trivial functions → fast. This is in *addition* to the inline mutation job inside `_smoke-ci.yml` (the orchestrator smoke tests the wired-in incremental mode; the standalone smoke tests the reusable itself independently).
- `_smoke-release.yml`: dry-run mode / no-op commit (just test action loads).
- `_smoke-security-weekly.yml`: no image-name, no prod-url → nuclei/grype/trivy-image skip; pip-audit + osv + trufflehog run against the smoke fixture.
- `_smoke-frontend.yml`: already exists and is green — add `lighthouse-url: ""` input → lighthouse step skips.

---

## 6. Key Cross-Cutting Constraints

- **Nesting limit:** app(1)→reusable-ci(2)→sub-reusable(3). `dast`/`mutation` as full sub-reusables = level 3 (fine). Composites called inside sub-reusables = level 3 composite (also fine). No level 4 sub-reusable inside a sub-reusable.
- **Permissions:** `pr-summary` needs `pull-requests: write` (per-job). `verify-prod` `gh issue create` needs `issues: write` (per-job). Add to caller contract docs.
- **reusable-notify runner:** add `runner-label` input (default `["self-hosted","linux","proxmox"]`) so smoke callers can override to `ubuntu-latest`. Required before wire-in.
- **`@dev` refs:** all internal cross-references stay `@dev` through all three cycles; bump to `@v1`/`@v1.1`/`@v1.2` post-tag. `@dev` is an intentionally mutable ref — a bug-fix commit on `dev` is auto-picked up by any caller already on `@dev`. This is desired behaviour during build-out (no need to re-tag for every hot-fix). It is NOT a breaking-change concern; breaking changes only apply to tagged releases (`@v1`, `@v1.1`) where callers have pinned a stable ref.
- **Git commit user:** use `git log -1` pattern (GOTCHA #8 in CLAUDE.md) — no `git config` global.
- **SHA-pinning:** every new third-party action must be SHA-pinned with `# vX.Y.Z` comment on first addition.

---

## 7. Out of Scope

- P4 App-Rollout (FootballApp→RecyclageApp→MitarbeiterApp→Rechnungsapp) — separate milestone
- LXC-104 self-hosted runner re-registration — separate infra task (unblocks P4)
- MitarbeiterApp `frontend/package-lock.json` generation — prereq for P4 MitarbeiterApp
- Rechnungsapp `deploy-prod: false` unchanged (LXC-103 freeze until Sprint 1S complete)
- `reusable-dast` nightly-vs-prod mode (needs stable prod URL + weekly scheduler in each app)
- Multi-runner SPOF (YAGNI §12)
- Watchtower replacement with push-based deploy (YAGNI §12)
