# CLAUDE.md — `shared-workflows` (ADZA-Group Unified CI)

> **Für Claude (neue Session):** Dies ist der Wiederaufnahme-Handoff für die Unified-CI-Initiative.
> Stand **2026-06-01**, branch `dev` (gepusht). **Released: floating `@v1` = `v1.3.2` — HERMETISCH + reif.** Lies das hier zuerst.
> Globale Arbeitsregeln: `~/.claude/CLAUDE.md`. Detail-Memory: `~/.claude/projects/.../memory/project_unified_ci.md`.
>
> **TL;DR Endstand:** Die CI-Bibliothek ist FERTIG, hermetisch, released. Apps pinnen `@v1`.
> Interne Refs der Reusables zeigen auf floating `@v1` (NICHT @dev/exact) → kein Drift, kein Re-Pin-Churn.
> Lint-Gates (ruff/dockerfile/eslint/tsc) advisory auf PR/dev, hart auf main/tags; **Tests immer hart**.
> **Rollout:** FootballApp ✅ grün. RecyclageApp/MitarbeiterApp/Rechnungsapp migriert, aber ihre
> **Test-Suites scheitern am harten Test-Gate** (echte App-Test-Schulden, KEIN CI-Bug) → App-Sanierung pro Repo, offen.

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
