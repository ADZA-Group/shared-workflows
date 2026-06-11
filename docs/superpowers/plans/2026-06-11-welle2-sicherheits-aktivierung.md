# Welle 2 — Sicherheits-Aktivierung pro App (Fleet-Endausbau)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** C2 `/health`-SHA in allen 4 Apps (verify-staging/prod wird scharf), a11y-Ratchet 12→0 und e2e-Aktivierung bei RecyclageApp — mit dem Prod-Version-Assert end-to-end bewiesen.

**Architecture:** Identisches App-Pattern je Flask-App (Dockerfile `ARG GIT_SHA`→`ENV APP_SHA`; `/health`-JSON um `sha` erweitert; Caller `staging-/prod-version-url`); Library liefert das Build-Arg seit v1.8.0. Prereq: Watchtower-Poll-Timing fixen (verify-prod pollt 20 min — Poll > 20 min ⇒ Version-Assert-Timeout ⇒ **False-Rollback**). Reihenfolge: RecyclageApp (voller Beweis inkl. gated promotion) → FootballApp → Rechnungsapp (NUR dev, user-gated Debt) → MitarbeiterApp (inert).

**Tech Stack:** Flask/pytest, Dockerfile, GitHub Actions Caller-Configs, SSH/Proxmox (Watchtower-Env).

**Konventionen:** wie Welle 1 (Log-Identität, LF, actionlint für Workflow-Files, fetch+rebase vor jedem Push, dev→Staging→main je App). Recon-Anker (verifiziert 2026-06-11): RecyclageApp `/health` = `app.py:260`, Dockerfile hat `ARG GIT_COMMIT` Z.91; FootballApp `/health` = `routes/health.py:10`; Rechnungsapp `/health` = `routes/admin.py:65` (`health_view`); MitarbeiterApp `/health` = `app.py:58`, Dockerfile hat `ARG GIT_COMMIT=unknown` + `ENV GIT_COMMIT=${GIT_COMMIT}` Z.42-43.

---

## Wiederverwendbares App-Pattern (Referenz für T2/T7/T8/T9)

**(P1) Dockerfile** — im Runtime-Stage, bei den bestehenden ENV-Zeilen:
```dockerfile
ARG GIT_SHA=dev
ENV APP_SHA=${GIT_SHA}
```
(Wo bereits `ARG GIT_COMMIT` existiert: zusätzlich `ARG GIT_SHA=dev` einführen und `ENV APP_SHA=${GIT_SHA}` setzen — CI sendet seit v1.8.0 `GIT_SHA`; `GIT_COMMIT` nicht entfernen.)

**(P2) `/health`-Route** — bestehende Response NUR erweitern (Key `sha`), z. B.:
```python
import os
# im bestehenden health-Handler, Response-Dict ergänzen:
"sha": os.environ.get("APP_SHA", "dev"),
```

**(P3) pytest** — neben bestehende Health-Tests (Datei je App unten):
```python
def test_health_exposes_sha(client, monkeypatch):
    monkeypatch.setenv("APP_SHA", "abc1234deadbeef")
    resp = client.get("/health")
    assert resp.status_code == 200
    assert resp.get_json()["sha"] == "abc1234deadbeef"
```
(Fixture-Name `client`/`auth_client` an die conftest der jeweiligen App anpassen — Implementer liest die bestehenden Health-Tests und folgt deren Muster. /health ist überall unauthenticated.)

**(P4) Caller** (`.github/workflows/build.yml`) — unter `prod-url`:
```yaml
      staging-version-url: "<staging-health-url>"   # nur wenn Staging existiert
      prod-version-url: "<prod-health-url>"
```

---

## Task 1: Watchtower-Poll-Prereq (LXC 102 fix + LXC 105 Befund)

**Files:** keine (SSH; Doku-Nachzug in T6/T7)

> OHNE diesen Fix: verify-prod (40×30s=20 min) + Poll 3600s ⇒ Assert-Timeout ⇒ Auto-Rollback
> retagt `:previous`→`:latest` und macht die Promotion rückgängig. HARTER Prereq.

- [ ] **Step 1: LXC 102 (RecyclageApp Prod) Poll 3600→300.** Compose-File finden + Env ändern + Watchtower neu erstellen:
```bash
ssh root@192.168.1.20 "pct exec 102 -- sh -c 'grep -rn WATCHTOWER_POLL_INTERVAL /opt/*/docker-compose*.yml /opt/*/.env 2>/dev/null'"
# im gefundenen File 3600 -> 300 ersetzen (sed -i), dann:
ssh root@192.168.1.20 "pct exec 102 -- sh -c 'cd /opt/<gefundenes-verzeichnis> && docker compose up -d watchtower'"
```
Verify: `docker inspect watchtower --format '{{range .Config.Env}}{{println .}}{{end}}' | grep POLL` → `300`. App-Container unangetastet (`docker ps` Status unverändert).

- [ ] **Step 2: LXC 105 (FootballApp Prod) Poll-Befund.** Gleicher inspect; wenn > 900 → auf 300 setzen (gleiche Prozedur). Befund notieren (fließt in T7 + CLAUDE.md).

- [ ] **Step 3: Staging-Poll-Kontrolle LXC 190** (soll 60s sein laut Doku): inspect, Befund notieren — kein Fix nötig solange ≤ 900.

---

## Task 2: RecyclageApp C2 (App + Dockerfile + Test)

**Files (Repo `RecyclageApp`, Branch dev):**
- Modify: `app.py` (Health-Handler ab Z.260), `Dockerfile` (Runtime-Stage, bei Z.91 `ARG GIT_COMMIT`)
- Test: `tests/test_health_sha.py` (neu; Muster P3, conftest nutzt `client`-Fixture — bestehende Tests lesen)

- [ ] Step 1: Health-Handler lesen (app.py:255-275) → Response-Dict um `"sha": os.environ.get("APP_SHA", "dev")` erweitern (P2; `import os` prüfen — app.py importiert os bereits).
- [ ] Step 2: Test schreiben (P3) → lokal rot beweisen geht ohne Postgres nicht zwingend (Skip-Gate-Pattern der App beachten) → Test mit Skip-Gate versehen wie `tests/test_thommen_db.py`-Muster, CI beweist.
- [ ] Step 3: Dockerfile P1 direkt unter `ARG GIT_COMMIT=unknown`.
- [ ] Step 4: Commit `feat(health): expose laufende git-sha am /health (C2 deploy-verify)` — NUR diese 3 Dateien.

## Task 3: RecyclageApp Caller-Aktivierung (gleicher dev-Push wie T2)

**Files:** Modify: `.github/workflows/build.yml` (unter `prod-url`)

- [ ] Step 1 (P4):
```yaml
      staging-version-url: "https://i-app.adza-group.ch/health"
      prod-version-url: "https://app.adza-group.ch/health"
```
- [ ] Step 2: Commit `ci: aktiviere C2 version-assert (staging+prod) — verify prueft laufende sha`; push dev (fetch+rebase vorher).
- [ ] Step 3: dev-Run watchen → **Beweis 1: verify-staging assert grün** (Staging-Watchtower 60s; Build trägt GIT_SHA seit v1.8.0; Staging-`/health` liefert die Run-SHA). Bei Timeout: erst Staging-Poll prüfen (T1 Step 3), nicht raten.

## Task 4: RecyclageApp a11y 12→0

**Files:** Modify: `frontend/src/...` (Login-Page-Komponente + ggf. Token-CSS), `.github/workflows/build.yml` (Ratchet)

- [ ] Step 1: Volle Findings-Liste ziehen: `gh run view 27263123792 --log 2>&1 | grep -aA6 "Errors in https"` (12 Stück; bekannte: Logo-Span weiß auf Grün 2.28:1 → Empfehlung bg `#09ac45`; muted `#94a3b8` 2.45:1 → Empfehlung `#000917`).
- [ ] Step 2: Login-Komponente finden (`grep -rn "Recycling Management" frontend/src`) → Farb-Klassen/Vars minimal-invasiv anpassen (dunkleres muted, Logo-bg dunkler ODER Schriftgewicht/Größe); KEIN Redesign. `cd frontend && npx tsc -b --noEmit && npm run build` lokal grün.
- [ ] Step 3: Commit `fix(a11y): login-page kontraste wcag-konform (12 findings -> 0)`; push dev; im dev-Run den advisory-a11y-Count aus der Frontend-Lane lesen (Step-Summary) → erwartet 0; sonst iterieren.
- [ ] Step 4: Bei 0: Caller `a11y-threshold: 12` → `0` (Kommentar anpassen), Commit `ci: a11y-ratchet 0 — schuld abgetragen`, push.

## Task 5: RecyclageApp e2e-Aktivierung (Smoke-first)

**Files:** Investigation-first — Create: `e2e/`-Verzeichnis (package.json `@playwright/test@1.60.0`, playwright.config.ts baseURL `http://localhost:8000`, 1 Login-Smoke-Spec) ODER Adaption der bestehenden `frontend`-Playwright-Specs; Modify: `.github/workflows/build.yml`.

- [ ] Step 1 (Investigation): Wie serviert Flask das SPA? (`grep -rn "static_folder\|send_from_directory\|dist" app.py routes/ | head`). Bestehende e2e: `ls frontend/e2e frontend/playwright.config.* 2>/dev/null` + `grep playwright frontend/package.json`.
- [ ] Step 2 (Entscheid, smoke-first): Wenn Flask den `frontend/dist`-Build serviert → `e2e-boot-command: "cd frontend && npm ci && npm run build && cd .. && pip install -q -r requirements.txt && gunicorn -w 1 -b 127.0.0.1:8000 wsgi:app"` mit `e2e-health-url: http://localhost:8000/health`, `e2e-dir` = neues schlankes `e2e/` (Login-Smoke gegen die geservte App; DB/Redis kommen aus den reusable-e2e-Services, test-env mappt localhost→postgres/redis automatisch). Wenn der lokale Boot in 2 Iterationen nicht steht → **Fallback (Spec R3, dokumentieren):** e2e gegen `https://i-app.adza-group.ch` (baseURL via E2E_BASE_URL), boot-command = trivialer `python -m http.server`-Dummy NICHT nötig — stattdessen NICHT enable-e2e, sondern Befund in CLAUDE.md + Welle-3-Item. Kein Gewürge.
- [ ] Step 3: Login-Smoke-Spec (Muster):
```typescript
import { test, expect } from "@playwright/test";
test("login page renders + login works", async ({ page }) => {
  await page.goto("/");
  await expect(page.locator("text=Recycling Management")).toBeVisible();
  await page.fill('input[name="username"]', "admin");
  await page.fill('input[name="password"]', process.env.E2E_PASSWORD || "TestPasswort123!");
  await page.click('button[type="submit"]');
  await expect(page).toHaveURL(/dashboard|einnahmen|\/$/);
});
```
(Selektoren an die echte Login-Page anpassen — Implementer liest die Komponente; Passwort = `RECYCLING_AUTH_PASSWORD` aus test-env, seeded beim Init.)
- [ ] Step 4: Caller: `enable-e2e: true` + boot/health/dir-Inputs; Commit; push dev; dev-Run: e2e-Job läuft (advisory auf dev) → grün.

## Task 6: RecyclageApp dev→main — der Wellen-Beweis

- [ ] Step 1: dev-Run komplett grün (T2–T5) → `git checkout main && git pull --ff-only && git merge --no-ff dev -m "ci: dev->main — C2 version-assert + a11y 0 + e2e (welle 2)" && git push`.
- [ ] Step 2: main-Run watchen. Erwartung: branch-policy ✓ → candidate → staging-green → promote → **verify-prod mit SHA-Assert grün** (Watchtower-Poll jetzt 300s < 20-min-Fenster) → **Beweis 2: Prod-Deploy per Version verifiziert, der Gestern-Blindfleck ist zu.** e2e hart auf main ✓. Bei Assert-Timeout trotz 300s: NICHT erneut mergen — Watchtower-Logs prüfen (Creds-403-Klasse), systematic-debugging.
- [ ] Step 3: RecyclageApp-CLAUDE.md: Deploy-Flow-Block aktualisieren (Poll 300s, C2 aktiv, e2e aktiv, a11y 0).

## Task 7: FootballApp C2 (dev→main)

**Files (Repo `FootballApp`):** Modify: `routes/health.py` (Z.10 ff), `Dockerfile` (Runtime-Stage nach Z.29 ENV-Block), `.github/workflows/build.yml`; Test: bestehende Health-Tests erweitern (`grep -rln "def test.*health" tests/` → dort P3 andocken).

- [ ] Step 1: P1+P2+P3 (Reihenfolge: Test rot lokal — FootballApp-Tests laufen sqlite-lokal — dann Code grün).
- [ ] Step 2: Caller NUR `prod-version-url: "https://footballapp.adza-group.ch/health"` (kein Staging!). 
- [ ] Step 3: Commit(s) + push dev → dev-Run grün (kein Staging-Verify dort) → dev→main mergen → main-Run: verify-prod-Assert greift nach Watchtower-Pull (Poll-Befund aus T1 Step 2 beachten; FootballApp ist NICHT gated — :latest kommt direkt, Assert prüft nur „neues Image läuft").
- [ ] Step 4: FootballApp-CLAUDE.md kurzer Vermerk (C2 aktiv; kein Staging = kein gated-promotion, Grenze aus Umbrella).

## Task 8: Rechnungsapp C2 — NUR dev (user-gated Debt!)

**Files (Repo `Rechnungsapp`):** Modify: `routes/admin.py` (health_view Z.65 — prüfen ob das wirklich das öffentliche `/health` ist: `grep -rn "url_prefix" routes/admin.py app.py | head`; falls `/health` woanders registriert ist, die echte Route nehmen), `Dockerfile` (Runtime-ENV-Block Z.110 ff), `.github/workflows/build.yml` (P4 beide URLs: `https://i-rechnungsapp.adza-group.ch/health` + `https://rechnungsapp.adza-group.ch/health`); Test: neben bestehende Admin-/Health-Tests.

- [ ] Step 1: P1+P2+P3+P4 als EIN dev-Commit-Set; push dev; dev-Run grün (verify-staging-Assert beweist Staging mit Run-SHA — Staging-Watchtower trackt dort `:dev`, Poll 3600s laut Memory! → wenn Assert-Timeout: erst Poll/Tag-Tracking auf LXC 203 verifizieren und ggf. wie T1 fixen, dokumentieren).
- [ ] Step 2: **STOPP — KEIN dev→main.** Vermerk in Rechnungsapp-CLAUDE.md: „C2 liegt auf dev, aktiviert sich mit dem user-gated Debt-Merge."

## Task 9: MitarbeiterApp /health-SHA (inert)

**Files (Repo `MitarbeiterApp`):** Modify: `app.py` (Z.58 Health) — Dockerfile hat `ARG GIT_COMMIT`+`ENV GIT_COMMIT` SCHON: P2-Variante `"sha": os.environ.get("APP_SHA", os.environ.get("GIT_COMMIT", "dev"))` + Dockerfile nur `ARG GIT_SHA=dev` / `ENV APP_SHA=${GIT_SHA}` ergänzen; Test neben bestehende.

- [ ] Step 1: Pattern + Test; push dev; CI grün; dev→main (CI-only-Wirkung, deploy-prod:false — kein Deploy-Risiko). KEINE version-urls (kein Ziel; dokumentiert inert).

## Task 10: Wellen-Abschluss

- [ ] Step 1: Memory (MEMORY.md + project_unified_ci.md): Welle-2-Stand, Beweise (Staging-Assert, Prod-Assert, a11y 0, e2e an), Watchtower-Poll-Fixes/Befunde, Rechnungsapp-dev-Status.
- [ ] Step 2: shared-workflows/CLAUDE.md Resume: Welle 2 ✓, nächste = Welle 3 (OpenAPI+Smoke je App) + Welle 4 (Watchtower-Flotte — LXC-Befunde aus T1 einarbeiten: 102 erledigt, Rest-Inventur offen).

---

## Self-Review (gegen Umbrella §2)

**Coverage:** A1 C2 alle 4 Apps → T2/T3/T7/T8/T9 ✓ (Reihenfolge + Rechnungsapp-dev-only + Mitarbeiter-inert wie Spec) · A5 a11y → T4 ✓ · A3 e2e → T5 (inkl. R3-Fallback ohne Gewürge) ✓ · Prod-Assert-E2E-Beweis → T6 ✓ · **Neu erkannter harter Prereq** (verify-prod 20 min vs Poll 3600s ⇒ False-Rollback) → T1, in T6/T8 referenziert ✓ · Doku → T6.3/T7.4/T8.2/T10 ✓.
**Placeholder:** keine — Pattern-Code vollständig (P1–P4), per-App-Anker aus Recon, Investigations-Tasks mit konkreten Kommandos + Entscheidungsregel + sauberem Fallback.
**Konsistenz:** ENV-Name `APP_SHA` einheitlich (health-check-Composite liest `.sha` aus JSON — Name im JSON ist `sha`, ENV-Name frei); Caller-Input-Namen identisch zu reusable-ci (staging-/prod-version-url); e2e-Inputs wie Phase G.
