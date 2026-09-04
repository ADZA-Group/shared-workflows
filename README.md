# ADZA-Group Shared Workflows

Reusable CI/CD workflows and composite actions for all ADZA-Group repositories.
The goal: every app's `.github/workflows/build.yml` is a ~25-line caller of
`reusable-ci.yml` — one canonical pipeline, zero drift.

> **Versioning:** app callers pin the floating release tag `@v1`. `dev` is the integration
> branch (Claude + Codex after the pair gate); `@v1` moves only through `release.yml`
> (candidate branch + smokes + atomic tag push), either manually via `scripts/release-v1.sh`
> or automatically every Monday via `weekly-release.yml` (see "Operating model").
> `uses: ./` does NOT work across repos — sibling composites/reusables are referenced by full
> path `adza-group/shared-workflows/...@<ref>`.

## Reusable Workflows

| Workflow | Purpose |
|----------|---------|
| `reusable-ci.yml` | **Orchestrator** — the one pipeline: changes → lint + security → test-matrix → coverage + test-results → docker build → verify-staging (dev) / verify-prod (main) |
| `reusable-security-scan.yml` | gitleaks · Bandit · Semgrep · pip-audit · CodeQL (py+js). Gates: gitleaks **always hard**; Bandit-HIGH **blocks on main/tags and on risky pushes**; Semgrep and pip-audit **advisory by default, opt-in dual-gate per app** via `security-blocking-scanners`; CodeQL always advisory (nightly + main/tags only). The Trivy *image* scan in `reusable-docker-build` is the hard vulnerability gate on main/tags |
| `reusable-docker-build.yml` | buildx (amd64) + size gate + Trivy image gate + SBOM + smoke; GHCR push of the *scanned* image + `:previous` backup; cosign keyless + SLSA provenance on main/tags |
| `reusable-frontend.yml` | node lane: eslint + tsc + vitest + vite build + bundle-size gate + Lighthouse CI + **pa11y-ci accessibility gate** (dual-gate) |
| `reusable-dast.yml` | OWASP ZAP baseline against staging (opt-in `enable-dast`, red on FAIL alerts only with `dast-blocking`) |
| `reusable-config-ci.yml` | infra/config-only repos (compose only): yamllint + `docker compose config` + gitleaks + OPA/conftest on the compose; dual-gate |
| `reusable-security-weekly.yml` | weekly sweep: pip-audit (all severities) · Trivy fs + deployed image · OSV · TruffleHog · Nuclei (prod URL) — advisory, results in the run summary |
| `reusable-weekly-cleanup.yml` | run/artifact retention (age-based only, keeps red runs) |
| `release.yml` / `weekly-release.yml` | `@v1` release pipeline (candidate branch → smokes → atomic tag push) and its Monday automation |

Removed 2026-09-04 (no caller, no consumer): multi-arch builds, gated promotion, api-contract,
e2e, load-test, mutation, pipeline-analytics, monitoring-dashboard, notify webhooks
(Discord/Slack/Telegram), telemetry, TIA/flake ledger, OPA + Trivy-fs + dependency-review in
the per-push security scan, Grype in the weekly sweep. Jarvis' CI cockpit and GitHub itself
are the observers now. `reusable-pipeline-analytics.yml` and `reusable-monitoring-dashboard.yml`
exist again as deprecated no-op stubs since v1.12.1 (callers on `main` still schedule them).

## Composite Actions

| Action | Purpose |
|--------|---------|
| `setup-python-deps` | **Debian-13 safe** — system `python3` + per-job venv + cached deps |
| `run-pytest-shard` | run one test shard → `.coverage.<shard>` data + junit; uploads both; expands globs/directories in `paths` |
| `coverage-gate` | `coverage combine` across shards (true union) → fail-under gate + diff-coverage |
| `start-app` | background-launch an app + poll health, output PID |
| `opa-policy` | conftest/OPA Rego checks on compose (used by `reusable-config-ci`) |
| `health-check` | endpoint polling + security-header check + version assert (`sha` / `commit` / `version` or `X-App-Version`) |

## Consuming `reusable-ci.yml`

An app's entire `build.yml`:

```yaml
name: CI/CD
on:
  push:         { branches: [main, dev], tags: ['v*'] }
  pull_request: { branches: [main, dev] }
  workflow_dispatch: {}
concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}
permissions:               # ⚠️ REQUIRED — see note below
  contents: read
  actions: read         # CodeQL on private repos (github/codeql-action#2117)
  packages: write
  id-token: write
  attestations: write
  security-events: write
  checks: write
  issues: write         # verify-prod opens incident issues on failure
  pull-requests: write  # pr-summary posts sticky CI comment on PRs
jobs:
  ci:
    uses: adza-group/shared-workflows/.github/workflows/reusable-ci.yml@v1
    with:
      app-name: rechnungsapp
      coverage-threshold: 85
      test-shards: >-
        [{"name":"backend","paths":"tests/test_*.py"},
         {"name":"integration","paths":"tests/integration/ tests/routes/"}]
      test-env: '{"RECHNUNG_TESTING":"1","RECHNUNG_DATABASE_URL":"postgresql://postgres:postgres@localhost:5432/test"}'
      install-system-deps: true     # tesseract/poppler for PDF/OCR apps
      staging-url: "https://i-app.example/health"
      staging-version-url: "https://i-app.example/health"
      staging-watchtower-url: "http://192.168.1.203:8080"
    secrets:
      WATCHTOWER_STAGING_TOKEN: ${{ secrets.WATCHTOWER_STAGING_TOKEN }}
```

### ⚠️ Required caller permissions

A **called** reusable workflow's `GITHUB_TOKEN` can only be **equal to or more restrictive
than the caller's** — if the callee requests more, GitHub fails the run at **`startup_failure`**
("workflow file issue"). `reusable-ci` delegates to nested jobs that need elevated scopes
(`docker-build` → `packages`/`id-token`/`attestations: write`; `security` → `security-events: write`;
`test-results` → `checks: write`; `verify-prod` → `issues: write`; `pr-summary` → `pull-requests: write`).
Therefore the **caller MUST grant the `permissions:` block above**. Omitting it is the #1 adoption pitfall.
Runner: every job runs on `runner-label` (default: the self-hosted proxmox runner on LXC 104).

### Key inputs (`reusable-ci.yml`)

Every input of the orchestrator is listed here; `scripts/check_docs.py` (actionlint gate) fails when
this table and `reusable-ci.yml` drift apart.

| Input | Default | Notes |
|-------|---------|-------|
| `app-name` | *(required)* | image name defaults to `ghcr.io/adza-group/<app-name>` |
| `test-shards` | *(required)* | JSON `[{name, paths, markers?, cov?}]` → dynamic test matrix. `paths` = space-separated pytest targets; since v1.11.1 `run-pytest-shard` expands shell globs (`tests/test_[a-i]*.py`) and directories itself and fails the shard on a token that matches nothing. `name` must be unique. |
| `test-env` | `{}` | JSON env for test jobs (put the DB URL here; postgres+redis services are provided, `localhost:5432/6379` are rewritten to the dynamic service ports) |
| `runner-label` | self-hosted proxmox | JSON array of runner labels for every job (`'["ubuntu-latest"]'` for repos without access to the org runners) |
| `python-version` | `3.11` | interpreter for the test job (`python<version>` on PATH preferred, loud warning otherwise) |
| `postgres-version` | `16-alpine` | postgres service image tag for the test jobs |
| `enable-redis` | `false` | reserved — a redis service is always provided; accepted for caller compatibility |
| `install-system-deps` | `false` | tesseract/poppler for PDF/OCR apps |
| `coverage-threshold` | `50` | union-coverage gate (blocking) |
| `diff-coverage-threshold` | `80` | coverage on changed lines (advisory on PR/dev, hard on main; main compares against `github.event.before`; tags off); `0` disables |
| `enable-property-tests` | `true` | hypothesis lane (advisory on dev, blocking on risky pushes and main) |
| `full-ci-on-dev-push` | `false` | `true` = security + property lanes also on dev/feature pushes (no CI diet) |
| `risky-paths` | `[]` | JSON globs merged with the built-in risky defaults (auth/security/permissions/migrations/models/payment/billing/price/delete/purge, Dockerfile, docker-compose*): a hit switches the diet off and makes property-tests/hadolint/bandit blocking |
| `full-ci-paths` | `[]` | JSON globs that force the full code lanes (tests, build, frontend) without hardening gates — e.g. `templates/**`, `static/**`, `translations/**` |
| `security-blocking-scanners` | `""` | opt-in dual-gate per app, comma-separated from `semgrep,pip-audit`: the named scanners block on main/tags and on risky pushes, stay advisory on PR/dev. Unknown names fail the `changes` job. |
| `has-frontend` | `false` | enable the frontend lane (`reusable-frontend.yml`) |
| `frontend-dir` | `frontend` | frontend directory |
| `a11y-url` | `""` | frontend lane: base URL for the pa11y scan (empty = serve the build output locally) |
| `a11y-paths` | `/` | frontend lane: space-separated paths to a11y-scan |
| `a11y-threshold` | `0` | frontend lane: max allowed pa11y errors per page |
| `image-name` | `""` | GHCR image name override (default `ghcr.io/adza-group/<app-name>`) |
| `image-size-limit-mb` | `800` | image size gate |
| `dockerfile` | `Dockerfile` | Dockerfile path |
| `docker-context` | `.` | docker build context |
| `sign-image` | `true` | cosign keyless + SLSA provenance — on main/tags only (staging images stay unsigned; nothing in the deploy path verifies signatures) |
| `enable-push` | `true` | GHCR push on `push` events (false for build-only) |
| `enforce-branch-policy` | `true` | main pushes must come via dev (ff or `--no-ff`/PR merge); violations block docker-build |
| `deploy-prod` | `true` | master switch for the verify tail (staging + prod) |
| `staging-url` | `""` | staging health URL; verify-staging runs on dev pushes only (main never deploys `:staging`) |
| `staging-version-url` | `""` | URL that reports the running version (`sha` / `commit` / `version` or `X-App-Version`); verify-staging polls until it equals `github.sha` |
| `staging-watchtower-url` | `""` | deterministic deploy: base URL of the Watchtower HTTP API on the staging host (`http://192.168.1.203:8080`); verify-staging POSTs `/v1/update` before polling. Requires the secret `WATCHTOWER_STAGING_TOKEN` and `staging-version-url` (the `changes` job fails fast otherwise). A failed trigger is a warning; the version assert stays the gate |
| `prod-url` | `""` | prod health URL; verify-prod runs on main pushes only, with auto-rollback `:previous` → `:latest` and an incident issue on failure |
| `prod-version-url` | `""` | like `staging-version-url` for prod |
| `prod-watchtower-url` | `""` | like `staging-watchtower-url` for prod (secret `WATCHTOWER_PROD_TOKEN`, `prod-version-url` required) |
| `enable-dast` | `false` | ZAP baseline against `staging-url` after verify-staging |
| `dast-blocking` | `false` | DAST job goes red on FAIL-level alerts instead of advisory. Not a deploy gate |
| `enable-ghcr-prune` / `enable-load-test` / `multi-arch` / `enable-mutation` / `cloud-runner-label` | — | **Deprecated no-ops** (removed in v1.12.0, re-declared in v1.12.1): a floating `@v1` must never break an existing caller — the removal put callers on `main` into `startup_failure` without a job or log. Values are ignored; a truthy value only yields a warning from the changes job. Removal = v2, once `scripts/check_callers.py` reports zero uses fleet-wide (dev **and** main) |

Secrets (all optional): `WATCHTOWER_STAGING_TOKEN`, `WATCHTOWER_PROD_TOKEN` — map them explicitly in
the caller's `secrets:` block (or use `secrets: inherit`). `DISCORD_WEBHOOK`, `SLACK_WEBHOOK`,
`TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID` are deprecated no-ops (notify webhooks removed in v1.12.0,
still declared so old callers do not fail at startup).

## Config-only repos (paperless, cloudflare)

Repos that contain only a `docker-compose.yml` (no app code/tests/Dockerfile) use the
lightweight `reusable-config-ci.yml` instead of the full `reusable-ci.yml`:

```yaml
name: CI
on:
  push:         { branches: [main, dev] }
  pull_request: { branches: [main] }
  workflow_dispatch:
permissions:
  contents: read
jobs:
  config:
    uses: adza-group/shared-workflows/.github/workflows/reusable-config-ci.yml@v1
    with:
      runner-label: ${{ vars.RUNNER_LABEL || '["ubuntu-latest"]' }}
    secrets: inherit
```

Gates: yamllint (relaxed) · `docker compose config` · gitleaks · OPA/conftest on the compose.

## Security policy (= the code)

gitleaks is always hard. Bandit-HIGH blocks on main/tags and on risky pushes (`force-blocking`).
Semgrep and pip-audit are **advisory by default** (Semgrep noise blocked main in v1.3.x); an app opts
in per scanner via `security-blocking-scanners` (dual-gated like Bandit) and via `dast-blocking`.
CodeQL runs nightly and on main/tags, always advisory (no GHAS in the fleet). The Trivy *image* scan
in `reusable-docker-build` is the hard vulnerability gate on main/tags. Measured 2026-09-04 before
offering the switch: rechnungsapp has `pip-audit` and `semgrep` enabled (0 active findings after the
defusedxml fix), recyclage has 2 and footballapp 16 active Semgrep findings, so the switch stays
per app. Advisory jobs use job-level `continue-on-error`; measured 2026-09-04 (run 33847987446 in
this repo): a failed job of that kind reports `needs.<job>.result == 'success'`, so advisory jobs can
never block `docker-build`. `scripts/gate_matrix.py` brute-forces the docker-build and verify gates
on every workflow change.

**Nightly = security only:** on `schedule` events the `changes` job switches the code lanes off
(tests/build/frontend already ran for the same pinned dependencies on the push); only the security
lane runs (CodeQL, pip-audit, Semgrep, Bandit, gitleaks).

## Deploy model (Watchtower, deterministic since 2026-09-04)

`dev` push → `:staging` image → verify-staging POSTs the Watchtower HTTP API on the staging host
(`staging-watchtower-url`, token from the host's `.env`), then polls `staging-version-url` until the
running version equals `github.sha` (budget 40 × 30 s); on failure it retags `:staging-previous` →
`:staging`. `main` push → `:latest` image (+ `:previous` backup) → verify-prod does the same against
prod (`prod-watchtower-url`, `prod-version-url`) and opens an incident issue on failure. Watchtower
polling stays on as fallback (`WATCHTOWER_HTTP_API_PERIODIC_POLLS=true`). Without a Watchtower URL
the verify jobs fall back to polling only; without a version URL they are 200-only (inert).

### Version App-Contract
The app must expose its git SHA: `GET /health → {"status":"ok","sha":"<GIT_SHA>"}` (`commit` and
`version` are accepted too, or the header `X-App-Version`). `GIT_SHA` is passed as a build arg by
`reusable-docker-build`; the app's Dockerfile consumes it (`ARG GIT_SHA` → `ENV APP_SHA`).

### Branch policy (enforced, default on)
Every `main` push is checked by `branch-policy`: HEAD must lie on `dev` (ff-merge) or be a merge
commit with dev as second parent (`--no-ff`/PR). Violation ⇒ run red, docker-build blocked ⇒ no image,
no deploy. Server-side branch protection is a paid feature on the private org repos, so this is the
enforcement. Emergency switch: `enforce-branch-policy: false`.

## Image signing

Images pushed from `main`/tags are signed with **cosign keyless** and get a **SLSA build provenance
attestation**; both steps are best-effort (`continue-on-error`). Staging images are deliberately not
signed (2026-09-04): nothing in the deploy path verifies signatures, Watchtower pulls whatever the tag
points to. Verify externally:

```bash
cosign verify \
  --certificate-identity-regexp '^https://github.com/ADZA-Group/<app>/' \
  --certificate-oidc-issuer 'https://token.actions.githubusercontent.com' \
  ghcr.io/adza-group/<app>:<tag>
gh attestation verify oci://ghcr.io/adza-group/<app>:<tag> --repo ADZA-Group/<app>
```

## Operating model (Azad + Claude, since 2026-09-04)

- **dev** is where Claude (with Codex as reviewer) lands changes after the pair gate: actionlint +
  `gate_matrix.py` + `check_docs.py` run on every workflow change (`actionlint.yml`).
- **@v1** moves only through `release.yml`: candidate branch with rewritten internal refs, smokes on
  the candidate (full orchestrator run, GHCR push on ubuntu), atomic tag push with `RELEASE_TOKEN`.
- **Monday 06:00 UTC** `weekly-release.yml` releases dev automatically when dev is ahead of `@v1`,
  the actionlint gate is green for exactly that SHA, no run for it is still open and no
  `.release-hold` file exists (`touch .release-hold` = emergency stop). Version: minor when a `feat`
  commit landed since `@v1`, otherwise patch. Manual release any time:
  `scripts/release-v1.sh <sha> vX.Y.Z --yes`.
- **Fleet callers** pin `@v1`, so the orchestrator's contract is a floating major: **never remove an
  input or secret** (unknown ones are a `startup_failure` without a job or log — incident 2026-09-04,
  rechnungsapp run 33858079440). Deprecate as a declared no-op with a warning instead; delete only in
  v2. `python scripts/check_callers.py` (needs `gh`) compares every fleet caller on dev **and** main
  against the local reusables — run it before any release that touches inputs.
- **`workflow_dispatch`** is the manual full run: all lanes are forced like on a main push (the path
  filter would otherwise see an empty diff on a repo whose main equals dev), images are never pushed.
- **Dependabot** PRs in the app repos are merged nightly by Jarvis (`routines/code-watch.md`) when the
  run for the exact head SHA is green; in this repo they are cherry-picked onto dev (the gh token
  lacks the `workflow` scope for API merges of workflow files).

## Releasing `@v1` (autonom, Kandidaten-Branch)

```bash
scripts/release-v1.sh <sha> vX.Y.Z [--yes] [--dry-run] [--no-wait]
```

Das Skript baut in einem Wegwerf-Worktree den Kandidaten-Branch `release-vX.Y.Z` = `<sha>` + ein
Commit, der alle internen Refs `adza-group/shared-workflows/...@v1` auf `@release-vX.Y.Z` umschreibt
(damit testen die Smokes den Kandidaten selbst, auch in verschachtelten Aufrufen) und `.release-source`
ablegt. `release.yml` laeuft auf dem Branch: Kandidaten-Check → Smokes (Orchestrator mit voller CI,
Docker-Push auf ubuntu) → atomarer Tag-Push (`vX.Y.Z` + `v1`) auf den Original-SHA → Branch-Cleanup.
Der Tag-Push braucht das Repo-Secret `RELEASE_TOKEN` (fine-grained PAT eines Repo-Admins,
`contents: write`), weil das Ruleset `protect-v1-tag` nur Admins bypassen laesst und GitHub weder die
Actions-Integration noch (org-seitig deaktivierte) Deploy-Keys zulaesst. `release.yml` prueft das Token
vor den Smokes und warnt 14 Tage vor Ablauf. Ohne Secret bleibt der Lauf am Tag-Push stehen (Tags
unberuehrt) und kann nach Anlage per `gh run rerun <id> --failed` fortgesetzt werden.

## Caveats / known gaps

- Only `linux/amd64` images are built and scanned (multi-arch removed 2026-09-04).
- The Watchtower HTTP API must be reachable from the runner (LAN); hosted runners cannot trigger it — the
  verify jobs then fall back to polling.
- Self-hosted runner LXC 104 is the single runner (deliberate); `actions/cache` is never used on it.
