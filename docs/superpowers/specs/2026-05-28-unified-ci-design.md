# Unified ADZA-Group CI/CD — Design Spec

- **Date:** 2026-05-28
- **Status:** Approved (design); pending spec review → implementation plan
- **Owner:** Azad Ahmed (ADZA-Group)
- **Home repo:** `adza-group/shared-workflows`
- **Scope:** One canonical CI/CD pipeline, delivered as a reusable workflow + composite actions, consumed by all ADZA Flask apps (Rechnungsapp, RecyclageApp, FootballApp, MitarbeiterApp) and any future app.

---

## 1. Goal

Replace four independently-drifting `build.yml` pipelines with **one canonical, parameterized pipeline** that merges the strengths of all four, fills their gaps, and is updated in exactly one place. "Perfect" here means: maximally thorough (all four advanced extra-tiers enabled), dual-gated (advisory on PR/dev, blocking on main), fully SHA-pinned, reproducible, and self-documenting.

### Locked decisions (from brainstorming)

| # | Decision | Choice |
|---|---|---|
| 1 | Delivery model | **Reusable workflow + composite actions** in `shared-workflows`; apps are thin callers |
| 2 | Runtime philosophy | **Always thorough** on every push + PR (no branch-based depth-tiering; change-detection only skips lanes whose files didn't change) |
| 3 | Advanced extras | **All four:** property+mutation tests, OPA/conftest policy, frontend-lane+Lighthouse, load+DAST |
| 4 | Gate policy | **Dual:** advisory on PR/dev, blocking on main/tag |
| 5 | mutmut | **Incremental per run** (changed modules only) + **full nightly sweep** |
| 6 | load/DAST/Lighthouse | **Post-deploy on dev** (need a live staging target) + **nightly vs prod** |

---

## 2. Current state

### 2.1 The four app pipelines (ground truth, 2026-05-28)

| App | Jobs | Headline strength contributed to the merge |
|---|---|---|
| **FootballApp** | 21 (+matrix) | `setup-python-deps` composite (system-python + per-job venv + `pip --retries 3 --timeout 60`), per-SHA no-cancel concurrency, `always() &&` cascade discipline, 100% SHA-pinning, 6-way pytest matrix, failure-history header |
| **RecyclageApp** | ~36 | multi-arch build, `require-staging-green` merge gate, auto-rollback (`:previous`↔`:latest`), Cosign+SBOM attest, CodeQL matrix (py+js), DAST/ZAP, k6 load, `monitor.yml`, release-please, 3 composites (`app-pid` output), `uv pip install --system` |
| **Rechnungsapp** | 28 | canonical supporting workflows (branch-discipline, labeler, dependabot-automerge), Postgres+Redis service containers, domain test partitioning (pdf-import, migration-backup), sticky PR-summary comment, auto-issue on prod-verify-fail, license-copyleft gate |
| **MitarbeiterApp** | 9 | frontend lane (eslint-9-flat + tsc + vitest, React-19 SPA), per-area change-detection (FE vs BE), `RUNNER_LABEL`/`*_DEPLOYED` repo-var toggles, multi-stage Vite→Flask Dockerfile |

**Note:** an earlier observed run (#315) showed Hypothesis, mutmut, OPA, Lighthouse, PR-Size-Gate, Dependency-Review — none of these exist in any current repo. They are treated here as **aspirational features to (re)introduce**, which decisions #3/#5/#6 do.

### 2.2 `shared-workflows` real state (cloned, HEAD `02288c5`)

Already present (so we extend, not greenfield) — **but immature:**

| Asset | State | Required change |
|---|---|---|
| `reusable-security-scan.yml` | gitleaks (hard) + bandit/semgrep/trivy/pip-audit (all `continue-on-error`) | Uses `actions/setup-python@v5` → **breaks on Debian-13 self-hosted**. Add CodeQL, OPA, dependency-review. Add **dual-gate**. Pin `trivy-action@master`. |
| `reusable-docker-build.yml` | buildx + size-gate + Trivy + SBOM | `push`/`sign-image` inputs **declared but unwired** (always `push:false`, no cosign). Trivy `exit-code:0` (not a gate). `build-push-action@v5` (apps use v6). Pin trivy. Add smoke-boot. |
| `reusable-load-test.yml` | k6 run + summary | `threshold-p95-ms` declared but **not enforced**. Add real p95/error-rate gate. |
| `reusable-notify.yml` | Discord/Slack/Telegram | **Good & new** — keep, wire into orchestrator failure path. |
| `reusable-monitoring-dashboard.yml` / `-pipeline-analytics.yml` / `-weekly-cleanup.yml` | consumed by apps today | Keep as-is. |
| `setup-python-env` (composite) | `actions/setup-python@v5` + `cache:pip` + tesseract/poppler | **Breaks on Debian-13.** Replace internals with FootballApp's system-python + per-job venv + `pip --retries 3 --timeout 60` + `$GITHUB_PATH` export. Keep system-deps + extra-packages inputs. |
| `health-check` (composite) | polling + security headers + outputs | **Good** — keep; use for verify-staging/prod. |

---

## 3. Target architecture

### 3.1 Orchestrator model

`reusable-ci.yml` is the **single canonical orchestrator**. It owns the entire job DAG once. Stage implementations are delegated to (hardened) sub-reusables and composite actions. App `build.yml` files are ~25-line callers. The DAG never lives in an app repo → zero drift.

```
app/build.yml  ──uses──▶  shared-workflows/reusable-ci.yml  ──┬─uses─▶ reusable-security-scan.yml
   (thin caller)              (the whole DAG, parameterized)   ├─uses─▶ reusable-docker-build.yml
                                                               ├─uses─▶ reusable-load-test.yml
                                                               ├─uses─▶ reusable-notify.yml
                                                               └─composite actions: setup-python-deps,
                                                                  run-pytest-shard, coverage-gate,
                                                                  start-app, health-check, opa-policy
```

Nesting depth: app(1) → reusable-ci(2) → sub-reusable(3) — within GitHub's 4-level limit. **App-specifics are expressed as inputs (data), not jobs.** Domain shards (`pdf-import`, `ml`, `migration`) are entries in a JSON `test-shards` input, so coverage aggregates uniformly. Only truly bespoke workflows (RecyclageApp `monitor.yml` metal-price freshness) stay app-local.

### 3.2 Repo layout (target)

```
shared-workflows/.github/
  workflows/
    reusable-ci.yml                 # NEW — the orchestrator / spine
    reusable-security-scan.yml      # EXTEND — +CodeQL +OPA +dep-review +dual-gate, fix python, pin trivy
    reusable-docker-build.yml       # COMPLETE — wire push+cosign+SLSA+smoke, gate trivy, bump v6, pin
    reusable-load-test.yml          # COMPLETE — enforce p95/error gate
    reusable-notify.yml             # KEEP
    reusable-frontend.yml           # NEW — eslint+tsc+prettier+vitest(+cov)+vite build+bundle-gate+Lighthouse
    reusable-release.yml            # NEW — release-please + changelog (namespace adza-group)
    reusable-dast.yml               # NEW — OWASP ZAP baseline (ubuntu) against a URL
    reusable-mutation.yml           # NEW — mutmut (incremental input + full mode), nightly-capable
    reusable-security-weekly.yml    # NEW — pip-audit+Trivy+OSV+Grype+TruffleHog+Nuclei/ZAP vs prod
    reusable-monitoring-dashboard.yml / -pipeline-analytics.yml / -weekly-cleanup.yml  # KEEP
  actions/
    setup-python-deps/              # REPLACE setup-python-env internals (system-python+venv+retries)
    run-pytest-shard/               # NEW — one shard: venv + services env + cov xml + junit
    coverage-gate/                  # NEW — download all shard cov → coverage combine → gate + PR-delta
    start-app/                      # NEW (port RecyclageApp) — boot Flask, app-pid output, /health poll
    opa-policy/                     # NEW — conftest vs Dockerfile + docker-compose
    health-check/                   # KEEP

each app/.github/
  workflows/build.yml               # thin caller → reusable-ci.yml@v1
  workflows/branch-discipline.yml   # canonical (ubuntu-latest)
  workflows/security-weekly.yml | release.yml | dashboard.yml | pipeline-analytics.yml
                                    | weekly-cleanup.yml | labeler.yml | dependabot-automerge.yml  # thin callers
  workflows/monitor.yml             # RecyclageApp ONLY (bespoke)
  labeler.yml, dependabot.yml       # config stays per-app
```

### 3.3 App-caller input contract (`reusable-ci.yml`)

| Input | Type | Default | Purpose |
|---|---|---|---|
| `app-name` | string | — (req) | image slug + alert title (`ghcr.io/adza-group/<app-name>`) |
| `env-prefix` | string | `""` | test env namespace (`RECHNUNG_`, `FOOTBALL_`, `MITARBEITER_`) |
| `python-version` | string | `"3.11"` | documentation only (composite uses system python) |
| `runner-label` | string(JSON) | `["self-hosted","linux","proxmox"]` | runner selection |
| `test-shards` | string(JSON) | — (req) | `[{"name","paths","markers?"}]` → dynamic matrix |
| `test-env` | string(JSON) | `"{}"` | extra env for test jobs (e.g. `{"RECHNUNG_TESTING":"1"}`) |
| `coverage-threshold` | number | `50` | union-coverage gate |
| `enable-redis` | boolean | `false` | add redis service to test jobs |
| `postgres-version` | string | `"16-alpine"` | test DB service |
| `install-system-deps` | boolean | `false` | tesseract/poppler (RecyclageApp/Rechnungsapp PDF) |
| `has-frontend` | boolean | `false` | enable frontend lane (`reusable-frontend.yml`) |
| `frontend-dir` | string | `"frontend"` | FE working dir |
| `enable-property-tests` | boolean | `true` | hypothesis suite |
| `enable-mutation` | boolean | `true` | mutmut incremental (full = nightly trigger) |
| `enable-opa` | boolean | `true` | conftest policy |
| `enable-dast` | boolean | `false` | ZAP vs staging (post-deploy) |
| `enable-load-test` | boolean | `false` | k6 vs staging (post-deploy) |
| `enable-lighthouse` | boolean | `false` | LHCI vs staging (post-deploy, needs FE) |
| `image-size-budget-mb` | number | `800` | image gate |
| `multi-arch` | boolean | `false` | amd64+arm64 via qemu |
| `staging-url` | string | `""` | verify-staging + post-deploy targets (empty ⇒ skip) |
| `prod-url` | string | `""` | verify-prod target (empty ⇒ skip) |
| `deploy-prod` | boolean | `true` | master switch for prod push+verify (Rechnungsapp ⇒ false) |
| `require-signed-images` | boolean | `false` | cosign-verify gate before deploy |

Secrets: `secrets: inherit` (GHCR via `GITHUB_TOKEN`; cosign keyless via OIDC; Discord/Slack/Telegram optional).

---

## 4. The pipeline spine (DAG)

```
Wave 0  changes (paths-filter) │ runner-health │ commit-lint(PR)
Wave 1  lint-python(ruff+actionlint) │ lint-dockerfile(hadolint) │ [lint-frontend]
        code-quality(radon) │ dead-code(vulture) │ todo-tracker │ license-check(copyleft)
Wave 1b ──uses reusable-security-scan──▶ gitleaks │ bandit │ semgrep │ codeql[py,js]@ubuntu
        │ pip-audit(+npm) │ dependency-review(PR) │ trivy-fs+IaC │ opa-policy
Wave 2  pytest-matrix(fromJSON test-shards) │ [property-tests] │ [frontend-tests] │ [build-frontend+bundle-gate]
Wave 2b test-results(EnricoMi) │ coverage-gate(coverage combine + PR-delta) │ [mutation-incremental]
Wave 3  ──uses reusable-docker-build──▶ build + Trivy-image-GATE + SBOM + smoke + size-gate
Wave 4  build-and-push (GHCR + metadata tags + [multi-arch] + :previous backup + cosign + SLSA)
Wave 5  deploy-staging(dev) → verify-staging(health-check) → require-staging-green(→main)
        → verify-prod(health-check + auto-issue + auto-rollback)        [all behind deploy-prod / urls]
Wave 5b [load-test] │ [dast-zap] │ [lighthouse]   ── need live staging, post-deploy on dev
Wave 6  pipeline-telemetry │ pr-summary(sticky) │ notify(reusable-notify + ci-failure issue)
```

`[bracketed]` jobs are enabled by an input. Every dependent job uses `if: always() && (needs.X.result == 'success' || == 'skipped')` cascade guards and `!cancelled()` on the deploy path (the hard-won GHA skip-cascade fixes). Every job has `timeout-minutes`. Concurrency (set in the app caller): `group: ${{ github.workflow }}-${{ github.ref }}-${{ github.sha }}`, `cancel-in-progress: false`.

---

## 5. Component specs

### 5.1 Composite actions

- **`setup-python-deps`** (replaces `setup-python-env` internals): verify system `python3`; ensure pip+venv (apt if missing); cache pip downloads (`actions/cache`, key `pip-${os}-sys-${suffix}-${hashFiles(requirements.txt)}`); create per-job venv at `$RUNNER_TEMP/<app>-venv`, export `$VENV/bin` to `$GITHUB_PATH`; `pip install --retries 3 --timeout 60 -r requirements.txt` + extras. Inputs: `install-system-deps` (tesseract/poppler/fra+deu), `extra-packages`, `cache-key-suffix`, `install-coverage`. **No `actions/setup-python`.**
- **`run-pytest-shard`**: inputs `name`, `paths`, `markers`, `env-json`, `enable-redis`, `postgres-version`. Starts postgres (+redis) service, sets env from `env-json` + `<PREFIX>_TESTING=1`, `<PREFIX>_DISABLE_SCHEDULER=1`, `<PREFIX>_DATABASE_URL`; runs `pytest <paths|-m markers> --timeout=60 --cov=. --cov-report=xml:cov-<name>.xml --junitxml=junit-<name>.xml`; uploads `cov-<name>` + `junit-<name>` artifacts (`continue-on-error` on upload — quota survival).
- **`coverage-gate`**: download all `cov-*` artifacts → `coverage combine` (real union, replacing the `max()` heuristic) → `coverage xml/report` → fail if `total < threshold` (single source of truth) → on PR, post a coverage-delta comment vs base.
- **`start-app`** (port from RecyclageApp): boot Flask (`init_db`, seed, `app.run` backgrounded), output `app-pid`, poll `/health` 30s. Shared by DAST/Lighthouse/integration when a live local app is needed.
- **`opa-policy`**: `conftest test Dockerfile docker-compose*.yml --policy policy/`. Rego policies: non-root USER, pinned base image (no `:latest`), HEALTHCHECK present, no secrets in ENV, compose has `restart` + resource limits. Dual-gated.
- **`health-check`**: keep as-is (polling + security headers + outputs).

### 5.2 Reusable sub-workflows

- **`reusable-security-scan.yml`** (extend): swap `actions/setup-python` → `setup-python-deps`; pin `trivy-action` to a release SHA; add `codeql` job (matrix `[python, javascript-typescript]`, `runs-on: ubuntu-latest` for RAM, `security-extended`); add `dependency-review` (PR-only); add `opa-policy` job; implement **dual-gate** via `continue-on-error: ${{ !(github.ref=='refs/heads/main' || startsWith(github.ref,'refs/tags/')) }}` on bandit/semgrep/trivy/pip-audit/codeql/opa. gitleaks stays hard always.
- **`reusable-docker-build.yml`** (complete): bump `build-push-action@v6`; pin `trivy-action`; make Trivy image scan a **gate** (`exit-code: 1`, `ignore-unfixed: true`) — dual per branch; add **smoke-boot** (`docker run` + `/health`, `--workers 1 --preload`); wire `push` (GHCR login + `metadata-action` tags) and `sign-image` (cosign keyless + `attest-build-provenance`) that are currently declared-but-dead; add `:latest`→`:previous` backup on main; multi-arch via qemu when requested.
- **`reusable-load-test.yml`** (complete): enforce `threshold-p95-ms` and error-rate<1% as a real gate (parse k6 JSON summary, `exit 1` on breach; advisory off main).
- **`reusable-frontend.yml`** (new): `setup-node` + `cache: npm`; **`npm ci`** (requires committed lockfile — see risks); `eslint`, `tsc -b --noEmit`, `prettier --check`, `vitest run --coverage` (FE coverage threshold), `vite build` + bundle-size gate; optional Lighthouse-CI against `staging-url`.
- **`reusable-release.yml`** (new): release-please (`release-type: simple`, custom `secure`/`harden` changelog sections, `include-v-in-tag`) + tag-triggered changelog via `softprops/action-gh-release`. **Image/repo namespace = `adza-group`** (fixes RecyclageApp's stale `azad-ahmed`).
- **`reusable-dast.yml`** (new): OWASP ZAP baseline on `ubuntu-latest` against a URL, custom exit-code logic (FAIL>0 blocks, WARN tolerated). Used post-deploy (staging) + weekly (prod).
- **`reusable-mutation.yml`** (new): mutmut. `mode: incremental` (mutate only changed files vs base ref) for build.yml; `mode: full` for nightly cron. Always advisory (reports surviving mutants to summary).
- **`reusable-security-weekly.yml`** (new): consolidate the richest weekly sweep — pip-audit + Trivy fs/image + OSV-Scanner + Grype + TruffleHog + Nuclei/ZAP vs prod.

### 5.3 `reusable-ci.yml` (orchestrator)

Owns Waves 0,1,2,2b,4,5,6 as direct jobs; delegates Wave 1b to `reusable-security-scan`, Wave 3 to `reusable-docker-build`, Wave 5b to `reusable-load-test`/`reusable-dast`/`reusable-frontend(lighthouse)`, failure path to `reusable-notify`. Passes all inputs through. Builds the dynamic test matrix from `fromJSON(inputs.test-shards)`.

---

## 6. Cross-cutting policies

- **Gate policy (dual):** `BLOCKING = ref==main || tag`. Advisory-on-PR/dev / hard-on-main for: bandit, semgrep, pip-audit, npm-audit, trivy-fs/IaC, codeql, opa, radon, vulture, license-check, mutation, load-test, dast, lighthouse. **Always hard:** gitleaks, ruff, pytest, coverage-gate, trivy-image, require-staging-green.
- **Action pinning:** all third-party actions SHA-pinned with `# vX.Y.Z` comment (kills `@master`/floating-tag drift). First-party `actions/*` + `github/codeql-action/*` may stay major-tag. `shared-workflows` gets its own `dependabot.yml` to bump pins → one update point. Resolves MitarbeiterApp's Node-20 deprecation centrally.
- **Change detection:** `dorny/paths-filter` outputs python/frontend/docker/deps/ci/templates + `any_code` + `start_time`. Gates lanes by changed files only (no depth reduction by branch — honors "always thorough").
- **Runner strategy:** `self-hosted, linux, proxmox` default; CodeQL + DAST forced to `ubuntu-latest` (RAM/determinism). `runner-label` input overrides (MitarbeiterApp uses `vars.RUNNER_LABEL || ubuntu-latest`).
- **Services:** test jobs get postgres (`postgres-version`) + optional redis as job service containers; DB URL built from ephemeral port.

---

## 7. Supporting-workflow unification

| Workflow | Canonical source | Model |
|---|---|---|
| `branch-discipline.yml` | Rechnungsapp | per-app, ubuntu-latest, enforce `{main,dev,dependabot/**}` + best-effort delete |
| `dependabot-automerge.yml` | Rechnungsapp | thin caller; patch/minor auto, major manual; **re-enable Dependabot in RecyclageApp** |
| `labeler.yml` | Rechnungsapp | thin caller |
| `security-weekly.yml` | RecyclageApp (richest) | → `reusable-security-weekly.yml` |
| `release.yml` | RecyclageApp | → `reusable-release.yml` (namespace fixed) |
| `dashboard / pipeline-analytics / weekly-cleanup` | existing reusables | keep |
| `monitor.yml` | RecyclageApp | stays bespoke (app-specific) |

---

## 8. Per-app caller configs (concrete)

- **Rechnungsapp:** `env-prefix: RECHNUNG_`, `coverage-threshold: 49`, `enable-redis: true`, `install-system-deps: true`, shards `[backend, integration, pdf-import, migration]`, `enable-dast: true`, `has-frontend: false`, `deploy-prod: false` (LXC-103 freeze), urls set.
- **RecyclageApp:** `install-system-deps: true` (tesseract/poppler), `has-frontend: true`, `enable-dast: true`, `enable-load-test: true`, `multi-arch: true`, urls set, `monitor.yml` (metal-price freshness) retained. Shards: its tests are currently one monolithic `test-backend` job — split by area during migration (e.g. `models`, `routes`, `importers`, `integration`) + keep the French keyword/company-detection regression check.
- **FootballApp:** `env-prefix: FOOTBALL_`, `coverage-threshold: 50`, shards `[smoke, models, auth, routes, importers, ml]`, `has-frontend: false`, urls = "" until staging LXC exists.
- **MitarbeiterApp:** `has-frontend: true`, `enable-lighthouse: true`, shards `[backend]`, `runner-label` via `vars.RUNNER_LABEL`, verify behind `vars.*_DEPLOYED`, **add committed `frontend/package-lock.json` + `npm ci`**, FE coverage gate, Node-20 pins fixed centrally.

---

## 9. "Always thorough" reconciliation

- Waves 0–4 run on **every push + PR** at full depth (change-detection only skips lanes whose files didn't change).
- mutmut: **incremental** (changed modules) per run (~2–4 min) + **full nightly** cron sweep. Always advisory.
- load / DAST / Lighthouse: require a deployed staging URL → run **post-deploy on dev** against `i-<app>.adza-group.ch`, plus **nightly vs prod** in the weekly sweep. Not a speed-tier — a hard dependency on a live target.

---

## 10. Rollout plan

1. Harden/complete `shared-workflows` (composites first, then sub-reusables, then `reusable-ci.yml`); validate in isolation with a throwaway smoke repo.
2. Tag `shared-workflows@v1`; app callers pin `@v1` (not `@main`) for reproducibility.
3. **Pilot: FootballApp** on `dev` → staging-smoke (lowest prod risk, youngest).
4. Roll out **RecyclageApp → MitarbeiterApp → Rechnungsapp**, one at a time, dev-first, staging-smoke each.
5. **Rechnungsapp:** `deploy-prod: false` — prod LXC-103 (monolith+SQLite) incompatible with multi-container; CI runs, no prod deploy until Sprint 1R.

---

## 11. Risks & open questions

- **MitarbeiterApp has no committed `frontend/package-lock.json`** → `npm ci` will fail. Must generate+commit a lockfile first (prerequisite task).
- **Nested reusable depth:** app→ci→sub = 3 levels (limit 4). Adding a 4th nested reusable inside a sub-reusable would break — keep sub-reusables flat (jobs+composites, not further nested reusables).
- **Single runner pool (LXC-104)** is a SPOF for all self-hosted jobs; out of scope to fix here but noted.
- **Secrets for notify** (Discord/Slack/Telegram) are optional; absent ⇒ steps skip cleanly.
- **CodeQL on ubuntu-hosted** consumes GitHub-hosted minutes (private repos) — acceptable; document cost.
- **Coverage combine** requires consistent `--cov` source roots across shards; verify per app.

## 12. Out of scope (YAGNI)

- Fixing the LXC-104 SPOF / adding a second runner pool.
- Migrating Rechnungsapp prod off SQLite/monolith (Sprint 1R).
- Non-Flask apps (paperless) — pattern can extend later but not now.
- Replacing Watchtower pull-based deploy with push-based.
