# Design: Deploy-Gate-Härtung (C1/C2), Flaky-Rerun-Fix (B1) & e2e Phase G

> **Stand:** 2026-06-09 · Branch `dev` · zielt auf `reusable-ci.yml` + Sub-Workflows + Composites
> **Entstanden aus:** kritischem Audit der Unified-CI (Turn 2026-06-09) + Verifikation der „andere-Session"-Behauptungen gegen Git/PyPI.

## 0. Motivation & verifizierter Ausgangsstand

Ein kritisches Audit (5-Achsen: Correctness/Readability/Architecture/Security/Performance) der `reusable-ci.yml`
(884 Z.) + `reusable-docker-build.yml` + `reusable-security-scan.yml` + aller Composites förderte drei strukturelle
Befunde + einen bestätigten Bug zutage. Parallel wurde eine zweite Session-Einschätzung gegen den Ground-Truth geprüft.

**Korrektur der zweiten Session (verifiziert):** Deren „was fehlt noch"-Liste ist ~80 % veraltet.
`git tag` zeigt `v1.5.0`–`v1.5.7` (alle 2026-06-03/04), `v1` → `v1.5.7`. Damit sind **A–F real released**
(B=v1.5.1, C=v1.5.4, D=v1.5.6, E=v1.5.5, F=v1.5.3). Der `api-contract`-Job (Phase D) existiert in
`reusable-ci.yml` und skippt nur, weil keine App ein OpenAPI-Spec emittiert — **kein fehlendes Feature**.
Die **einzige** real bestätigte Breiten-Lücke ist **e2e/Playwright**: RecyclageApp hatte es vor der Migration
(commit `0af76c9` „replace inline E2E with proper Playwright test files"), verlor es bei `b176c29` (P4 thin caller).
Im Power-up-Spec ist e2e **nicht** als Phase getrackt.

## 1. Scope

**In Scope (diese Iteration):**

- **B1** — Flaky-Rerun-Fix (1-Zeiler, deterministisch).
- **C1 / Iteration 1** — Minimal-DAG-Gating: harte Gates real in den Deploy-Pfad hängen.
- **C2** — Opt-in Version-Assert im Health-Check + dokumentierter App-Contract.
- **Phase G** — `reusable-e2e.yml` (pre-merge, lokal gebootete App + Playwright), opt-in, dual-gate.
- **Doc** — Spec-Power-up um „Phase G" ergänzen + `CLAUDE.md` „A–F released" als verifiziert markieren.

**Explizit DEFERRED (eigene Folge-Iteration, dokumentiert):**

- **C1 / Iteration 2** — Candidate-Tag-Promotion (`:candidate-<sha>` → Promote-nach-grün). Das ist der
  *vollständige* Fix für „Staging-grün-vor-Prod". Iteration 1 schließt nur die Security/Coverage/e2e-Lücke.
- **Paid-gated** — CodeQL→Security-Tab (braucht GHAS), harte Signatur-Verifikation. Bleiben bewusst Free-Tier-Grenze.

## 2. Befunde → Design

### B1 — Flaky-Rerun ist ein stiller No-Op

**Befund:** `run-pytest-shard/action.yml` macht `pip install -q pytest-rerun-failures`. Verifiziert via PyPI:
`pytest-rerun-failures` (mit Bindestrich) → **HTTP 404, existiert nicht**; das kanonische Paket ist
**`pytest-rerunfailures`** (v16.3, pytest-dev). `-q` + `|| echo warning` schluckt den Install-Fehler →
`import pytest_rerunfailures` schlägt fehl → `--reruns` wird **nie** gesetzt. Das in v1.5.0 ausgelieferte
Flaky-Mitigation-Feature ist fleet-weit wirkungslos.

**Design:** Paketname `pytest-rerun-failures` → `pytest-rerunfailures`. Zusätzlich Härtung: bei Install-Fehler
**oder** fehlendem Import eine sichtbare `::warning::` mit klarer Ursache (nicht still). Kein Verhaltenswechsel
sonst — `--reruns` greift dann real.

### C1 / Iteration 1 — Harte Gates real in den Deploy-Pfad

**Befund:** `docker-build` hat `needs: [changes, lint-python, test-matrix]`. **Nicht** `security`, **nicht**
`coverage`. `docker-build` pusht `:latest`/`:staging` (Watchtower zieht Prod/Staging). Folge: ein roter
`gitleaks` (Secret), `bandit`-HIGH oder gerissene Coverage **verhindern den Push nicht** — nur Branch-Protection
auf PR-Basis gatet, und der dokumentierte `git merge --no-ff dev; git push`-Direct-Push umgeht das.

**Design (Iteration 1):**

1. **Total-Coverage-Gate dual machen.** Aktuell `blocking: "true"` (hart auf allen Branches). Angleichen an die
   Fleet-Philosophie + an die bereits dual-gegatete Diff-Coverage: **advisory auf PR/dev, hart auf main/tags.**
   Umsetzung: in `reusable-ci.yml` `coverage`-Job `blocking: ${{ github.ref == 'refs/heads/main' || startsWith(github.ref,'refs/tags/') }}`.
2. **`security`, `coverage`, `e2e` in `docker-build.needs`** aufnehmen + Guard erweitern:
   - `needs.security.result == 'success'` — automatisch korrekt dual-gegatet: das `security`-Reusable lässt
     `gitleaks` immer hart + `bandit`-HIGH nur auf main hart fallen (Rest `continue-on-error`). Also blockt
     `security == success` auf dev nur bei Secret-Leak, auf main zusätzlich bei bandit-HIGH. **Gewollt.**
   - `needs.coverage.result != 'failure'` — erlaubt `skipped` (Nicht-Python-Diff) + `success`; blockt nur echten
     Fail. Mit (1) heißt das: dev-Coverage-Drop blockt Staging nicht, main-Drop blockt Prod.
   - `needs.e2e.result != 'failure'` — analog (siehe Phase G; skipped wenn `enable-e2e:false`).
3. **PR-only-to-main + Branch-Protection.** Doku-/Policy-Teil (kein CI-Code): `main` darf nur per PR befüllt
   werden; Branch-Protection-Required-Checks müssen `{gitleaks, bandit, coverage, test-matrix}` listen. Wird im
   README + CLAUDE.md als Pflicht festgehalten. (Der `branch-discipline`-Workflow killt Feature-Branches, aber
   erzwingt **nicht** PR-statt-Direct-Push — das ist die Lücke, die hier dokumentiert/geschlossen wird.)

**Residuum (→ Iteration 2):** Auf einem main-Push wird `:latest` weiterhin im `docker-build`-Job gepusht, also
**vor** `verify-staging`. Iteration 1 stellt sicher, dass security/coverage/e2e/tests **vor** dem Push grün sind,
löst aber nicht „erst Staging-grün, dann Prod-Image". Das ist der explizite Auftrag von Iteration 2
(Candidate-Promotion). Wird in Spec + CLAUDE.md als bekannter Rest dokumentiert, nicht stillschweigend.

### C2 — Version-Assert (läuft das NEUE Image?)

**Befund:** `health-check` pollt auf HTTP 200. Das alte Image liefert auch 200 → grün, obwohl Watchtower das neue
Image evtl. nicht gezogen hat (realer Mai-Incident: Watchtower-403, Prod hing auf altem Image, Health 200).

**Design (Phase-D-Muster, opt-in):**

- `health-check`-Composite bekommt zwei optionale Inputs:
  - `expected-version` (z. B. `${{ github.sha }}`, leer = aus).
  - `version-url` (Default = `<url>` selbst; sonst eigener Endpoint).
- Wenn `expected-version` gesetzt: nach erfolgreichem 200-Poll ein zusätzlicher Schritt, der
  `version-url` liest, ein `sha`-/`version`-Feld extrahiert (JSON `.sha`/`.version` **oder** ein
  `X-App-Version`-Header) und gegen `expected-version` (Prefix-Match auf 7+ Stellen) assertet. Mismatch →
  Job-Fail (mit klarer Meldung „Watchtower hat das neue Image noch nicht deployt: läuft `<got>`, erwartet `<sha>`").
- `reusable-ci.yml` reicht `expected-version: ${{ github.sha }}` an `verify-staging`/`verify-prod` durch — aber
  nur **wirksam**, wenn die App den Endpoint liefert (sonst Input leer lassen ⇒ Verhalten wie heute, nur 200).
- **App-Contract** (dokumentierte Folgearbeit, NICHT CI): App exponiert die laufende Git-SHA an `/health`
  (`{"status":"ok","sha":"<GIT_SHA>"}`), SHA via Docker-Build-Arg/ENV. Inert bis die App das liefert — exakt
  das api-contract/Phase-D-Aktivierungsmuster. Aktivierung dann per-App über einen neuen Caller-Input
  (`version-url`/`prod-version-url`) bzw. implizit `${{ github.sha }}`.

### Phase G — e2e/Playwright (pre-merge, hermetisch)

**Befund:** Kein e2e-Job im Unified-CI; RecyclageApp verlor seine Playwright-Suite bei der Migration.

**Design:** neues `reusable-e2e.yml` + Verdrahtung im Orchestrator, opt-in, hermetisch vor dem Merge.

- **Boot-Modell:** Postgres+Redis als Job-Services (wie `test-matrix`), App-Start über das vorhandene
  `start-app`-Composite (es existiert explizit „DRY for Integration/E2E/DAST/API tests"). Playwright fährt
  gegen `http://localhost:<port>`.
- **Browser/Runner:** Job läuft im Container `mcr.microsoft.com/playwright:v1.<pin>-jammy` (Browser +
  System-Deps vorinstalliert) → umgeht das Debian-13-self-hosted-`sudo`/`--with-deps`-Problem und ist hermetisch.
  `runs-on` bleibt `${{ inputs.runner-label }}` (Container braucht nur Docker auf dem Runner). SHA-/Digest-Pin
  des Playwright-Images dokumentiert.
- **Inputs:** `enable-e2e` (Orchestrator, Default `false`), `e2e-command` (Default `npx playwright test`),
  `e2e-dir` (Default `e2e`), `boot-command`, `health-url`, `test-env`, `runner-label`, `python-version`.
  Skip-when-empty: `enable-e2e:false` ⇒ Job läuft gar nicht (wie load-test/dast/api-contract).
- **Dual-Gate:** Playwright-Step `continue-on-error` auf PR/dev, hart auf main/tags (gleiche Konditionale wie
  bandit/license). Playwright-eigene `retries` (Config) mildern Flakiness; zusätzlich `--retries=2` auf CI.
- **Orchestrator-Wiring:** neuer `e2e`-Job `needs: [changes, test-matrix]`,
  `if: ${{ inputs.enable-e2e && (needs.changes.outputs.python=='true' || needs.changes.outputs.frontend=='true' || needs.changes.outputs.ci=='true') }}`;
  Ergebnis fließt in `docker-build.needs` (siehe C1). In `telemetry.needs` + Summary aufnehmen.
- **Smoke:** `_smoke-e2e.yml` (workflow_dispatch + temporär push:[dev]) gegen eine Mini-Flask-Fixture
  (`tests/fixtures/e2e/`) mit einer trivialen Playwright-Spec; auf ubuntu validiert (Muster der Repo-CLAUDE.md §„Wie man ein Stück auf ubuntu validiert").

### Doc-Korrektur

- `docs/superpowers/specs/2026-06-03-senior-ci-powerup-design.md`: **Phase G (e2e)** als getrackte Phase ergänzen
  (war übersehen).
- `shared-workflows/CLAUDE.md`: „A–F released" als **verifiziert** markieren (Tag-Beleg `v1`→`v1.5.7`), Phase-G
  als offen aufnehmen, C1-Iteration-2-Residuum + C2-App-Contract als Resume-Punkte notieren.
- `README.md`: C2-App-Contract (`/health`-SHA) + e2e-Caller-Inputs + die PR-only-to-main/Branch-Protection-Pflicht
  unter Consuming/CAVEATS.

## 3. Geänderte/neue Artefakte

| Artefakt | Art | Inhalt |
|---|---|---|
| `.github/actions/run-pytest-shard/action.yml` | edit | B1: Paketname + sichtbarer Warn |
| `.github/actions/health-check/action.yml` | edit | C2: `expected-version`/`version-url` + Assert-Step |
| `.github/workflows/reusable-ci.yml` | edit | C1: coverage dual + docker-build.needs/Guard; C2: durchreichen; Phase G: `e2e`-Job + telemetry |
| `.github/workflows/reusable-e2e.yml` | **neu** | Phase G Reusable |
| `.github/workflows/_smoke-e2e.yml` | **neu** | Smoke (ubuntu) |
| `tests/fixtures/e2e/` | **neu** | Mini-Flask + Playwright-Spec |
| Spec / CLAUDE.md / README.md | edit | Doc-Korrektur |

## 4. Testing & Validierung

1. `./bin/actionlint.exe` (exit 0) + `python -m yamllint -d relaxed` auf alle geänderten/neuen Workflows.
2. **Ubuntu-Smoke** je Stück (Repo-CLAUDE.md-Muster): temporärer `push:[dev]`-Trigger, `gh run watch --exit-status`,
   danach Trigger zurücknehmen. Neu: `_smoke-e2e.yml`. Bestehende `_smoke-*` für coverage/docker-build re-validieren,
   weil `docker-build.needs`/`coverage`-Blocking geändert werden.
3. **B1** verifizieren: ein Shard mit absichtlich flaky-markiertem Test → Junit zeigt Reruns (statt sofort rot).
4. **C2** verifizieren: Smoke-Fixture liefert `/health` mit SHA → Assert grün; SHA mutieren → Assert rot.
5. **C1** verifizieren: Smoke mit gitleaks-Treffer ⇒ `docker-build` skipped/blockt (statt push). Coverage unter
   Schwelle auf simuliertem main ⇒ blockt; auf dev ⇒ advisory (push läuft).

## 5. Rollout

- Alles auf `dev` bauen + ubuntu-validieren. Interne Refs der neuen/geänderten Reusables auf floating `@v1`
  (Hermetik-Regel; keine `@dev`/exact). Nach grün: neuer Tag `v1.6.0` + `v1` force-move (nach `git log v1 --not dev`
  Verlust-Check + `git ls-remote`-Verifikation der Ziel-SHA).
- **dev→main + Fleet-Aktivierung USER-GATED.** Per-App Opt-in: `enable-e2e` + `version-url` setzen die Apps selbst,
  wenn sie Playwright-Specs bzw. `/health`-SHA liefern. Default-off ⇒ kein Verhaltenswechsel für die anderen Apps.
- Git-Commits mit Log-Identität (Repo-CLAUDE.md Gotcha #8: kein `git config` setzen).

## 6. Risiken & offene Punkte

- **R1 — `docker-build.needs` erweitern kann startup_failure/Skip-Kaskaden auslösen**, wenn ein neu referenzierter
  Job unter bestimmten Change-Detection-Pfaden skippt. Mitigation: `!= 'failure'`-Guards (erlauben skipped),
  `always()` bleibt erster Term; in jedem `_smoke`-Pfad (python-only / docker-only / frontend-only / ci-only) testen.
- **R2 — Playwright-Container auf self-hosted:** braucht Docker-in-Job-Container-Support des Runners; falls LXC-104
  zickt → e2e-Smoke fällt zurück auf ubuntu (`runner-label`-Override), wie der Rest der Validierung.
- **R3 — Coverage dual machen** senkt die dev-Strenge (Drop blockt Staging nicht mehr). Bewusst — entspricht der
  Fleet-Philosophie; main bleibt hart. Falls unerwünscht: `blocking:true` lassen + nur main in docker-build.needs.
- **O1 — C1-Iteration-2 (Candidate-Promotion)** ist der eigentliche „Staging-vor-Prod"-Fix und bleibt offen.
- **O2 — C2/e2e-Aktivierung** ist App-seitige Folgearbeit (SHA-`/health`, Playwright-Specs) pro Repo.
