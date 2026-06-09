# CLAUDE.md — `shared-workflows` (ADZA-Group Unified CI)

> **Für Claude (neue Session):** Dies ist der Wiederaufnahme-Handoff für die Unified-CI-Initiative.
> Stand **2026-06-03**, branch `dev`. **Released: floating `@v1` = `v1.5.0` (commit `ff674f6`) — verifiziert via `git ls-remote`.** Lies das hier zuerst.
>
> **🚀 CI-POWER-UP läuft** (Senior-Level „alles abdecken", Umbrella-Spec `docs/superpowers/specs/2026-06-03-senior-ci-powerup-design.md`, 6 Phasen, Reihenfolge A✅→B→F→C→E→D):
> **Phase A ✅ released (v1.5.0):** diff-coverage-gate (changed-line, default 80%, dual-gate, in `coverage-gate`-Composite + reusable-ci coverage-job `fetch-depth:0`) + `pytest-rerun-failures` flaky-auto-rerun (`test-reruns`-Input in `run-pytest-shard`). Composites live; empirische coverage-job-Validierung läuft beim nächsten App-Push mit Python-Code-Änderung. Plan: `docs/superpowers/plans/2026-06-03-ci-powerup-phaseA-test-depth.md`.
> **Phase B ✅ released (v1.5.1):** cosign keyless + SLSA attest fleet-weit AN — `sign-image`-Default in `reusable-docker-build.yml` von `false`→`true` (Konsistenz mit `reusable-ci.yml`, das es seit 2026-05-28 schon hatte) + FootballApp-Caller `sign-image: false` Override entfernt → alle 4 Apps signieren by default. Steps bleiben `continue-on-error: true` (Sigstore-Outage/Org-Limit advisory). README hat neue Sektion "Image signing & verification" mit `cosign verify` + `gh attestation verify` Snippets + opt-in `require-signed-images`-Gate. Empirische Validierung (Plan-Task 6, pending): FootballApp dev-Run nach v1.5.1-Release erwartet `Cosign sign (keyless)` + `SLSA build provenance` Steps grün; wenn Sigstore-Outage oder Org-Limit → advisory rot, kein Blocker. Plan: `docs/superpowers/plans/2026-06-03-ci-powerup-phaseB-cosign-fleet-wide.md`.
> **Phase F ✅ released (v1.5.3):** `reusable-config-ci.yml` (yamllint + `docker compose config` + gitleaks + OPA/conftest, dual-gate, runner-label-driven) für die compose-only Infra-Repos `paperless` + `cloudflare`; je ~20-Zeilen `ci.yml`-Thin-Caller. **Empirisch validiert:** cloudflare dev+**main** GRÜN (Run `26935409227`), paperless dev GRÜN. **Lektion (dev≠main):** yamllint-Step nutzte `pip --user` → PEP-668 `externally-managed` → auf dev advisory (still grün), auf main BLOCKING → cloudflare-main-Run `26935300119` rot. Fix `874a42b`: yamllint in throwaway-venv (ubuntu+self-hosted), fallback `--user`→`--break-system-packages`. **v1.5.2 war transienter Mistag (vor PEP-668-Fix); echter Release = `v1.5.3` = `@v1`.** Smoke `_smoke-config-ci.yml` grün auf ubuntu. Plan: `docs/superpowers/plans/2026-06-03-ci-powerup-phaseF-config-ci.md`.
> **Phase C ✅ released (v1.5.4):** pa11y-ci a11y-Gate in `reusable-frontend.yml` (`a11y-*`-Inputs: scan URL ODER lokal-served Build-Output, headless-Chrome `--no-sandbox`, dual-gate) + `lighthouse-config`-Input für `lighthouserc.json`-Budget (Template in `tests/fixtures/frontend/`). Smoke `_smoke-frontend.yml` grün auf ubuntu (a11y-Step `success` gegen served Fixture-Build). Für Jinja/HTMX-Apps: `a11y-url` auf Staging zeigen; SPAs: leer lassen → lokaler Build-Scan. Plan: `docs/superpowers/plans/2026-06-04-ci-powerup-phaseC-frontend-a11y.md`.
> **Phase E ✅ released (v1.5.5):** (1) **PR-concurrency-Fix** in allen Callern — `group` von `…-${{ github.sha }}` auf `…-${{ github.ref }}` (sha gedroppt, sonst war jede SHA eigene Group → cancel feuerte NIE) + `cancel-in-progress: ${{ github.event_name == 'pull_request' }}` (superseded PR-Runs canceln, push/main-Deploys nie unterbrechen). Config-Caller (paperless/cloudflare) + 3 stabile App-Caller (rechnungsapp/recyclage-app/MitarbeiterApp) angewendet; FootballApp übersprungen (NO-SHIP v3 auf dev — nachziehen bei nächstem dev→main). (2) **Opt-in `prod-environment`/`staging-environment`-Inputs** auf verify-prod/verify-staging (default '' = kein Gate; empty-env via `_smoke-env` bewiesen ungefährlich → kein startup_failure). Gibt freies Deployment-Tracking. **⚠️ Befund: required-reviewer-Approval ist auf PRIVATEN Repos PAID** (`gh api`→`422 billing plan`), `production`-Env anlegbar aber Reviewer-Regel braucht Team/Pro. Watchtower-pull-Deploy hat eh keinen gate-baren Job → echtes pre-deploy-Approval würde `:latest`-Push gaten (separates Design, nicht gebaut). Plan: `docs/superpowers/plans/2026-06-04-ci-powerup-phaseE-deploy-env-concurrency.md`.
> **Phase D ✅ released (v1.5.6):** `reusable-api-contract.yml` (schemathesis property-based fuzzing; `start-app` composite + dual-gate). Opt-in `openapi-spec`-Input in `reusable-ci.yml` → `api-contract`-Job, **skip wenn leer** (alle aktuellen Apps → skipped, kein OpenAPI-Spec). Smoke `_smoke-api-contract.yml` grün auf ubuntu gegen Flask-Fixture mit `/openapi.json` (schemathesis-Step `success`). **⚠️ App-Code-Folgearbeit (NICHT CI):** Apps müssen erst ein OpenAPI-Spec emittieren (flask-smorest/apispec) bevor api-contract greift. Plan: `docs/superpowers/plans/2026-06-04-ci-powerup-phaseD-api-contract.md`.
> **🏁 CI-POWER-UP KOMPLETT (A–F alle released):** A=v1.5.0 (diff-cov+flaky) · B=v1.5.1 (cosign fleet) · C=v1.5.4 (a11y) · D=v1.5.6 (api-contract) · E=v1.5.5 (env+concurrency) · F=v1.5.3 (config-CI). `@v1`=v1.5.6.
>
> **✅ 2026-06-09 VERIFIZIERT (Audit + git) + AUDIT-HÄRTUNG auf `dev`:** `git tag` zeigt v1.5.0–v1.5.7,
> `v1`→v1.5.7 → A–F sind real released; api-contract (Phase D) ist gebaut+verdrahtet (skippt nur mangels
> App-OpenAPI-Spec). **Neu auf `dev` (Spec/Plan `2026-06-09-ci-deploy-gate-c2-e2e`), empirisch ubuntu-validiert:**
> B1 (`pytest-rerunfailures`-Fix), C1-It.1 (security+coverage+e2e in `docker-build.needs`, coverage dual,
> fail-closed), C2 (opt-in version-assert), **Phase G** (`reusable-e2e.yml`, opt-in). Audit-Befunde M1
> (SHA-Pin Floating-Actions) + N1 (toter `setup-python-env`) wurden parallel in `baaddff` erledigt; zusätzlich
> `_smoke-ci` `actions:read` + 2 api-Fixture-Lint-Fixes. **OFFEN (Resume):** (a) **T8-Release**: e2e-Ref in
> `reusable-ci.yml` von `@dev`→`@v1` flippen, dann `v1.6.0` taggen + `@v1` force-moven; (b) **C1-It.2** =
> Candidate-Tag-Promotion (echtes Staging→Prod-Gate; `:latest` wird noch im build-Job gepusht); (c) C2/e2e
> App-Aktivierung pro Repo (`/health`-SHA bzw. Playwright-Specs); (d) PR-only-to-main als Branch-Protection-Pflicht.
>
> **▶️ RESUME-PUNKT (2026-06-03) — Self-Hosted-CI-Umbau IMPLEMENTIERT (v1.4.1+v1.4.2):** GitHub-Actions-Gratis-Minuten waren
> erschöpft (`ADZA-Group` 2126/2000, $0 Spend) → hosted-Runner org-weit geblockt. **Fix = Fleet-CI voll self-hosted-fähig gemacht:**
> 1. `decide-runner`-Fallback invertiert (kein-PAT / Billing-unlesbar / Minuten-niedrig → **self-hosted** statt hosted) in allen 4 App-Callern + dev→main.
> 2. **ALLE hardkodierten hosted-Stellen in `reusable-ci`/`reusable-security-scan` entfernt** (v1.4.1: codeql + dependency-review `runs-on`→runner-label;
>    v1.4.2: `frontend` + `dast` `runner-label`-Input war `'["ubuntu-latest"]'` hardkodiert → forwardet jetzt `${{ inputs.runner-label }}`). `grep ubuntu-latest reusable-ci.yml` = 0.
> 3. RecyclageApp `multi-arch:false` (amd64-only, kein QEMU-OOM auf 4 GB self-hosted).
> **Empirisch bewiesen:** `decide-runner`→self + `Detect Changes` success auf self-hosted, **0 Billing-Blocks** für runner-label-Jobs.
> **OFFEN (Queue/Versions-Realität):** 3× LXC-104-Runner (runner-4 AUS = 4 GB-OOM-Linie) verarbeiten den Validierungs-Backlog LANGSAM.
> Die main-Runs der 2 Frontend-Apps (RecyclageApp/MitarbeiterApp), die auf **v1.4.1** starteten, tragen noch den frontend-Billing-Block →
> brauchen einen **frischen Run auf @v1=v1.4.2** (proven-by-construction grün; Rechnungsapp/FootballApp ohne Frontend sind schon entsperrt).
> **Nächster Schritt:** Queue abwarten/abräumen → fresh v1.4.2-Runs der Frontend-Apps grün verifizieren. **Alternativ (sofort):** Spending-Limit > $0 → hosted frei.
> **Deploy-Tail (v1.4.0) noch offen:** DT4 (watchtower `--cleanup` Composes + RecyclageApp `containrrr→nickfedor`, SSH-LXC) + DT5 (rollback-Test). Plan: `docs/.../plans/2026-06-01-deploy-tail-rollback-cleanup.md`.
> Self-Hosted-Spec/Plan: `docs/.../specs|plans/2026-06-03-self-hosted-ci-runner-selection*.md`.
> Globale Arbeitsregeln: `~/.claude/CLAUDE.md`. Detail-Memory: `~/.claude/projects/.../memory/project_unified_ci.md`.
>
> **TL;DR Endstand:** Die CI-Bibliothek ist FERTIG, hermetisch, released. Apps pinnen `@v1`.
> Interne Refs der Reusables zeigen auf floating `@v1` (NICHT @dev/exact) → kein Drift, kein Re-Pin-Churn.
> Lint-Gates (ruff/dockerfile/eslint/tsc) advisory auf PR/dev, hart auf main/tags; **Tests immer hart**.
>
> **🔴 ROOT-CAUSE-INCIDENT 2026-06-01 (`@v1`-Mispoint):** `@v1` zeigte real auf die **stale v1.3.1-Linie**
> (`894dabb`→`8d08c4e`, NICHT auf der `dev`-Historie), während die Doku „v1.3.6" behauptete. Folge: ALLE
> `@v1`-Apps liefen wochenlang auf **v1.3.1** — die v1.3.2–v1.3.6-Verbesserungen (Semgrep/pip-audit von
> dual-gate → **immer advisory**) kamen NIE an → **`main` rot** (Semgrep/pip-audit blockten auf main).
> **Fix:** `git tag -f v1 93c06b4` + `push -f` (verifiziert). **Lehre:** `@v1`-Ziel NIE aus Doku/Memory glauben
> — immer `git ls-remote origin refs/tags/v1` + `git log -1 <sha>`. Force-Move nur nach `git log v1 --not dev` (Verlust-Check).
>
> **🔴 ROOT-CAUSE-INCIDENT 2026-06-01 (CodeQL „immer rot" — ZWEI Schichten):** v1.3.7 (`upload:false` +
> hadolint `--failure-threshold error`) war die **falsche Ebene** + lief gar nicht. Echte Ursachen (via
> systematic-debugging + Web-Verifikation gegen `github/codeql-action#2117`):
> **(1) Orchestrator-Drift:** `reusable-ci.yml` pinnte ALLE 18 internen Refs auf `@v1.3.1` (stale), während
> alle anderen Reusables längst `@v1` floateten → reusable-ci@v1 zog **security-scan@v1.3.1** → mein
> `upload:false`-Edit (in security-scan@dev) **wurde nie ausgeführt**.
> **(2) Fehlendes `actions: read`:** CodeQL ruft auf PRIVATEN Repos `GET /actions/runs/{id}` → ohne den Scope
> `Resource not accessible by integration` → „configuration error". Pflicht-Scope laut codeql-action#2117
> (NICHT GHAS — `advanced_security: null` auf allen Repos, daher bleibt `upload:false` korrekt).
> **v1.3.8-Fix (verifiziert GRÜN auf RecyclageApp dev):** (a) reusable-ci interne Refs `@v1.3.1`→`@v1` (de-staled);
> (b) `actions: read` durch die **3-Schicht-Kette** App-Caller → reusable-ci `security`-Job → `codeql`-Job;
> (c) `upload:false` + hadolint-threshold bleiben (aus v1.3.7).
> **🔑 LEHRE:** Wenn du eine genestete Reusable editierst, prüf IMMER die **Pins im Orchestrator** (`grep '@v1\.' reusable-ci.yml`)
> — ein stale `@v1.3.x` heißt deine Edits an @v1/@dev laufen nicht. Permissions müssen durch JEDE Caller-Schicht (App→orchestrator-job→nested-job).
> **Rollout (2026-06-01):** `actions: read` in alle 4 App-Caller (Pflicht-Scope, sonst greift v1.3.8 nicht).
> **CodeQL verifiziert GRÜN** (lief, NICHT skipped): RecyclageApp dev+**main**, Rechnungsapp dev, MitarbeiterApp dev
> (je py+js `success`). FootballApp dev queued (Caller gefixt, identische Config → erwartet grün, noch nicht empirisch bestätigt).
> **Rechnungsapp/FootballApp/MitarbeiterApp `main`-Merge VERSCHOBEN** (User-Entscheidung 2026-06-01: kein zusätzlicher
> Prod-Rebuild jetzt). Diff ist CI-only (build.yml `actions:read`, nicht im Image) → fließt risikolos beim nächsten
> normalen dev→main-Flow auf `main`. RecyclageApp `main` ist bereits grün gemergt (`22261b7`).

---

## 🎯 Ziel der Initiative

EINE kanonische `reusable-ci.yml` + Composite-Actions in diesem Repo ersetzen die vier
unabhängig driftenden `build.yml` der ADZA-Apps (Rechnungsapp, RecyclageApp, FootballApp,
MitarbeiterApp). Jede App wird zum **~25-Zeilen-Caller** → null Drift. Domain-Spezifika
sind **Inputs (Daten)**, keine eigenen Jobs (z.B. `test-shards` JSON).

Entstanden via `superpowers` brainstorming → writing-plans → subagent-driven-development.
**Spec:** `docs/superpowers/specs/2026-05-28-unified-ci-design.md` (lies §8 für Per-App-Caller-Configs).
**Pläne:** `docs/superpowers/plans/2026-05-28-unified-ci-*.md`.

---

## ✅ Stand: was GEBAUT + VALIDIERT ist

**Alles actionlint-clean + GRÜN auf ubuntu-hosted validiert** (das self-hosted LXC-104
Dispatch hängt — ubuntu-hosted umgeht das und beweist die Logik end-to-end):

| Stück | Status |
|---|---|
| Composites: `setup-python-deps`, `run-pytest-shard`, `coverage-gate`, `start-app`, `opa-policy`(+Rego) | ✅ grün (ubuntu) |
| `reusable-frontend` (eslint/tsc/vitest/vite build/bundle-gate) | ✅ grün (ubuntu) |
| `reusable-security-scan` (gitleaks/bandit/semgrep/trivy/pip-audit/CodeQL/dep-review/OPA, dual-gate) | ✅ grün (ubuntu) |
| `reusable-docker-build` (buildx/size-gate/trivy-gate/SBOM/smoke/+push+cosign+SLSA+multi-arch) | ✅ grün (ubuntu) |
| **`reusable-ci.yml` Orchestrator (FULL chain, alle ~17 Jobs inkl. postgres+redis-Matrix)** | ✅ grün (ubuntu) |
| `reusable-load-test` (k6 p95/error-gate) | gebaut, NICHT validiert (braucht Live-Ziel) |
| `reusable-notify` / `-monitoring-dashboard` / `-pipeline-analytics` / `-weekly-cleanup` | vorbestehend |
| **Cycle B — ALL new reusables** (`reusable-dast`, `reusable-mutation`, `reusable-release`, `reusable-security-weekly`) + Lighthouse in `reusable-frontend` | ✅ grün (ubuntu) |

2 Code-Reviews (opus) + 6+ echte Bugs gefangen & gefixt (Permissions-Eskalation,
coverage-false-green, opa-rego-cross-fire, eslint-parser, fehlende checkouts, conftest-import).

## ❌ Was OFFEN ist (Wiederaufnahme-Punkte, Stand 2026-06-01)

1. **App-Test-Remediation (3 Apps)** — RecyclageApp/MitarbeiterApp/Rechnungsapp sind auf `@v1` migriert, die Pipeline LÄUFT korrekt (kein startup_failure mehr), Lint ist advisory — ABER ihre **Test-Suites scheitern am harten Test-Gate**. RecyclageApp verifiziert: postgres+redis starten sauber → **kein CI-/Config-Bug, echte App-Test-Fails**. Das ist App-Code-Arbeit PRO REPO (je App: `systematic-debugging` der Test-Fails bis grün), getrennt von der CI. **Nächster Schritt wenn gewünscht:** eine App vornehmen (RecyclageApp zuerst), Tests grün machen.
2. **MitarbeiterApp + Rechnungsapp**: ihre CI-Migration-Commits sind lokal committed aber teils noch nicht gepusht (+ fremde Feature-WIP im Working-Tree dieser Repos — NICHT mit-pushen!). Vor App-Arbeit: pro Repo `git status` prüfen, fremde WIP respektieren.
3. **FootballApp** pinnt `@v1.3.0` (exakt, grün); fleet-konsistenter wäre `@v1` — optionaler Angleich.
4. **LXC-104 self-hosted Runner** sind FLAKY + 4 GB RAM (OOM-Risiko bei 4 parallel schweren Jobs). Apps ohne `runner-label`-Override laufen dort. Für stabile self-hosted-Läufe ggf. Re-Registrierung / mehr RAM. Validierung lief deshalb auf ubuntu (`runner-label: '["ubuntu-latest"]'`).
5. **`reusable-load-test` + DAST/Lighthouse** brauchen Live-Staging-Ziele → noch nicht runtime-validiert.

---

## 🧩 Repo-Struktur

```
.github/workflows/
  reusable-ci.yml              # DER Orchestrator (changes→lint→security→test-matrix→coverage→docker-build→telemetry)
  reusable-security-scan.yml   # +CodeQL +dep-review +OPA, dual-gate (advisory PR/dev, blocking main/tag)
  reusable-docker-build.yml    # build+scan+SBOM+smoke (+ push+cosign+SLSA+multi-arch wenn push=true)
  reusable-load-test.yml       # k6 p95/error budget
  reusable-frontend.yml        # node lane, ubuntu-default
  reusable-notify / -monitoring-dashboard / -pipeline-analytics / -weekly-cleanup
  _smoke-*.yml                 # workflow_dispatch Smokes (composites, -ubuntu, security-scan, docker-build, frontend, ci)
.github/actions/
  setup-python-deps/           # System-python3 + per-job venv + cached deps (Debian-13-safe; ersetzt legacy setup-python-env)
  run-pytest-shard/ coverage-gate/ start-app/ opa-policy/(+policy/*.rego) health-check/
tests/fixtures/{app,docker,frontend}/   # Smoke-Fixtures
docs/superpowers/{specs,plans}/         # Design + Pläne
README.md                    # Asset-Liste + Caller-Contract + Caveats
```

## 📞 Caller-Contract (so ruft eine App `reusable-ci` auf)

Siehe `README.md` „Consuming reusable-ci.yml". **Kritisch: der App-Caller MUSS diesen
`permissions`-Block setzen** (sonst `startup_failure`):
```yaml
permissions: { contents: read, packages: write, id-token: write, attestations: write, security-events: write, checks: write }
```
Pflicht-Inputs: `app-name`, `test-shards` (JSON `[{name,paths,markers?,cov?}]`). DB-URL in `test-env` (JSON).

---

## ⚠️ GOTCHAS (hart erarbeitet — nicht nochmal reinlaufen)

1. **`uses: ./...` in einem reusable workflow löst gegen das CALLER-Repo auf**, nicht shared-workflows.
   → Composites/Sub-Reusables per VOLLEM Pfad + literalem Ref referenzieren:
   `adza-group/shared-workflows/.github/actions/<name>@<ref>` (keine `${{ }}` im `uses:`-Ref).
   Build-out: `@dev`; bei Release → `@v1`.
2. **Ein CALLED workflow GITHUB_TOKEN kann NICHT mehr als der Caller** → sonst `startup_failure`
   ("workflow file issue"). Caller muss die Scopes oben gewähren; `reusable-ci` claimt per-job.
3. **`gh workflow run` dispatcht nur Workflows auf dem DEFAULT-Branch** (dev-only Smokes → 404).
   Validieren via temporärem `push:[dev]`-Trigger im Smoke (danach zurücknehmen).
4. **LXC-104 Runner-Dispatch hängt:** Runner sind laut GitHub `online`+`idle`, nehmen aber keine
   Jobs an (Zombie-Dispatch). Ausgeschlossen: runner-group (=all repos), labels (match Apps),
   Konnektivität (curl=200), GitHub-Incident, Code. `systemctl restart actions.runner.*` half NICHT.
   Wahrscheinlich **Voll-Re-Registrierung nötig** (`config.sh remove` + neu). SSH: `ssh root@192.168.1.20`
   → `pct exec 104 -- ...`. **Bis dahin: alles ubuntu-hosted validieren** (`runner-label: '["ubuntu-latest"]'`).
5. **eslint flat config** braucht `typescript-eslint`; `tseslint.configs.base` ist ein EINZELNES
   Objekt (NICHT spreaden).
6. **opa-policy:** dockerfile.rego + compose.rego teilen `package main` → conftest wendet alle
   Regeln auf jeden Input an → dockerfile-Regeln mit `is_dockerfile`-Guard schützen (sonst Cross-Fire auf compose).
7. **Coverage portabel:** `relative_files = true` in run-pytest-shard (sonst absolute Pfade →
   coverage-gate-Job kann sie nicht auflösen).
8. **Git in diesem Clone hat KEINE user-config** → committen mit
   `NAME=$(git log -1 --format='%an'); EMAIL=$(git log -1 --format='%ae'); git -c user.name="$NAME" -c user.email="$EMAIL" commit -m ...`
   (NIE `git config` setzen — globale ADZA-Regel).
9. **Offene Review-Items (Design-Entscheidungen, in README CAVEATS):** M4 (Multi-Shard
   postgres-Port-Kollision auf den 4 same-host Runnern → dynamische Ports vor FootballApps 6 Shards);
   arm64 nicht separat Trivy-gescannt; frontend-only docker-build-Gate.

---

## 🔧 Wie man ein Stück auf ubuntu validiert (das Muster dieser Session)

1. Im Smoke-Caller `runner-label: '["ubuntu-latest"]'` setzen (Override; reusable-ci reicht es an
   nested Reusables durch) + temporär `on: { push: { branches: [dev] } }` hinzufügen.
2. `./bin/actionlint.exe <wf>` (exit 0) — actionlint.exe liegt in `bin/` (nicht committet); yamllint via `python -m yamllint -d relaxed`.
3. committen + `git push origin dev` → der push-Trigger feuert den Smoke auf ubuntu (NICHT vom LXC-104-Block betroffen).
4. `gh run watch <id> --exit-status` → grün?
5. Bei Fehler: `gh run view <id> --log-failed` → fixen (systematic-debugging) → re-push.
6. Nach grün: den temporären `push:[dev]`-Trigger wieder rausnehmen (Smoke = `workflow_dispatch`-only).

## ▶️ Empfohlener nächster Schritt

**Option A (entblockt alles):** LXC-104 Runner-Dispatch fixen (GOTCHA #4, Voll-Re-Registrierung)
→ dann self-hosted-Validierung + P4-Pilot (FootballApp zuerst, dev-first).
**Option B:** P3b (Deploy-Tail) + neue Reusables bauen (gegen Live-Staging validieren).
**Option C:** P4-Pilot-Migration vorbereiten (FootballApp build.yml → reusable-ci@dev-Caller, Config aus Spec §8).
